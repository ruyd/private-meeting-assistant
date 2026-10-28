import AVFoundation
import Foundation
import Testing
@testable import Private_Meeting_Assistant

/// Diagnostic, not part of the normal run: replays a capture-test recording (mic.wav and system.wav,
/// timeline-aligned) through the echo gate, with and without the echo canceller, and prints what
/// reaches the transcript as "Me". Run with
/// `TEST_RUNNER_ECHO_REPLAY_DIR=<folder> xcodebuild test -only-testing:…/EchoReplayTests`.
/// `TEST_RUNNER_ECHO_REPLAY_NEAR_WAV=<wav> TEST_RUNNER_ECHO_REPLAY_NEAR_DB=<dBFS>` mixes in a voice
/// from 8 s, as if you talked over the far end, and reports how much of it survives.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ECHO_REPLAY_DIR"] != nil))
struct EchoReplayTests {
    private static let rate = 16_000

    private func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func gated(mic: [Float], far: [Float], stages: EchoGate.Stages) -> [Float] {
        var gate = EchoGate(stages: stages)
        if stages.cancel, ProcessInfo.processInfo.environment["ECHO_REPLAY_TRACE"] != nil {
            gate.trace = { f, p, t, echo in
                guard (267...300).contains(f) else { return }
                func db(_ x: Float) -> String { String(format: "%4.0f", 10 * log10(max(x, 1e-12))) }
                print("trace: \(f) judged \(db(p)) threshold \(t.map(db) ?? "  -") \(echo ? "GATED" : "pass")")
            }
        }
        var out = [Float](repeating: 0, count: mic.count)
        func place(_ o: EchoGate.Output?) {
            guard let o else { return }
            for (i, s) in o.samples.enumerated() where o.position + i < out.count { out[o.position + i] = s }
        }
        for start in stride(from: 0, to: mic.count, by: 1_600) {
            let end = min(start + 1_600, mic.count)
            gate.addFarEnd(Array(far[start..<end]), at: start)
            place(gate.processMic(Array(mic[start..<end]), at: start))
        }
        place(gate.flush())
        let st = gate.stats
        print(String(format: "replay:   gate: delay %d, level %.2f, gated %d/%d far-end frames; canceller gain %.1f, removed %.1f dB while the far end played",
                     gate.delay ?? -1, gate.echoLevel ?? -1, st.gated, st.farEndFrames, st.cancellerGain,
                     st.cancelledEcho > 0 ? 10 * log10(st.rawEcho / st.cancelledEcho) : 0))
        return out
    }

    @Test func farEndTranscript() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_REPLAY_DIR"]!)
        let far = try load(dir.appending(path: "system.wav"))
        guard let model = SpeechModel.catalog.first(where: ModelStore.isComplete) else { return }
        let lines = try await Transcriber.load(model).transcribe(Array(far[0..<min(15 * Self.rate, far.count)]), language: "en")
        print("far: kept \(lines.map(\.text))")
    }

    @Test func cancellerSweep() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_REPLAY_DIR"]!)
        let mic = try load(dir.appending(path: "mic.wav"))
        var far = try load(dir.appending(path: "system.wav"))
        far += [Float](repeating: 0, count: max(mic.count - far.count, 0))
        let n = min(mic.count, 20 * Self.rate) / EchoCanceller.frameSize * EchoCanceller.frameSize
        func db(_ x: ArraySlice<Float>) -> Float { 10 * log10(max(x.reduce(0) { $0 + $1 * $1 } / Float(x.count), 1e-12)) }
        for (length, predelay) in [(8_192, 0), (2_048, 7 * 480), (2_048, 8 * 480), (4_096, 7 * 480)] {
            for gain: Float in [1, 5] {
                // Far end shifted later by `predelay` samples, so the filter only has to model what follows.
                let shifted = [Float](repeating: 0, count: predelay) + far[0..<(n - predelay)].map { $0 * gain }
                let residual = EchoCanceller(filterLength: length).cancel(mic: mic[0..<n], farEnd: shifted[...])
                let erle = stride(from: 0, to: 20, by: 4).map { t -> String in
                    let r = (t * Self.rate)..<min((t + 4) * Self.rate, n)
                    return String(format: "%.1f", db(mic[r]) - db(residual[r]))
                }
                print("sweep: taps \(length) predelay \(predelay / 16) ms far×\(Int(gain)) removes dB per 4 s: \(erle.joined(separator: " "))")
            }
        }
    }

    @Test func replay() async throws {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: env["ECHO_REPLAY_DIR"]!)
        var mic = try load(dir.appending(path: "mic.wav"))
        var far = try load(dir.appending(path: "system.wav"))
        far += [Float](repeating: 0, count: max(mic.count - far.count, 0))

        var near = [Float](repeating: 0, count: mic.count)
        if let db = env["ECHO_REPLAY_NEAR_DB"].flatMap(Float.init), let path = env["ECHO_REPLAY_NEAR_WAV"] {
            let voice = try load(URL(fileURLWithPath: path))
            let rms = (voice.reduce(0) { $0 + $1 * $1 } / Float(voice.count)).squareRoot()
            let gain = pow(10, db / 20) / max(rms, 1e-9)
            for (i, v) in voice.enumerated() where 8 * Self.rate + i < mic.count { near[8 * Self.rate + i] = v * gain }
            for i in mic.indices { mic[i] += near[i] }
        }

        var transcriber: Transcriber?
        if let model = SpeechModel.catalog.first(where: ModelStore.isComplete) {
            transcriber = try await Transcriber.load(model)
        }
        var configurations: [(String, EchoGate.Stages)] = [
            ("gate only", .init(cancel: false, suppressResidual: false, gate: true)),
            ("canceller + gate", .init(cancel: true, suppressResidual: false, gate: true, gateOnlyWhileLearning: false)),
            ("canceller + band suppression, gate only while learning", .init(gateOnlyWhileLearning: true)),
            ("canceller + band suppression + gate, margin 8 — default", .init()),
        ]
        // ECHO_REPLAY_SWEEP=1: band suppression without the gate at several strengths instead.
        if env["ECHO_REPLAY_SWEEP"] != nil {
            configurations = [(-40, -15), (-60, -25), (-60, -40), (-80, -40), (-80, -60)].map { quiet, talking in
                ("suppress \(quiet)/\(talking) dB", .init(cancel: true, suppressResidual: true, gate: false, gateOnlyWhileLearning: false,
                                                       echoSuppression: Int32(quiet), echoSuppressionWhileTalking: Int32(talking)))
            }
        }
        var themLines: [TranscriptLine]?
        for (name, stages) in configurations {
            let out = gated(mic: mic, far: far, stages: stages)
            print("replay [\(name)]")
            if near.contains(where: { $0 != 0 }) {
                let r = (8 * Self.rate)..<min(12 * Self.rate, mic.count)
                let dot = r.reduce(Float(0)) { $0 + out[$1] * near[$1] }
                let energy = r.reduce(Float(0)) { $0 + near[$1] * near[$1] }
                print(String(format: "replay:   your voice kept: %.0f%%", 100 * dot / max(energy, 1e-12)))
            }
            guard let transcriber else { continue }
            // Transcribe both sides as the app does, then apply the transcript-level echo filter.
            func lines(_ samples: [Float], _ source: AudioSource) async throws -> [TranscriptLine] {
                var segmenter = Segmenter()
                var utterances = segmenter.push(samples)
                if let last = segmenter.flush() { utterances.append(last) }
                var result: [TranscriptLine] = []
                for u in utterances {
                    // Loudness of the utterance's louder frames (90th percentile), in dBFS.
                    let frames = stride(from: 0, to: u.samples.count - 480, by: 480).map { o in
                        u.samples[o..<(o + 480)].reduce(Float(0)) { $0 + $1 * $1 } / 480
                    }.sorted()
                    let level = frames.isEmpty ? -120 : 10 * log10(max(frames[frames.count * 9 / 10], 1e-12))
                    for l in try await transcriber.transcribe(u.samples, language: "en") {
                        result.append(TranscriptLine(source: source, startMs: u.startMs + Int(l.start * 1000), endMs: u.startMs + Int(l.end * 1000),
                                                     text: source == .mic ? String(format: "[%.0f dBFS] ", level) + l.text : l.text))
                    }
                }
                return result
            }
            if themLines == nil { themLines = try await lines(far, .system) }
            for line in try await lines(out, .mic) {
                let dropped = EchoText.isEcho(line, of: themLines ?? [])
                print(String(format: "replay:   Me %5.2fs%@: %@", Double(line.startMs) / 1000, dropped ? " (dropped as echo text)" : "", line.text))
            }
        }
    }
}
