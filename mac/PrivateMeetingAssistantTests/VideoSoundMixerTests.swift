import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import Private_Meeting_Assistant

struct VideoSoundMixerTests {
    private let dir = FileManager.default.temporaryDirectory.appending(path: "mixer-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// A 3 s video: gray frames at 30 fps and a 440 Hz tone at 48 kHz stereo, standing in for the app.
    private func makeVideo(_ url: URL, seconds: Double = 3) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let picture = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: picture, sourcePixelBufferAttributes: nil)
        let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
        writer.add(picture)
        writer.add(sound)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        var frame = 0, audioAt = 0
        let frames = Int(seconds * 30), samples = Int(seconds * 48_000)
        while frame < frames || audioAt < samples {
            if frame < frames, picture.isReadyForMoreMediaData {
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
                CVPixelBufferLockBaseAddress(buffer!, [])
                memset(CVPixelBufferGetBaseAddress(buffer!), 128, CVPixelBufferGetDataSize(buffer!))
                CVPixelBufferUnlockBaseAddress(buffer!, [])
                adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
                frame += 1
                if frame == frames { picture.markAsFinished() }
            }
            if audioAt < samples, sound.isReadyForMoreMediaData {
                let count = min(1_024, samples - audioAt)
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                pcm.frameLength = AVAudioFrameCount(count)
                for i in 0..<count {
                    let v = 0.2 * sin(2 * Float.pi * 440 * Float(audioAt + i) / 48_000)
                    pcm.floatChannelData![0][i] = v
                    pcm.floatChannelData![1][i] = v
                }
                sound.append(try #require(sampleBuffer(pcm, at: audioAt)))
                audioAt += count
                if audioAt == samples { sound.markAsFinished() }
            }
            if !picture.isReadyForMoreMediaData && !sound.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        }
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
    }

    private func sampleBuffer(_ pcm: AVAudioPCMBuffer, at position: Int) -> CMSampleBuffer? {
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: CMTimeValue(position), timescale: 48_000), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: pcm.format.formatDescription, sampleCount: CMItemCount(pcm.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sample) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList) == noErr else { return nil }
        return sample
    }

    /// Level of `hz` (Goertzel) in mono samples.
    private func level(_ x: ArraySlice<Float>, hz: Double, rate: Double = 48_000) -> Double {
        let k = 2 * cos(2 * Double.pi * hz / rate)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s = Double(v) + k * s1 - s2
            s2 = s1
            s1 = s
        }
        return (s1 * s1 + s2 * s2 - k * s1 * s2).squareRoot() / Double(x.count)
    }

    @Test(.timeLimit(.minutes(2)))
    func mixesTheMicInAtItsOffset() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appending(path: "video.mp4")
        try await makeVideo(video)

        // The mic: a 1 kHz tone from 1 s into the video (its file starts 0.5 s before the video).
        let take = try VideoMicRecorder()
        let tone = (0..<(16_000 * 3)).map { i in i < 24_000 ? Float(0) : 0.3 * sin(2 * Float.pi * 1_000 * Float(i) / 16_000) }
        for offset in stride(from: 0, to: tone.count, by: 1_600) {
            take.append(Array(tone[offset..<min(offset + 1_600, tone.count)]), at: 100_000 + offset)
        }
        #expect(take.finish() == 100_000)

        let mixed = dir.appending(path: "mixed.mp4")
        try await VideoSoundMixer.mix(video: video, mic: take.url, micStartsAt: -0.5, into: mixed)

        let asset = AVURLAsset(url: mixed)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3) < 0.1, "duration \(duration)")
        let file = try AVAudioFile(forReading: mixed)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        func at(_ from: Double, _ to: Double) -> ArraySlice<Float> { left[Int(from * 48_000)..<Int(to * 48_000)] }
        print(String(format: "mixer: 440 Hz %.3f / %.3f, 1 kHz before %.4f, after %.3f",
                     level(at(0.2, 0.8), hz: 440), level(at(1.2, 2.5), hz: 440), level(at(0.2, 0.8), hz: 1_000), level(at(1.2, 2.5), hz: 1_000)))
        #expect(level(at(0.2, 0.8), hz: 440) > 0.05, "the app's sound is kept")
        #expect(level(at(1.2, 2.5), hz: 440) > 0.05)
        #expect(level(at(0.2, 0.8), hz: 1_000) < 0.01, "no mic before it started")
        #expect(level(at(1.2, 2.5), hz: 1_000) > 0.08, "the mic from 1 s on")
    }

    @Test(.timeLimit(.minutes(2)))
    func makesAThumbnailOnce() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appending(path: MeetingFiles.videosFolder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appending(path: "00.00.59.mp4")
        try await makeVideo(video, seconds: 2)

        let thumbnail = try #require(await VideoThumbnail.ensure(for: video))
        #expect(thumbnail.lastPathComponent == ".00.00.59.jpg")
        let image = try #require(ScreenCapture.thumbnail(of: thumbnail))
        #expect(image.width == 64 && image.height == 64)
        let made = try thumbnail.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try await Task.sleep(for: .milliseconds(20))
        await VideoThumbnail.ensure(for: video)
        #expect(try thumbnail.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == made, "not made again")
        // The meeting's videos are still just the one.
        #expect(MeetingFiles.videos(in: dir).map { $0.url.lastPathComponent } == ["00.00.59.mp4"])
    }
}
