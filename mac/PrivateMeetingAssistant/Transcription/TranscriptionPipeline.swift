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
}

/// Turns captured audio into transcript lines: each source is cut into utterances on the audio
/// clock, then Whisper transcribes them one at a time in the order they finished.
final class TranscriptionPipeline: Sendable {
    private struct Job: Sendable {
        let source: AudioSource
        let utterance: Segmenter.Utterance
    }

    /// A source that skips ahead by more than this stopped delivering for a while.
    private static let gapToleranceSamples = Int(MonoResampler.sampleRate * 0.2)

    private let startHostTime: UInt64
    private let segmenters = Mutex<[AudioSource: Segmenter]>([:])
    private let queued = Counter()
    private let jobs: AsyncStream<Job>.Continuation
    private let worker: Task<Void, Never>
    private let onBacklog: @Sendable (Int) -> Void

    /// `onLine` and `onBacklog` are called off the main thread.
    init(
        transcriber: Transcriber,
        language: String?,
        startHostTime: UInt64,
        onLine: @escaping @Sendable (TranscriptLine) -> Void,
        onBacklog: @escaping @Sendable (Int) -> Void
    ) {
        self.startHostTime = startHostTime
        self.onBacklog = onBacklog
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self)
        jobs = continuation
        let queued = queued
        worker = Task.detached(priority: .userInitiated) {
            for await job in stream {
                let u = job.utterance
                do {
                    for line in try await transcriber.transcribe(u.samples, language: language) {
                        onLine(TranscriptLine(
                            source: job.source,
                            startMs: u.startMs + Int(line.start * 1000),
                            endMs: min(u.startMs + Int(line.end * 1000), u.endMs),
                            text: line.text
                        ))
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
        let utterances = segmenters.withLock { segmenters in
            var segmenter = segmenters[chunk.source] ?? Segmenter()
            var out: [Segmenter.Utterance] = []
            if position > segmenter.position + Self.gapToleranceSamples, let ended = segmenter.skip(to: position) {
                out.append(ended)
            }
            out += segmenter.push(chunk.samples)
            segmenters[chunk.source] = segmenter
            return out
        }
        for u in utterances { enqueue(Job(source: chunk.source, utterance: u)) }
    }

    /// Transcribes speech still in progress, then waits for the queue to drain.
    func finish() async {
        let remaining = segmenters.withLock { segmenters in
            AudioSource.allCases.compactMap { source in
                segmenters[source]?.flush().map { Job(source: source, utterance: $0) }
            }
        }
        remaining.forEach(enqueue)
        jobs.finish()
        await worker.value
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
