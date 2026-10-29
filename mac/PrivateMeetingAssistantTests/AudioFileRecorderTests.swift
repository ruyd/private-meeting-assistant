import AVFoundation
import Foundation
import Testing
@testable import Private_Meeting_Assistant

struct AudioFileRecorderTests {
    private func tone(_ seconds: Double, frequency: Float) -> [Float] {
        (0..<Int(16_000 * seconds)).map { 0.3 * sin(2 * .pi * frequency * Float($0) / 16_000) }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
    }

    @Test func mixesSourcesOnTheMeetingTimeline() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let start = mach_absolute_time()
        let recorder = try AudioFileRecorder(url: url, startHostTime: start, isOn: true)

        func feed(_ source: AudioSource, _ samples: [Float], at seconds: Double) {
            for offset in stride(from: 0, to: samples.count, by: 1_600) {
                let hostTime = start + AVAudioTime.hostTime(forSeconds: seconds + Double(offset) / 16_000)
                recorder.append(AudioChunk(source: source, samples: Array(samples[offset..<min(offset + 1_600, samples.count)]), hostTime: hostTime))
            }
        }
        // 0–2 s: the mic. 3–4 s: system audio after a gap (it only flows while something plays).
        feed(.mic, tone(2, frequency: 300), at: 0)
        feed(.system, tone(1, frequency: 500), at: 3)
        // 4–5 s: saving turned off, the mic still talking; 5–6 s: on again.
        recorder.setOn(false)
        feed(.mic, tone(1, frequency: 300), at: 4)
        recorder.setOn(true)
        feed(.mic, tone(1, frequency: 300), at: 5)
        await recorder.finish()

        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let rate = Int(file.processingFormat.sampleRate)
        func second(_ s: Double) -> ArraySlice<Float> {
            let from = Int((s + 0.1) * Double(rate)), to = Int((s + 0.9) * Double(rate))
            return samples[min(from, samples.count)..<min(to, samples.count)]
        }

        #expect(abs(Double(samples.count) / Double(rate) - 6) < 0.2, "\(Double(samples.count) / Double(rate)) s")
        #expect(rms(second(0)) > 0.15)
        #expect(rms(second(2)) < 0.01, "the gap is silent")
        #expect(rms(second(3)) > 0.15, "system audio lands at 3 s")
        #expect(rms(second(4)) < 0.01, "saving was off")
        #expect(rms(second(5)) > 0.15)
    }

    /// Chunk timestamps drift a few samples against the audio's own length (the device clock, the
    /// resampler). Placing each chunk exactly by its timestamp left millisecond gaps of silence and
    /// overlaps, heard as crackling; the file should be one continuous tone.
    @Test func jitteryTimestampsMakeNoGaps() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try AudioFileRecorder(url: url, startHostTime: mach_absolute_time(), isOn: true)
        let toneSamples = tone(6, frequency: 440)
        var position = 0
        for (i, offset) in stride(from: 0, to: toneSamples.count, by: 1_600).enumerated() {
            // Timestamps wander up to ±12 samples (0.75 ms) from where the samples really belong.
            let drift = [0, 7, -5, 12, -12, 3][i % 6]
            recorder.append(Array(toneSamples[offset..<min(offset + 1_600, toneSamples.count)]), from: .mic, at: position + drift)
            position += 1_600
        }
        await recorder.finish()

        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        // Skip the encoder's start and end; in between, no millisecond of the tone may go quiet.
        let body = samples[3_200..<(samples.count - 3_200)]
        let quietMs = stride(from: body.startIndex, to: body.endIndex - 16, by: 16).filter { rms(body[$0..<$0 + 16]) < 0.05 }.count
        #expect(quietMs == 0, "\(quietMs) quiet milliseconds inside the tone")
    }

    @Test func transcriptLinksAudioAndVideos() {
        let meeting = Meeting(
            id: 1, title: "Demo", startedAt: Date(), summaryStatus: "none", segmentCount: 1, durationMs: 60_000,
            folder: URL(fileURLWithPath: "/tmp/demo")
        )
        let segments = [Segment(id: 1, meetingID: 1, source: .mic, startMs: 20_000, endMs: 22_000, text: "Here's the demo.", speaker: "Me")]
        let video = MeetingScreenshot(url: URL(fileURLWithPath: "/tmp/demo/video/00.00.10.mp4"), atMs: 10_000)
        let md = MeetingFiles.transcriptMarkdown(meeting, segments, videos: [video], hasAudio: true)
        #expect(md.contains("*Audio: [audio.m4a](<audio.m4a>)*"))
        #expect(md.contains("*Video from 00:10: [00.00.10.mp4](<video/00.00.10.mp4>)*\n\n**[00:20] Me:**"))
    }
}

/// Records the test host's own window, so it needs the app's Screen Recording permission.
@MainActor
@Suite(.enabled(if: ScreenCapture.hasPermission, "Screen Recording not allowed"))
struct WindowRecorderTests {
    @Test(.timeLimit(.minutes(1)))
    func recordsAWindowToMP4() async throws {
        let bundleID = try #require(Bundle.main.bundleIdentifier)
        let url = FileManager.default.temporaryDirectory.appending(path: "video-\(UUID().uuidString)/00.00.05.mp4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let recorder = try await WindowRecorder.start(bundleID: bundleID, appName: "Test host", micUID: nil, to: url)
        try await Task.sleep(for: .seconds(2))
        await recorder.stop()
        #expect(recorder.failure == nil)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        #expect(!video.isEmpty)
        #expect(duration > 1, "\(duration) s")
    }
}
