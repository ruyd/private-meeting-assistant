import AVFoundation
import Foundation
import Speech
import Synchronization
import Testing
@testable import Private_Meeting_Assistant

/// Apple's on-device recognizer, fed at real-time speed like the microphone: how soon words show up.
/// Runs where the recognizer is available (it downloads its English model the first time).
@Suite(.enabled(if: SpeechTranscriber.isAvailable, "no on-device speech recognizer"))
struct LiveTranscriberTests {
    private func synthesize(_ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appending(path: "say-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Daniel", "-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000", text]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    @Test(.timeLimit(.minutes(3)))
    func wordsArriveWhileSpeaking() async throws {
        let sentence = "We decided to submit the App Store build on Monday and price it at nine dollars."
        let speech = try synthesize(sentence)
        let audio = [Float](repeating: 0, count: 8_000) + speech + [Float](repeating: 0, count: 24_000)
        let speechStart = 0.5, speechEnd = 0.5 + Double(speech.count) / 16_000

        let fragments = Mutex<[(at: Double, fragment: LiveTranscriber.Fragment)]>([])
        let whisperLines = Mutex<[(at: Double, text: String)]>([])
        let clock = ContinuousClock()
        let origin = Mutex<ContinuousClock.Instant?>(nil)
        @Sendable func elapsed() -> Double {
            let now = clock.now
            return origin.withLock { $0.map { (now - $0) / .seconds(1) } } ?? 0
        }
        let live = try #require(await LiveTranscriber.start(locale: Locale(identifier: "en-US")) { fragment in
            let t = elapsed()
            fragments.withLock { $0.append((t, fragment)) }
        })
        // Today's path, for comparison: Whisper on each utterance once the speaker pauses.
        let model = SpeechModel.catalog.first(where: ModelStore.isComplete)
        let start = mach_absolute_time()
        var pipeline: TranscriptionPipeline?
        if let model {
            pipeline = TranscriptionPipeline(
                transcriber: try await Transcriber.load(model), language: "en", startHostTime: start, removeEcho: false,
                onLine: { line in let t = elapsed(); whisperLines.withLock { $0.append((t, line.text)) } }, onBacklog: { _ in }
            )
        }
        origin.withLock { $0 = clock.now }
        for offset in stride(from: 0, to: audio.count, by: 1_600) {
            let chunk = Array(audio[offset..<min(offset + 1_600, audio.count)])
            // Capture timestamps wander a few samples, sometimes before where the last chunk ended.
            live.append(chunk, at: max(offset + [0, 7, -5, 12, -12, 3][(offset / 1_600) % 6], 0))
            pipeline?.append(AudioChunk(source: .mic, samples: chunk, hostTime: start + AVAudioTime.hostTime(forSeconds: Double(offset) / 16_000)))
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(1))
        await live.stop()
        await pipeline?.finish()
        for w in whisperLines.withLock({ $0 }) { print(String(format: "whisper: +%.2fs %@", w.at, w.text)) }
        if let w = whisperLines.withLock({ $0.first }) {
            print(String(format: "whisper: first line at %.2fs (%.2fs after speech began, %.2fs after it ended)", w.at, w.at - speechStart, w.at - speechEnd))
        }

        let got = fragments.withLock { $0 }
        for g in got { print(String(format: "live: +%.2fs [%.2f-%.2f] %@ %@", g.at, Double(g.fragment.startMs) / 1000, Double(g.fragment.endMs) / 1000, g.fragment.isFinal ? "final" : "volatile", g.fragment.text)) }
        let first = try #require(got.first)
        print(String(format: "live: speech %.2f-%.2fs; first words at %.2fs (%.2fs after speech began); \"Monday\" at %.2fs",
                     speechStart, speechEnd, first.at, first.at - speechStart, got.first { $0.fragment.text.contains("Monday") }?.at ?? -1))
        #expect(first.at - speechStart < 1.5, "first words should show within a second and a half of speech starting")
        #expect(got.contains { $0.fragment.text.lowercased().contains("monday") })
        #expect(got.contains { $0.fragment.isFinal }, "it should keep listening to the end despite the jitter")
        // Fragments are placed on the meeting timeline, by the positions they were fed at.
        #expect(abs(Double(first.fragment.startMs) / 1000 - speechStart) < 1)
    }
}

struct LiveFragmentTests {
    @Test func whisperReplacesFragmentsOnceItPassesTheirMiddle() {
        // Apple's final fragment spans two of Whisper's lines and ends just after them.
        let long = LiveTranscriber.Fragment(startMs: 3_000, endMs: 18_600, text: "Revenue grew…", isFinal: true)
        #expect(!long.isCovered(byWhisperReaching: 9_000))
        #expect(long.isCovered(byWhisperReaching: 18_200))
        // Words still being spoken stay until Whisper gets to them.
        let now = LiveTranscriber.Fragment(startMs: 18_000, endMs: 21_000, text: "and next", isFinal: false)
        #expect(!now.isCovered(byWhisperReaching: 18_200))
    }

    @Test func whisperLinesWithNoWordsHeardAreSuspect() {
        func line(_ start: Int, _ end: Int) -> TranscriptLine { TranscriptLine(source: .mic, startMs: start, endMs: end, text: "Thank you.") }
        func fragment(_ start: Int, _ end: Int, _ text: String, final: Bool = true) -> LiveTranscriber.Fragment {
            LiveTranscriber.Fragment(startMs: start, endMs: end, text: text, isFinal: final)
        }
        var heard = LiveTranscriber.Heard(from: 0)
        heard.add(fragment(4_860, 7_800, "Okay, this is"))
        // Fan noise from 12 s: Whisper wrote a line, the recognizer nothing.
        #expect(heard.verdict(on: line(12_000, 13_500)) == .nothing)
        // Real speech, timed a little differently by the two.
        #expect(heard.verdict(on: line(4_400, 7_700)) == .heard)
        #expect(heard.verdict(on: line(8_100, 9_000)) == .heard)
        // The recognizer wrote "Um" over the fan: not words.
        heard.add(fragment(550, 6_610, "Um."))
        // Noise from the very start, as with a fan above the mic.
        #expect(heard.verdict(on: line(533, 2_033)) == .nothing)
        // Too near the start of listening to tell.
        #expect(heard.verdict(on: line(0, 1_000)) == .heard)
        // Words in progress stretch back too far to rule on yet: "Thank you." at 3.9 s over noise,
        // just before speech the recognizer is still working on.
        heard.add(fragment(0, 21_000, "We decided to", final: false))
        #expect(heard.verdict(on: line(19_000, 20_000)) == .unsure)
        heard.add(fragment(21_800, 25_000, "We decided to submit"))
        #expect(heard.verdict(on: line(19_000, 20_000)) == .nothing)
        heard.until = 30_500
        // Noise running into the end of the recording is judged up to just before it…
        #expect(heard.verdict(on: line(28_987, 30_507)) == .nothing)
        // …but a last word said just before stopping is kept.
        #expect(heard.verdict(on: line(29_700, 30_400)) == .heard)
    }

}
