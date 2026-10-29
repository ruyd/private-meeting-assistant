import AVFoundation
import OSLog
import Synchronization

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "transcription")

struct TranscriptLine: Identifiable, Equatable, Sendable {
    let id = UUID()
    let source: AudioSource
    /// Milliseconds from the start of the recording.
    let startMs: Int
    let endMs: Int
    let text: String
    /// The voice this line was told apart as (Participant 1, 2…), when speakers are identified on
    /// its source; numbers may change when the recording finishes (see `SpeakerTracker.finished`).
    var participant: Int? = nil

    /// "Participant 2", or "Me" / "Them" when speakers aren't told apart.
    var speaker: String { participant.map { "Participant \($0)" } ?? source.speaker }
}

/// The voices told apart in a recording: their profiles, how numbers given during the recording map
/// to the final ones, and a sample clip of each (16 kHz), keyed by final number.
struct SpeakerResult: Sendable {
    let profiles: [SpeakerTracker.Profile]
    let renumber: [Int: Int]
    let clips: [Int: [Float]]
}

/// Turns captured audio into transcript lines: each source is cut into utterances on the audio
/// clock, then Whisper transcribes them one at a time in the order they finished.
final class TranscriptionPipeline: Sendable {
    private struct Job: Sendable {
        let source: AudioSource
        let utterance: Segmenter.Utterance
    }

    /// A source that skips ahead by more than this stopped delivering for a while.
    fileprivate static let gapToleranceSamples = Int(MonoResampler.sampleRate * 0.2)

    private let startHostTime: UInt64
    private struct State {
        var segmenters: [AudioSource: Segmenter] = [:]
        /// nil when echo removal is off (e.g. the user wears headphones and turned it off).
        var echoGate: EchoGate?
        /// Steady background noise off the mic, after echo removal (before it, it would upset the
        /// echo canceller, which needs the mic as the room heard it).
        var denoiser = NoiseSuppressor()
        /// 30 ms frames (by meeting position) in which the far end played, for the last few seconds.
        var farEndFrames: Set<Int> = []
        /// The meeting position from which echo removal knows the echo's delay and level and
        /// gates it; nil until then. Mic audio from before it may still carry the echo.
        var echoRemovalReadyAt: Int?

        /// Notes which frames of system audio had sound.
        mutating func noteFarEnd(_ samples: [Float], at position: Int) {
            let frame = Segmenter.frame
            for start in stride(from: 0, to: samples.count, by: frame) {
                let end = min(start + frame, samples.count)
                var sum: Float = 0
                for s in samples[start..<end] { sum += s * s }
                if sum / Float(end - start) > 1e-6 { farEndFrames.insert((position + start) / frame) }
            }
            let oldest = (position - Int(MonoResampler.sampleRate) * 5) / frame
            farEndFrames = farEndFrames.filter { $0 >= oldest }
        }

        /// The mic audio for the saved recording. Until echo removal has learned the echo's delay and
        /// level (the first two seconds or so of the far end talking), its output still carries the
        /// echo, so the mic is left out wherever the far end played up to half a second before.
        func micForSaving(_ samples: [Float], at position: Int) -> [Float] {
            guard echoGate != nil, !farEndFrames.isEmpty else { return samples }
            if let ready = echoRemovalReadyAt, position >= ready { return samples }
            let frame = Segmenter.frame
            var out = samples
            for start in stride(from: 0, to: samples.count, by: frame) {
                if let ready = echoRemovalReadyAt, position + start >= ready { break }
                let f = (position + start) / frame
                if (f - 17...f).contains(where: farEndFrames.contains) {
                    for i in start..<min(start + frame, out.count) { out[i] = 0 }
                }
            }
            return out
        }

        mutating func denoise(_ samples: [Float], at position: Int) -> (samples: [Float], position: Int) {
            denoiser?.process(samples, at: position) ?? (samples, position)
        }

        /// Cuts `samples` (starting at absolute sample `position`) into utterances.
        mutating func segment(_ source: AudioSource, _ samples: [Float], at position: Int) -> [Segmenter.Utterance] {
            var segmenter = segmenters[source] ?? Segmenter()
            var out: [Segmenter.Utterance] = []
            if position > segmenter.position + TranscriptionPipeline.gapToleranceSamples, let ended = segmenter.skip(to: position) {
                out.append(ended)
            }
            out += segmenter.push(samples)
            segmenters[source] = segmenter
            return out
        }
    }

    private let state: Mutex<State>
    /// Voices told apart so far, and the audio of each one's sample line (by its time range).
    private final class Speakers: Sendable {
        struct State {
            var tracker = SpeakerTracker()
            var clips: [ClosedRange<Int>: [Float]] = [:]
        }
        let state = Mutex(State())
    }
    private let speakers = Speakers()
    private let queued = Counter()
    private let jobs: AsyncStream<Job>.Continuation
    private let worker: Task<Void, Never>
    private let onBacklog: @Sendable (Int) -> Void
    /// Receives the audio transcription hears, at its meeting sample position: system audio as
    /// captured, and the mic after echo removal. For saving the meeting's audio without echo.
    private let onAudio: (@Sendable (AudioSource, [Float], Int) -> Void)?

    /// `onLine` and `onBacklog` are called off the main thread.
    init(
        transcriber: Transcriber,
        language: String?,
        startHostTime: UInt64,
        removeEcho: Bool = true,
        voiceprinter: Voiceprinter? = nil,
        identifySpeakers: Set<AudioSource> = [],
        voiceActivity: VoiceActivity? = VoiceActivity.bundled(),
        onAudio: (@Sendable (AudioSource, [Float], Int) -> Void)? = nil,
        onLine: @escaping @Sendable (TranscriptLine) -> Void,
        onBacklog: @escaping @Sendable (Int) -> Void
    ) {
        self.startHostTime = startHostTime
        self.onBacklog = onBacklog
        self.onAudio = onAudio
        state = Mutex(State(echoGate: removeEcho ? EchoGate() : nil))
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self)
        jobs = continuation
        let queued = queued
        let speakers = speakers
        worker = Task.detached(priority: .userInitiated) {
            for await job in stream {
                let u = job.utterance
                // Loud enough for the segmenter but nobody talking (a fan, clicks, a quiet room):
                // Whisper would write "Thank you." over it.
                if let voiceActivity, !voiceActivity.hasSpeech(u.samples) {
                    log.debug("skipped \(u.endMs - u.startMs) ms without speech")
                    onBacklog(queued.add(-1))
                    continue
                }
                do {
                    for line in try await transcriber.transcribe(u.samples, language: language) {
                        var out = TranscriptLine(
                            source: job.source,
                            startMs: u.startMs + Int(line.start * 1000),
                            endMs: min(u.startMs + Int(line.end * 1000), u.endMs),
                            text: line.text
                        )
                        if let voiceprinter, identifySpeakers.contains(job.source) {
                            out.participant = Self.identify(out, in: u, line: line, voiceprinter: voiceprinter, speakers: speakers)
                        }
                        onLine(out)
                    }
                } catch {
                    log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
                }
                onBacklog(queued.add(-1))
            }
        }
    }

    /// Called from audio threads with every captured chunk.
    func append(_ chunk: AudioChunk) {
        let position = samplePosition(of: chunk.hostTime)
        let onAudio = onAudio
        let utterances = state.withLock { state -> [Segmenter.Utterance] in
            switch chunk.source {
            case .system:
                state.echoGate?.addFarEnd(chunk.samples, at: position)
                if onAudio != nil, state.echoGate != nil { state.noteFarEnd(chunk.samples, at: position) }
                onAudio?(.system, chunk.samples, position)
                return state.segment(.system, chunk.samples, at: position)
            case .mic:
                guard state.echoGate != nil else {
                    let mic = state.denoise(chunk.samples, at: position)
                    onAudio?(.mic, mic.samples, mic.position)
                    return state.segment(.mic, mic.samples, at: mic.position)
                }
                let gated = state.echoGate?.processMic(chunk.samples, at: position)
                if state.echoRemovalReadyAt == nil, state.echoGate?.delay != nil, state.echoGate?.echoLevel != nil {
                    // Its gating takes another moment to settle (measured: about a second).
                    state.echoRemovalReadyAt = position + chunk.samples.count + Int(MonoResampler.sampleRate * 1.5)
                }
                guard let gated else { return [] }
                let mic = state.denoise(gated.samples, at: gated.position)
                onAudio?(.mic, state.micForSaving(mic.samples, at: mic.position), mic.position)
                return state.segment(.mic, mic.samples, at: mic.position)
            }
        }
        for u in utterances { enqueue(Job(source: chunk.source, utterance: u)) }
    }

    /// Transcribes speech still in progress, then waits for the queue to drain.
    func finish() async {
        let remaining = state.withLock { state in
            if let gate = state.echoGate {
                let s = gate.stats
                log.notice("echo gate: delay \(gate.delay ?? -1) frames, level \(gate.echoLevel ?? -1), frames \(s.frames), with far end \(s.farEndFrames), gated \(s.gated), best correlation \(s.bestCorrelation) at lag \(s.bestLag)")
            }
            var jobs: [Job] = []
            if let held = state.echoGate?.flush() {
                let mic = state.denoise(held.samples, at: held.position)
                onAudio?(.mic, state.micForSaving(mic.samples, at: mic.position), mic.position)
                jobs += state.segment(.mic, mic.samples, at: mic.position).map { Job(source: .mic, utterance: $0) }
            }
            for source in AudioSource.allCases {
                if let last = state.segmenters[source]?.flush() { jobs.append(Job(source: source, utterance: last)) }
            }
            return jobs
        }
        remaining.forEach(enqueue)
        jobs.finish()
        await worker.value
    }

    /// The final participants once `finish()` returned; nil when no voices were told apart.
    func speakerResult() -> SpeakerResult? {
        speakers.state.withLock { speakers in
            guard !speakers.tracker.profiles.isEmpty else { return nil }
            let (profiles, renumber) = speakers.tracker.finished()
            var clips: [Int: [Float]] = [:]
            for (i, profile) in profiles.enumerated() {
                clips[i + 1] = speakers.clips[profile.sample]
            }
            return SpeakerResult(profiles: profiles, renumber: renumber, clips: clips)
        }
    }

    /// Lines shorter than this borrow the voiceprint of their whole utterance; with less than this
    /// in the utterance too, the line goes to whoever spoke last (voiceprints of shorter clips are
    /// unreliable).
    static let minVoiceprintSamples = Int(MonoResampler.sampleRate * 2)

    private static func identify(
        _ out: TranscriptLine, in u: Segmenter.Utterance, line: Transcriber.Line, voiceprinter: Voiceprinter, speakers: Speakers
    ) -> Int? {
        let rate = MonoResampler.sampleRate
        let from = min(max(Int(Double(line.start) * rate), 0), u.samples.count)
        let to = min(max(Int(Double(line.end) * rate), from), u.samples.count)
        let own = u.samples[from..<to]
        let clip = own.count >= minVoiceprintSamples ? own : u.samples.count >= minVoiceprintSamples ? u.samples[...] : nil
        let voiceprint = clip.flatMap { voiceprinter.embed($0) }
        return speakers.state.withLock { speakers in
            // Only a line long enough on its own can be the sample clip of its voice.
            let (participant, isSample) = speakers.tracker.assign(
                voiceprint, source: out.source, startMs: out.startMs, endMs: out.endMs,
                canBeSample: own.count >= minVoiceprintSamples
            )
            if isSample {
                speakers.clips[out.startMs...out.endMs] = Array(own)
                // Keep only the clips that are still someone's sample.
                let kept = Set(speakers.tracker.profiles.map(\.sample))
                speakers.clips = speakers.clips.filter { kept.contains($0.key) }
            }
            return participant
        }
    }

    private func enqueue(_ job: Job) {
        onBacklog(queued.add(1))
        jobs.yield(job)
    }

    private final class Counter: Sendable {
        private let value = Mutex(0)
        func add(_ delta: Int) -> Int { value.withLock { $0 += delta; return $0 } }
    }

    private func samplePosition(of hostTime: UInt64) -> Int {
        let seconds = AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: startHostTime)
        return max(Int(seconds * MonoResampler.sampleRate), 0)
    }
}
