import Foundation
import Testing
@testable import Private_Meeting_Assistant

struct LowCutFilterTests {
    private func tone(_ hz: Double, seconds: Double = 1) -> [Float] {
        (0..<Int(16_000 * seconds)).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / 16_000)) }
    }

    /// Level change in dB once the filter has settled (the first quarter second is skipped).
    private func gain(_ hz: Double) -> Double {
        let input = tone(hz)
        let output = LowCutFilter().process(input)
        func rms(_ x: [Float]) -> Double { (x[4_000...].reduce(0) { $0 + Double($1 * $1) } / Double(x.count - 4_000)).squareRoot() }
        return 20 * log10(rms(output) / rms(input))
    }

    @Test func cutsRumbleAndKeepsVoices() {
        #expect(gain(30) < -30, "fan hum")
        #expect(gain(50) < -20)
        #expect(abs(gain(100) + 3) < 0.5, "-3 dB at the cutoff")
        #expect(abs(gain(200)) < 0.5, "a low voice's pitch")
        #expect(abs(gain(1_000)) < 0.1)
        #expect(abs(gain(4_000)) < 0.1)
    }

    @Test func chunksContinueSeamlessly() {
        let input = tone(150) + tone(1_000, seconds: 0.5)
        let whole = LowCutFilter().process(input)
        let filter = LowCutFilter()
        var chunked: [Float] = []
        for offset in stride(from: 0, to: input.count, by: 1_600) {
            chunked += filter.process(Array(input[offset..<min(offset + 1_600, input.count)]))
        }
        #expect(chunked == whole)
    }
}
