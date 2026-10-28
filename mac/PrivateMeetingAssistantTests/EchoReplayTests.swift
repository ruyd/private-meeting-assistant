import AVFoundation
import Foundation
import Testing
@testable import Private_Meeting_Assistant

/// Diagnostic, not part of the normal run: replays a capture-test recording (mic.wav and system.wav,
/// timeline-aligned) through the echo gate and prints what it does each second. Run with
/// `TEST_RUNNER_ECHO_REPLAY_DIR=<folder> xcodebuild test -only-testing:…/EchoReplayTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ECHO_REPLAY_DIR"] != nil))
struct EchoReplayTests {
    private func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    @Test func replay() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_REPLAY_DIR"]!)
        var mic = try load(dir.appending(path: "mic.wav"))
        var far = try load(dir.appending(path: "system.wav"))
        far += [Float](repeating: 0, count: max(mic.count - far.count, 0))
        // Optionally mix in near-end speech (you talking over them) at the given level, 8 s to 11 s.
        var near = [Float](repeating: 0, count: mic.count)
        if let db = ProcessInfo.processInfo.environment["ECHO_REPLAY_NEAR_DB"].flatMap(Float.init),
           let path = ProcessInfo.processInfo.environment["ECHO_REPLAY_NEAR_WAV"] {
            let voice = try load(URL(fileURLWithPath: path))
            let rms = (voice.reduce(0) { $0 + $1 * $1 } / Float(voice.count)).squareRoot()
            let gain = pow(10, db / 20) / max(rms, 1e-9)
            for (i, v) in voice.enumerated() where 8 * 16_000 + i < mic.count { near[8 * 16_000 + i] = v * gain }
            for i in mic.indices { mic[i] += near[i] }
        }

        var gate = EchoGate()
        var out = [Float](repeating: 0, count: mic.count)
        var report: [String] = []
        let second = 16_000
        for start in stride(from: 0, to: mic.count, by: 1_600) {
            let end = min(start + 1_600, mic.count)
            gate.addFarEnd(Array(far[start..<end]), at: start)
            if let o = gate.processMic(Array(mic[start..<end]), at: start) {
                for (i, s) in o.samples.enumerated() where o.position + i < out.count { out[o.position + i] = s }
            }
            if end % second == 0 {
                let t = end / second - 1
                func db(_ x: ArraySlice<Float>) -> Float { 10 * log10(max(x.reduce(0) { $0 + $1 * $1 } / Float(x.count), 1e-12)) }
                let range = (t * second)..<((t + 1) * second)
                report.append(String(
                    format: "%2ds far %4.0f mic %4.0f out %4.0f | delay %@ level %@ gated %d/%d",
                    t, db(far[range]), db(mic[range]), db(out[range]),
                    gate.delay.map(String.init) ?? "-", gate.echoLevel.map { String(format: "%.2f", $0) } ?? "-",
                    gate.stats.gated, gate.stats.farEndFrames
                ))
            }
        }
        print("replay:\n" + report.joined(separator: "\n"))
        // What would reach the transcript as "Me": utterances in the gated mic, transcribed.
        if let model = SpeechModel.catalog.first(where: ModelStore.isComplete) {
            let transcriber = try await Transcriber.load(model)
            var segmenter = Segmenter()
            var utterances = segmenter.push(out)
            if let last = segmenter.flush() { utterances.append(last) }
            for u in utterances {
                let text = try await transcriber.transcribe(u.samples, language: "en").map(\.text).joined(separator: " ")
                print(String(format: "replay: Me %5.2fs–%5.2fs: %@", Double(u.startMs) / 1000, Double(u.endMs) / 1000, text))
            }
        }
        if near.contains(where: { $0 != 0 }) {
            // How much of the near-end speech survives: correlate the output with it over 8–12 s.
            let r = (8 * 16_000)..<min(12 * 16_000, mic.count)
            let dot = r.reduce(Float(0)) { $0 + out[$1] * near[$1] }
            let energy = r.reduce(Float(0)) { $0 + near[$1] * near[$1] }
            print(String(format: "replay: near-end kept %.0f%% (output projected onto it)", 100 * dot / max(energy, 1e-12)))
        }
    }
}
