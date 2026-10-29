import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Private_Meeting_Assistant

/// Diagnostic, not part of the normal run: cuts a recording into utterances as the app does and
/// prints what Whisper makes of each, with how sure it is there was speech, to see which lines it
/// invents. Run with `PMA_TRACE_SEGMENTS=1` too to see the lines it drops. Run with
/// `TEST_RUNNER_REPLAY_AUDIO=<audio file> xcodebuild test -only-testing:…/InventedLinesReplay`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["REPLAY_AUDIO"] != nil))
struct InventedLinesReplay {
    @Test(.timeLimit(.minutes(5)))
    func replay() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REPLAY_AUDIO"]!)
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        // TEST_RUNNER_REPLAY_GAIN_DB: louder, to reach the segmenter's threshold as the live mic did.
        let gain = pow(10, Float(ProcessInfo.processInfo.environment["REPLAY_GAIN_DB"].flatMap(Double.init) ?? 0) / 20)
        let samples = try MonoResampler().convert(buffer).map { $0 * gain }
        // How much steady noise the mic's noise suppression takes off this recording.
        if let suppressor = NoiseSuppressor() {
            let out = stride(from: 0, to: samples.count, by: 1_600).flatMap { suppressor.process(Array(samples[$0..<min($0 + 1_600, samples.count)]), at: $0).samples }
            func db(_ x: [Float]) -> Double { 10 * log10(max(x.reduce(0) { $0 + Double($1 * $1) } / Double(max(x.count, 1)), 1e-12)) }
            print(String(format: "replay: noise suppression %.1f → %.1f dB", db(samples), db(out)))
            for second in stride(from: 0, to: min(samples.count, out.count) / 16_000, by: 2) {
                let r = (second * 16_000)..<min((second + 2) * 16_000, out.count)
                print(String(format: "replay:   %2d s: %.1f → %.1f dB", second, db(Array(samples[r])), db(Array(out[r]))))
            }
        }
        let model = try #require(SpeechModel.catalog.first(where: ModelStore.isComplete))
        let transcriber = try await Transcriber.load(model)

        // What Apple's recognizer (the live text) hears in the same audio, fed at about real time.
        let heard = Mutex<[LiveTranscriber.Fragment]>([])
        if let live = await LiveTranscriber.start(locale: Locale(identifier: "en-US"), onFragment: { f in heard.withLock { $0.append(f) } }) {
            for offset in stride(from: 0, to: samples.count, by: 1_600) {
                live.append(Array(samples[offset..<min(offset + 1_600, samples.count)]), at: offset)
                try await Task.sleep(for: .milliseconds(25))
            }
            try await Task.sleep(for: .seconds(2))
            await live.stop()
        }
        for f in heard.withLock({ $0 }) {
            print(String(format: "replay: apple %5.2f-%5.2fs %@ %@", Double(f.startMs) / 1000, Double(f.endMs) / 1000, f.isFinal ? "final" : "volatile", f.text))
        }

        var segmenter = Segmenter()
        var utterances = segmenter.push(samples)
        if let last = segmenter.flush() { utterances.append(last) }
        // TEST_RUNNER_SILERO_MODEL=<…mlmodelc>: Silero's speech probabilities per utterance.
        let vad = ProcessInfo.processInfo.environment["SILERO_MODEL"].flatMap { VoiceActivity.load(from: URL(fileURLWithPath: $0)) }
        for u in utterances {
            var silero = ""
            if let vad {
                vad.reset()
                let p = vad.probabilities(u.samples[...])
                let speech = p.filter { $0 >= 0.5 }.count
                var run = 0, longest = 0
                for x in p { run = x >= 0.5 ? run + 1 : 0; longest = max(longest, run) }
                silero = String(format: "  silero max %.2f, speech %d of %d chunks, longest %d", p.max() ?? 0, speech, p.count, longest)
            }
            print(String(format: "replay: utterance %5.2f-%5.2fs%@", Double(u.startMs) / 1000, Double(u.endMs) / 1000, silero))
            for line in try await transcriber.transcribe(u.samples, language: "en") {
                print(String(format: "replay: %5.2f-%5.2fs line %5.2f-%5.2fs  noSpeech %.2f confidence %.2f  %@",
                             Double(u.startMs) / 1000, Double(u.endMs) / 1000, Double(u.startMs) / 1000 + Double(line.start),
                             Double(u.startMs) / 1000 + Double(line.end), line.noSpeech, line.confidence, line.text))
            }
            if let vad, ProcessInfo.processInfo.environment["SILERO_CHUNKS"] != nil {
                vad.reset()
                let p = vad.probabilities(u.samples[...])
                print("replay:   silero per 32 ms from \(Double(u.startMs) / 1000)s: " + p.map { String(format: "%.0f", $0 * 9) }.joined())
            }
        }
    }
}
