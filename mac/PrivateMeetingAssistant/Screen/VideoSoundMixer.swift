import AVFoundation
import CoreImage
import OSLog

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "video")

/// Finishes a recorded video. "Record video + mic": the app's sound (48 kHz stereo) and the
/// echo-removed mic (16 kHz mono, from `VideoMicRecorder`) are mixed and encoded as the video's sound.
/// "Cut size": the picture is cropped (`VideoArea.verticalCut`), scaled to fit 1280×720
/// and encoded at 2.5 Mbit/s, instead of copied as it is (ScreenCaptureKit's full window, 2406×2166
/// at 30–40 Mbit/s for a browser on this Mac).
enum VideoSoundMixer {
    /// The mic to mix in, and where its first sample plays in the video (seconds; negative: before).
    struct Mic {
        let url: URL
        let startsAt: Double
    }

    /// How to re-encode the picture.
    struct Picture {
        /// The part to keep, as fractions of the frame with the origin at the top left; nil: all.
        var crop: CGRect?
        var maxWidth = 1_280
        var maxHeight = 720
        var bitRate = 2_500_000
    }

    static let rate = 48_000
    private static let channels = 2
    private static let block = 1_024

    enum Failure: LocalizedError {
        case noPicture, cantWrite(String)
        var errorDescription: String? {
            switch self {
            case .noPicture: "The video has no picture."
            case .cantWrite(let why): "Couldn't finish the video: \(why)"
            }
        }
    }

    /// Writes `video` with `mic` mixed into its sound to `output`. The mic file's first sample plays
    /// at `micStartsAt` seconds into the video (negative: before it began).
    static func mix(video: URL, mic: URL, micStartsAt: Double, into output: URL) async throws {
        try await rewrite(video: video, mic: Mic(url: mic, startsAt: micStartsAt), picture: nil, into: output)
    }

    /// Writes `video` to `output` with `mic` mixed into its sound (if any) and its picture re-encoded
    /// as `picture` says (nil: copied as it is).
    static func rewrite(video: URL, mic: Mic?, picture: Picture?, into output: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noPicture }
        let appTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration).seconds
        let hint = try await videoTrack.load(.formatDescriptions).first
        let transform = try await videoTrack.load(.preferredTransform)
        let natural = try await videoTrack.load(.naturalSize)
        let resize = picture.map { Resize($0, from: natural) }

        let reader = try AVAssetReader(asset: asset)
        let pictures = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: resize.map { _ in
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        })
        reader.add(pictures)
        var appSound: AVAssetReaderTrackOutput?
        if let appTrack {
            let output = AVAssetReaderTrackOutput(track: appTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            reader.add(output)
            appSound = output
        }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let pictureInput = resize.map { r in
            AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: r.width, AVVideoHeightKey: r.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: r.bitRate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ])
        } ?? AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        pictureInput.transform = transform
        pictureInput.expectsMediaDataInRealTime = false
        let soundInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 192_000,
        ])
        soundInput.expectsMediaDataInRealTime = false
        writer.add(pictureInput)
        writer.add(soundInput)

        guard reader.startReading() else { throw Failure.cantWrite(reader.error?.localizedDescription ?? "reading") }
        guard writer.startWriting() else { throw Failure.cantWrite(writer.error?.localizedDescription ?? "writing") }
        writer.startSession(atSourceTime: .zero)

        let sound = try SoundSource(app: appSound, mic: mic, frames: Int(duration * Double(rate)))
        // Each input is fed from its own queue; its source is only ever read there.
        let picturePump = Pump(input: pictureInput) {
            guard let sample = pictures.copyNextSampleBuffer() else { return nil }
            return resize.map { $0.apply(to: sample) } ?? sample
        }
        let soundPump = Pump(input: soundInput) { sound.next() }
        async let picturesDone: Void = picturePump.run(queue: "video-mix-picture")
        async let soundDone: Void = soundPump.run(queue: "video-mix-sound")
        _ = await (picturesDone, soundDone)
        if reader.status == .failed { throw Failure.cantWrite(reader.error?.localizedDescription ?? "reading") }
        await writer.finishWriting()
        if writer.status != .completed { throw Failure.cantWrite(writer.error?.localizedDescription ?? "writing") }
    }

    /// Crops and scales decoded frames for re-encoding.
    private final class Resize: @unchecked Sendable {
        let width: Int
        let height: Int
        let bitRate: Int
        /// The part of the frame kept, in Core Image's coordinates (origin at the bottom left).
        private let source: CGRect
        private let context = CIContext()
        private var pool: CVPixelBufferPool?
        private var format: CMVideoFormatDescription?

        init(_ picture: Picture, from natural: CGSize) {
            let crop = picture.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let x = (crop.minX * natural.width).rounded(), w = (crop.width * natural.width).rounded()
            let h = (crop.height * natural.height).rounded()
            let y = (natural.height - (crop.minY * natural.height).rounded() - h)
            source = CGRect(x: x, y: max(y, 0), width: max(w, 2), height: max(h, 2))
            let scale = min(Double(picture.maxWidth) / source.width, Double(picture.maxHeight) / source.height, 1)
            // Even sizes, as H.264 needs.
            width = max(Int(source.width * scale) / 2 * 2, 2)
            height = max(Int(source.height * scale) / 2 * 2, 2)
            bitRate = picture.bitRate
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary, &pool)
        }

        func apply(to sample: CMSampleBuffer) -> CMSampleBuffer? {
            guard let frame = CMSampleBufferGetImageBuffer(sample), let pool else { return nil }
            var out: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
            let image = CIImage(cvPixelBuffer: frame)
                .cropped(to: source)
                .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / source.width, y: CGFloat(height) / source.height))
            context.render(image, to: out)
            if format == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: out, formatDescriptionOut: &format) }
            guard let format else { return nil }
            var timing = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sample), presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
                decodeTimeStamp: .invalid
            )
            var result: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: out, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result)
            return result
        }
    }

    /// Feeds an input from `next` until it runs out.
    private final class Pump: @unchecked Sendable {
        let input: AVAssetWriterInput
        let next: () -> CMSampleBuffer?

        init(input: AVAssetWriterInput, next: @escaping () -> CMSampleBuffer?) {
            self.input = input
            self.next = next
        }

        func run(queue label: String) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) { [self] in
                    while input.isReadyForMoreMediaData {
                        guard let sample = next(), input.append(sample) else {
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                    }
                }
            }
        }
    }

    /// The mixed sound, a block at a time on the video's timeline (48 kHz stereo, interleaved).
    private final class SoundSource: @unchecked Sendable {
        private let app: AVAssetReaderTrackOutput?
        private let mic: AVAudioFile?
        private let micStartsAt: Double
        private let frames: Int
        private var position = 0
        /// Decoded app sound from frame `appBase` on (interleaved).
        private var appSamples: [Float] = []
        private var appBase = 0
        private var appDone: Bool
        /// Mic samples from mic frame `micBase` on.
        private var micSamples: [Float] = []
        private var micBase = 0
        private let format: CMAudioFormatDescription

        init(app: AVAssetReaderTrackOutput?, mic: Mic?, frames: Int) throws {
            self.app = app
            appDone = app == nil
            self.mic = try mic.map { try AVAudioFile(forReading: $0.url, commonFormat: .pcmFormatFloat32, interleaved: false) }
            micStartsAt = mic?.startsAt ?? 0
            self.frames = frames
            var description = AudioStreamBasicDescription(
                mSampleRate: Double(VideoSoundMixer.rate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * VideoSoundMixer.channels), mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(4 * VideoSoundMixer.channels), mChannelsPerFrame: UInt32(VideoSoundMixer.channels),
                mBitsPerChannel: 32, mReserved: 0
            )
            var format: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            guard let format else { throw Failure.cantWrite("audio format") }
            self.format = format
        }

        func next() -> CMSampleBuffer? {
            guard position < frames else { return nil }
            let count = min(VideoSoundMixer.block, frames - position)
            var out = appFrames(position, count)
            let channels = VideoSoundMixer.channels
            for i in 0..<count where mic != nil {
                let voice = micSample(at: Double(position + i) / Double(VideoSoundMixer.rate))
                for c in 0..<channels {
                    out[i * channels + c] = max(min(out[i * channels + c] + voice, 1), -1)
                }
            }
            let buffer = makeBuffer(out, frames: count, at: position)
            position += count
            return buffer
        }

        /// The app's sound for frames `start..<start+count`, silence where there's none.
        private func appFrames(_ start: Int, _ count: Int) -> [Float] {
            let channels = VideoSoundMixer.channels
            while !appDone, appBase + appSamples.count / channels < start + count {
                guard let sample = app?.copyNextSampleBuffer() else {
                    appDone = true
                    break
                }
                let at = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * Double(VideoSoundMixer.rate)).rounded())
                let decoded = Self.floats(sample)
                if appSamples.isEmpty {
                    appBase = at
                } else {
                    // Gaps in the app's sound (nothing playing) become silence.
                    let end = appBase + appSamples.count / channels
                    if at > end { appSamples += [Float](repeating: 0, count: (at - end) * channels) }
                }
                appSamples += decoded
            }
            var out = [Float](repeating: 0, count: count * channels)
            for i in 0..<count {
                let j = start + i - appBase
                guard j >= 0, j * channels + channels <= appSamples.count else { continue }
                for c in 0..<channels { out[i * channels + c] = appSamples[j * channels + c] }
            }
            // Drop what's been used.
            let used = start + count - appBase
            if used > 0, used * channels <= appSamples.count {
                appSamples.removeFirst(used * channels)
                appBase += used
            }
            return out
        }

        /// The mic at `seconds` into the video, interpolated from 16 kHz.
        private func micSample(at seconds: Double) -> Float {
            let x = (seconds - micStartsAt) * MonoResampler.sampleRate
            guard x >= 0 else { return 0 }
            let i = Int(x)
            let f = Float(x - Double(i))
            let a = micValue(i), b = micValue(i + 1)
            return a + (b - a) * f
        }

        private func micValue(_ index: Int) -> Float {
            if index >= micBase + micSamples.count {
                // Read on in one-second blocks; earlier ones aren't needed again.
                let keep = max(index - micBase - 16, 0)
                if keep > 0, keep <= micSamples.count {
                    micSamples.removeFirst(keep)
                    micBase += keep
                }
                while index >= micBase + micSamples.count {
                    guard let mic, let buffer = AVAudioPCMBuffer(pcmFormat: mic.processingFormat, frameCapacity: 16_000),
                          (try? mic.read(into: buffer)) != nil, buffer.frameLength > 0
                    else { return 0 }
                    micSamples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
                }
            }
            let j = index - micBase
            return j >= 0 && j < micSamples.count ? micSamples[j] : 0
        }

        private static func floats(_ sample: CMSampleBuffer) -> [Float] {
            guard let data = CMSampleBufferGetDataBuffer(sample) else { return [] }
            let length = CMBlockBufferGetDataLength(data)
            var out = [Float](repeating: 0, count: length / 4)
            out.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            return out
        }

        private func makeBuffer(_ samples: [Float], frames: Int, at position: Int) -> CMSampleBuffer? {
            let bytes = samples.count * 4
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                     customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr,
                  let block
            else { return nil }
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
            var sample: CMSampleBuffer?
            let time = CMTime(value: CMTimeValue(position), timescale: CMTimeScale(VideoSoundMixer.rate))
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                       sampleCount: frames, presentationTimeStamp: time,
                                                                       packetDescriptions: nil, sampleBufferOut: &sample) == noErr
            else {
                log.error("couldn't make an audio buffer")
                return nil
            }
            return sample
        }
    }
}
