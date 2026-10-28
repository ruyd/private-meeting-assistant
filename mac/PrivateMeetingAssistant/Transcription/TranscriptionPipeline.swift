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

    /// `onLine` and `onBacklog` are called off the main thread.
    init(
        transcriber: Transcriber,
        language: String?,
        startHostTime: UInt64,
        removeEcho: Bool = true,
        voiceprinter: Voiceprinter? = nil,
        identifySpeakers: Set<AudioSource> = [],
        onLine: @escaping @Sendable (TranscriptLine) -> Void,
        onBacklog: @escaping @Sendable (Int) -> Void
    ) {
        self.startHostTime = startHostTime
        self.onBacklog = onBacklog
        state = Mutex(State(echoGate: removeEcho ? EchoGate() : nil))
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self)
        jobs = continuation
        let queued = queued
        let speakers = speakers
        worker = Task.detached(priority: .userInitiated) {
            for await job in stream {
                let u = job.utterance
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
        let utterances = state.withLock { state -> [Segmenter.Utterance] in
            switch chunk.source {
            case .system:
                state.echoGate?.addFarEnd(chunk.samples, at: position)
                return state.segment(.system, chunk.samples, at: position)
            case .mic:
                guard state.echoGate != nil else { return state.segment(.mic, chunk.samples, at: position) }
                guard let gated = state.echoGate?.processMic(chunk.samples, at: position) else { return [] }
                return state.segment(.mic, gated.samples, at: gated.position)
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
                jobs += state.segment(.mic, held.samples, at: held.position).map { Job(source: .mic, utterance: $0) }
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
