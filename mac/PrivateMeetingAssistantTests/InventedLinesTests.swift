import AVFoundation
import Foundation
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
        let model = try #require(SpeechModel.catalog.first(where: ModelStore.isComplete))
        let transcriber = try await Transcriber.load(model)

        var segmenter = Segmenter()
        var utterances = segmenter.push(samples)
        if let last = segmenter.flush() { utterances.append(last) }
        for u in utterances {
            for line in try await transcriber.transcribe(u.samples, language: "en") {
                print(String(format: "replay: %5.2f-%5.2fs  noSpeech %.2f confidence %.2f  %@",
                             Double(u.startMs) / 1000, Double(u.endMs) / 1000, line.noSpeech, line.confidence, line.text))
            }
        }
    }
}
