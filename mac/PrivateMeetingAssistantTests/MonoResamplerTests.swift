import AVFoundation
import Testing
@testable import Private_Meeting_Assistant

struct MonoResamplerTests {
    /// Builds `seconds` of a stereo sine (left and right identical) at `rate`.
    private func stereoSine(rate: Double, hz: Double, seconds: Double, amplitude: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = amplitude * Float(sin(2 * .pi * hz * Double(i) / rate)) }
        }
        return buffer
    }

    /// Splits a buffer into consecutive slices of `size` frames, like a capture callback delivers.
    private func slices(of buffer: AVAudioPCMBuffer, size: Int) -> [AVAudioPCMBuffer] {
        stride(from: 0, to: Int(buffer.frameLength), by: size).map { start in
            let n = min(size, Int(buffer.frameLength) - start)
            let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(n))!
            slice.frameLength = AVAudioFrameCount(n)
            for ch in 0..<Int(buffer.format.channelCount) {
                slice.floatChannelData![ch].update(from: buffer.floatChannelData![ch] + start, count: n)
            }
            return slice
        }
    }

    @Test func streams48kStereoTo16kMono() throws {
        let resampler = MonoResampler()
        let input = stereoSine(rate: 48_000, hz: 440, seconds: 2, amplitude: 0.5)
        var out: [Float] = []
        for slice in slices(of: input, size: 512) { out += try resampler.convert(slice) }

        // Length: 2 s at 16 kHz, minus at most the converter's filter delay.
        #expect(abs(out.count - 32_000) < 200)

        // Downmix keeps the level of identical channels, and the tone survives: RMS of a 0.5 sine is ~0.354.
        let steady = Array(out[1_000..<(out.count - 1_000)])
        #expect(abs(LevelMeter.rms(steady) - 0.354) < 0.03)

        // Zero crossings give the frequency: 440 Hz has 880 per second.
        let crossings = zip(steady, steady.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        let hz = Double(crossings) / 2 / (Double(steady.count) / 16_000)
        #expect(abs(hz - 440) < 5)
    }

    @Test func passesThrough16kMono() throws {
        let resampler = MonoResampler()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        for i in 0..<1_600 { buffer.floatChannelData![0][i] = 0.25 }
        let out = try resampler.convert(buffer)
        #expect(out.count == 1_600)
        #expect(out.allSatisfy { abs($0 - 0.25) < 1e-4 })
    }

    @Test func meterScale() {
        #expect(LevelMeter.display(1) == 1)
        #expect(LevelMeter.display(0) == 0)
        #expect(abs(LevelMeter.display(0.001) - 0) < 0.01)   // -60 dBFS
        #expect(abs(LevelMeter.display(0.0316) - 0.5) < 0.01) // -30 dBFS
    }
}
