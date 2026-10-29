import AVFoundation
import Foundation
import Testing
@testable import Private_Meeting_Assistant

struct VolumeSliderTests {
    @Test func hundredPercentSitsInTheMiddle() {
        #expect(VolumeSlider.position(1) == 0.5)
        #expect(VolumeSlider.position(0) == 0)
        #expect(VolumeSlider.position(1.5) == 1)
        #expect(VolumeSlider.position(0.5) == 0.25)
        #expect(abs(VolumeSlider.position(1.1) - 0.6) < 1e-9)
        #expect(VolumeSlider.volume(0.25) == 0.5)
        #expect(VolumeSlider.volume(1) == 1.5)
        #expect(VolumeSlider.volume(0.51) == 1, "snaps to 100% close by")
        #expect(abs(VolumeSlider.volume(0.6) - 1.1) < 1e-9)
    }
}

@MainActor
struct InlineAudioPlayerTests {
    @Test func loadsAndSeeksWithoutPlaying() throws {
        let url = try #require(Bundle(for: PlayerBundleToken.self).url(forResource: "jfk", withExtension: "wav"))
        let player = InlineAudioPlayer()
        player.load(url)
        #expect(abs(player.duration - 11) < 0.1, "\(player.duration)")
        player.seek(to: 4.5)
        #expect(player.currentTime == 4.5)
        #expect(!player.isPlaying)
        player.seek(to: 99)
        #expect(player.currentTime == player.duration)
        player.volume = 1.5
        player.volume = 0
        player.stop()
    }
}

private final class PlayerBundleToken {}
