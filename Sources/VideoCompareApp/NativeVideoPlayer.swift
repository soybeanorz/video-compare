import AppKit
import CFFmpeg
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import QuartzCore

final class NativeVideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let pts: Double
    let duration: Double

    init(pixelBuffer: CVPixelBuffer, pts: Double, duration: Double) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.duration = duration
    }
}

struct PlayerStatusSnapshot: Sendable, Equatable {
    var fileURL: URL?
    var timePosition: Double = 0
    var duration: Double = 0
    var fps: Double = 60
    var isPaused = true
    var isSeekIdle = true
    var isStaticImage = false
}

private final class SeekCancelToken: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Int32>

    init() {
        pointer = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        pointer.initialize(to: 0)
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
}

private struct DecoderHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

private final class TimeCompletionBox: @unchecked Sendable {
    let completion: (Double?) -> Void

    init(_ completion: @escaping (Double?) -> Void) {
        self.completion = completion
    }
}

private final class FrameCompletionBox: @unchecked Sendable {
    let completion: (NativeVideoFrame?) -> Void

    init(_ completion: @escaping (NativeVideoFrame?) -> Void) {
        self.completion = completion
    }
}

private final class FramesCompletionBox: @unchecked Sendable {
    let completion: ([NativeVideoFrame]) -> Void

    init(_ completion: @escaping ([NativeVideoFrame]) -> Void) {
        self.completion = completion
    }
}

private final class SeekCompletionBox: @unchecked Sendable {
    let completion: (Bool) -> Void

    init(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }
}

private final class BoolCompletionBox: @unchecked Sendable {
    let completion: (Bool) -> Void

    init(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }
}

final class NativeVideoPlayer: @unchecked Sendable {
    private static let rawPreviewMaxPixelSize = 1600

    let slot: VideoSlot

    private let queue: DispatchQueue
    private let loopPreviewQueue: DispatchQueue
    private let seekLock = NSLock()
    private let statusLock = NSLock()
    private let playbackLock = NSLock()
    private var decoder: OpaquePointer?
    private var pendingSeek: (seconds: Double, exact: Bool, publishFrame: Bool, generation: Int, completion: SeekCompletionBox?)?
    private var isSeeking = false
    private var seekGeneration = 0
    private let seekCancelToken = SeekCancelToken()
    private var playbackGeneration = 0
    private var visible = true
    private var frameHistory: [NativeVideoFrame] = []
    private var frameHistoryIndex: Int?
    private var frameCache: [Int: NativeVideoFrame] = [:]
    private var frameCacheOrder: [Int] = []
    private var staticImageFrame: NativeVideoFrame?
    private var staticImageReloadGeneration = 0
    private var rawRenderSession: RawRenderSession?
    private var rawNeutralDefaults: RawNeutralDefaults?
    private var status = PlayerStatusSnapshot()

    private final class RawRenderSession {
        let url: URL
        let filter: CIFilter
        let context: CIContext
        let colorSpace: CGColorSpace
        let defaults: RawNeutralDefaults
        private var previewPixelBuffer: CVPixelBuffer?
        private var fullPixelBuffer: CVPixelBuffer?

        init(url: URL) throws {
            guard let filter = CIFilter(imageURL: url) else {
                throw NSError(domain: "VideoCompare.RawLoad", code: 1, userInfo: [NSLocalizedDescriptionKey: "系统 RAW 解码器无法打开该文件"])
            }
            filter.setDefaults()
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            self.url = url
            self.filter = filter
            self.colorSpace = colorSpace
            self.context = CIContext(options: [
                .workingColorSpace: colorSpace,
                .outputColorSpace: colorSpace
            ])
            self.defaults = NativeVideoPlayer.rawNeutralDefaults(from: filter)
        }

        func render(adjustment: ColorAdjustmentState, maxPixelSize: Int?) throws -> CVPixelBuffer {
            let mapped = RawTemperatureTintMapper.mappedNeutral(defaults: defaults, adjustment: adjustment)
            Diagnostics.log("raw.decode path=\(url.lastPathComponent) defaultTemp=\(String(format: "%.3f", defaults.temperature)) defaultTint=\(String(format: "%.3f", defaults.tint)) mappedTemp=\(String(format: "%.3f", mapped.temperature)) mappedTint=\(String(format: "%.3f", mapped.tint)) previewMax=\(maxPixelSize.map(String.init) ?? "full")")
            NativeVideoPlayer.setFilterValueIfAvailable(mapped.temperature, key: "inputNeutralTemperature", filter: filter)
            NativeVideoPlayer.setFilterValueIfAvailable(mapped.tint, key: "inputNeutralTint", filter: filter)
            NativeVideoPlayer.setFilterValueIfAvailable(1.0, key: "inputBoost", filter: filter)

            guard var image = filter.outputImage else {
                throw NSError(domain: "VideoCompare.RawLoad", code: 2, userInfo: [NSLocalizedDescriptionKey: "系统 RAW 解码器无法生成图像"])
            }
            let extent = image.extent
            guard extent.width > 1, extent.height > 1 else {
                throw NSError(domain: "VideoCompare.RawLoad", code: 3, userInfo: [NSLocalizedDescriptionKey: "RAW 图像尺寸无效"])
            }
            image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))

            var width = max(1, Int(ceil(extent.width)))
            var height = max(1, Int(ceil(extent.height)))
            if let maxPixelSize, max(width, height) > maxPixelSize {
                let scale = CGFloat(maxPixelSize) / CGFloat(max(width, height))
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                width = max(1, Int(ceil(image.extent.width)))
                height = max(1, Int(ceil(image.extent.height)))
            }

            let pixelBuffer = try reusablePixelBuffer(width: width, height: height, preview: maxPixelSize != nil)
            context.render(
                image,
                to: pixelBuffer,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                colorSpace: colorSpace
            )
            return pixelBuffer
        }

        private func reusablePixelBuffer(width: Int, height: Int, preview: Bool) throws -> CVPixelBuffer {
            let current = preview ? previewPixelBuffer : fullPixelBuffer
            if let current,
               CVPixelBufferGetWidth(current) == width,
               CVPixelBufferGetHeight(current) == height {
                return current
            }
            let pixelBuffer = try NativeVideoPlayer.makePixelBuffer(width: width, height: height)
            if preview {
                previewPixelBuffer = pixelBuffer
            } else {
                fullPixelBuffer = pixelBuffer
            }
            return pixelBuffer
        }
    }

    var statusSnapshot: PlayerStatusSnapshot {
        statusLock.lock()
        let snapshot = status
        statusLock.unlock()
        return snapshot
    }

    var fileURL: URL? { statusSnapshot.fileURL }
    var timePosition: Double { statusSnapshot.timePosition }
    var duration: Double { statusSnapshot.duration }
    var fps: Double { statusSnapshot.fps }
    var isPaused: Bool { statusSnapshot.isPaused }
    var isStaticImage: Bool { statusSnapshot.isStaticImage }

    var onStatusChanged: (() -> Void)?
    var onFrameDecoded: ((VideoSlot, CVPixelBuffer, Double) -> Void)?
    var onVisibilityChanged: ((VideoSlot, Bool) -> Void)?
    var onOpenFailed: ((VideoSlot, String) -> Void)?
    var onSeekCompleted: ((VideoSlot, Bool, TimeInterval) -> Void)?

    init(slot: VideoSlot) {
        self.slot = slot
        self.queue = DispatchQueue(label: "VideoCompare.native.decode.\(slot.rawValue)", qos: .userInitiated)
        self.loopPreviewQueue = DispatchQueue(label: "VideoCompare.native.loopPreview.\(slot.rawValue)", qos: .utility)
    }

    deinit {
        let decoder = self.decoder
        self.decoder = nil
        seekCancelToken.pointer.pointee = Int32.max
        if let decoder {
            let handle = DecoderHandle(pointer: decoder)
            queue.async {
                vc_decoder_close(handle.pointer)
            }
        }
    }

    var isSeekIdle: Bool {
        seekLock.lock()
        let idle = !isSeeking && pendingSeek == nil
        seekLock.unlock()
        return idle
    }

    func load(url: URL) {
        Diagnostics.log("player.\(slot.rawValue).load path=\(url.path)")
        updateStatus {
            $0.fileURL = url
            $0.isPaused = true
            $0.duration = 0
            $0.timePosition = 0
            $0.fps = 60
            $0.isStaticImage = MediaFileSupport.isImage(url)
        }
        _ = nextPlaybackGeneration()
        frameHistory.removeAll(keepingCapacity: true)
        frameHistoryIndex = nil
        frameCache.removeAll(keepingCapacity: true)
        frameCacheOrder.removeAll(keepingCapacity: true)
        staticImageFrame = nil
        rawRenderSession = nil
        rawNeutralDefaults = nil
        staticImageReloadGeneration += 1
        if MediaFileSupport.isImage(url) {
            loadStaticImage(url: url)
            return
        }
        let path = url.path
        queue.async {
            if let old = self.decoder {
                vc_decoder_close(old)
                self.decoder = nil
            }

            var error = [CChar](repeating: 0, count: 512)
            guard let opened = path.withCString({ vc_decoder_open($0, &error, Int32(error.count)) }) else {
                let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                DispatchQueue.main.async {
                    self.onOpenFailed?(self.slot, message.isEmpty ? "无法打开视频" : message)
                }
                return
            }

            self.decoder = opened
            let duration = vc_decoder_duration(opened)
            let fps = vc_decoder_fps(opened)
            let keyframes = vc_decoder_keyframe_count(opened)
            Diagnostics.log("player.\(self.slot.rawValue).opened duration=\(String(format: "%.6f", duration)) fps=\(String(format: "%.6f", fps)) keyframes=\(keyframes)")
            DispatchQueue.main.async {
                self.updateStatus {
                    $0.duration = duration
                    $0.fps = fps > 1 ? fps : 60
                    $0.timePosition = 0
                }
            }
            self.decodeSeek(seconds: 0, exact: true, publishStale: true)
        }
    }

    func setPause(_ paused: Bool, force: Bool = false) {
        if staticImageFrame != nil {
            updateStatus { $0.isPaused = true }
            return
        }
        guard force || statusSnapshot.isPaused != paused else { return }
        updateStatus { $0.isPaused = paused }
        if paused {
            _ = nextPlaybackGeneration()
        } else {
            startPlaybackLoop()
        }
    }

    func setSynchronizedPlaybackActive(_ active: Bool) {
        if staticImageFrame != nil {
            updateStatus { $0.isPaused = true }
            return
        }
        _ = nextPlaybackGeneration()
        updateStatus { $0.isPaused = !active }
    }

    func togglePause() {
        setPause(!isPaused)
    }

    func reloadStaticImage(rawAdjustment adjustment: ColorAdjustmentState, preview: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard let url = fileURL,
              isStaticImage,
              MediaFileSupport.isRawImage(url) else {
            completion?(false)
            return
        }
        let completionBox = completion.map(BoolCompletionBox.init)
        staticImageReloadGeneration += 1
        let generation = staticImageReloadGeneration
        queue.async {
            guard generation == self.staticImageReloadGeneration else {
                Diagnostics.log("player.\(self.slot.rawValue).raw.reload.skipStaleBeforeDecode generation=\(generation)")
                return
            }
            do {
                Diagnostics.log("player.\(self.slot.rawValue).raw.reload.start generation=\(generation) temp=\(String(format: "%.4f", adjustment.temperature)) tint=\(String(format: "%.4f", adjustment.tint)) preview=\(preview)")
                let session = try self.rawRenderSession(for: url)
                let pixelBuffer = try session.render(
                    adjustment: adjustment,
                    maxPixelSize: preview ? Self.rawPreviewMaxPixelSize : nil
                )
                let rawDefaults = session.defaults
                let frame = NativeVideoFrame(pixelBuffer: pixelBuffer, pts: 0, duration: 0)
                DispatchQueue.main.async {
                    guard generation == self.staticImageReloadGeneration,
                          self.fileURL == url,
                          self.isStaticImage else {
                        return
                    }
                    self.rawNeutralDefaults = rawDefaults
                    self.staticImageFrame = frame
                    self.presentStaticImageFrame(frame)
                    Diagnostics.log("player.\(self.slot.rawValue).raw.reload.apply generation=\(generation) preview=\(preview)")
                    completionBox?.completion(true)
                }
            } catch {
                DispatchQueue.main.async {
                    guard generation == self.staticImageReloadGeneration else {
                        return
                    }
                    self.onOpenFailed?(self.slot, error.localizedDescription)
                    completionBox?.completion(false)
                }
            }
        }
    }

    func seekAbsolute(_ seconds: Double, exact: Bool = true, allowCachedFrame: Bool = true, publishFrame: Bool = true, completion: ((Bool) -> Void)? = nil) {
        let completionBox = completion.map(SeekCompletionBox.init)
        if let staticImageFrame {
            if publishFrame {
                presentStaticImageFrame(staticImageFrame)
            }
            completionBox?.completion(true)
            return
        }
        seekLock.lock()
        seekGeneration += 1
        let generation = seekGeneration
        seekCancelToken.pointer.pointee = Int32(generation)
        if publishFrame, allowCachedFrame, exact, Thread.isMainThread, let cached = cachedFrame(at: seconds) {
            pendingSeek = nil
            seekLock.unlock()
            presentHistoricalFrame(cached)
            completionBox?.completion(true)
            return
        }
        DispatchQueue.main.async {
            self.frameHistory.removeAll(keepingCapacity: true)
            self.frameHistoryIndex = nil
        }
        pendingSeek = (max(0, seconds), exact, publishFrame, generation, completionBox)
        Diagnostics.log("player.\(slot.rawValue).seek.request generation=\(generation) seconds=\(String(format: "%.6f", max(0, seconds))) exact=\(exact) isSeeking=\(isSeeking)")
        guard !isSeeking else {
            seekLock.unlock()
            return
        }
        isSeeking = true
        seekLock.unlock()

        queue.async {
            while true {
                self.seekLock.lock()
                guard let request = self.pendingSeek else {
                    self.isSeeking = false
                    self.seekLock.unlock()
                    break
                }
                self.pendingSeek = nil
                self.seekLock.unlock()
                Diagnostics.log("player.\(self.slot.rawValue).seek.start generation=\(request.generation) seconds=\(String(format: "%.6f", request.seconds)) exact=\(request.exact)")
                self.decodeSeek(
                    seconds: request.seconds,
                    exact: request.exact,
                    publishStale: false,
                    publishFrame: request.publishFrame,
                    seekGeneration: request.generation,
                    completion: request.completion
                )
            }
        }
    }

    func frameStep(_ direction: Int) {
        stepFrame(direction: direction) { _ in }
    }

    func stepFrame(direction: Int, completion: @escaping (Double?) -> Void) {
        let completionBox = TimeCompletionBox(completion)
        setPause(true)
        if let staticImageFrame {
            presentStaticImageFrame(staticImageFrame)
            completionBox.completion(staticImageFrame.pts)
            return
        }
        if direction < 0, presentPreviousFrameFromHistory(completion: completion) {
            return
        }

        if direction > 0 {
            if presentNextFrameFromHistory(completion: completion) {
                return
            }
            decodeNextFrameForSynchronization { frame in
                guard let frame else {
                    completionBox.completion(nil)
                    return
                }
                self.presentSynchronizedFrame(frame)
                completionBox.completion(frame.pts)
            }
            return
        }

        let target = max(0, timePosition + Double(direction) / max(1, fps))
        queue.async {
            guard let decoder = self.decoder else {
                DispatchQueue.main.async { completionBox.completion(nil) }
                return
            }
            var frame = VCDecodedFrame()
            let result = vc_decoder_seek(decoder, target, 1, &frame)
            guard result > 0, let unmanagedPixelBuffer = frame.pixelBuffer else {
                vc_frame_release(&frame)
                DispatchQueue.main.async { completionBox.completion(nil) }
                return
            }
            let videoFrame = NativeVideoFrame(
                pixelBuffer: unmanagedPixelBuffer.takeRetainedValue(),
                pts: frame.pts,
                duration: frame.duration
            )
            DispatchQueue.main.async {
                self.frameHistory.removeAll(keepingCapacity: true)
                self.frameHistoryIndex = nil
                self.presentSynchronizedFrame(videoFrame)
                completionBox.completion(videoFrame.pts)
            }
        }
    }

    func setVideoVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        DispatchQueue.main.async {
            self.onVisibilityChanged?(self.slot, visible)
        }
    }

    func applyTransform(_ transform: TransformState) {
        _ = transform
    }

    func setSubtitleLoadingDisabled(_ disabled: Bool) {
        _ = disabled
    }

    func queryPlaybackInfo() {
        notifyStatus()
    }

    func decodeNextFrameForSynchronization(completion: @escaping (NativeVideoFrame?) -> Void) {
        let completionBox = FrameCompletionBox(completion)
        if let staticImageFrame {
            completionBox.completion(staticImageFrame)
            return
        }
        queue.async {
            guard self.decoder != nil else {
                DispatchQueue.main.async { completionBox.completion(nil) }
                return
            }
            var frame = VCDecodedFrame()
            let result = vc_decoder_next(self.decoder, &frame)
            guard result > 0, let unmanagedPixelBuffer = frame.pixelBuffer else {
                vc_frame_release(&frame)
                DispatchQueue.main.async { completionBox.completion(nil) }
                return
            }
            let videoFrame = NativeVideoFrame(
                pixelBuffer: unmanagedPixelBuffer.takeRetainedValue(),
                pts: frame.pts,
                duration: frame.duration
            )
            DispatchQueue.main.async {
                completionBox.completion(videoFrame)
            }
        }
    }

    func decodeFrameForLoopPreview(seconds: Double, exact: Bool = true, completion: @escaping (NativeVideoFrame?) -> Void) {
        let completionBox = FrameCompletionBox(completion)
        decodeFramesForLoopPreview(seconds: seconds, exact: exact, maxFrames: 1) { frames in
            completionBox.completion(frames.first)
        }
    }

    func decodeFramesForLoopPreview(seconds: Double, exact: Bool = true, maxFrames: Int, completion: @escaping ([NativeVideoFrame]) -> Void) {
        let completionBox = FramesCompletionBox(completion)
        guard maxFrames > 0 else {
            DispatchQueue.main.async {
                completionBox.completion([])
            }
            return
        }
        if let staticImageFrame {
            DispatchQueue.main.async {
                completionBox.completion([staticImageFrame])
            }
            return
        }
        guard let url = statusSnapshot.fileURL else {
            DispatchQueue.main.async {
                completionBox.completion([])
            }
            return
        }

        let path = url.path
        let target = max(0, seconds)
        loopPreviewQueue.async {
            var error = [CChar](repeating: 0, count: 512)
            guard let previewDecoder = path.withCString({ vc_decoder_open($0, &error, Int32(error.count)) }) else {
                DispatchQueue.main.async {
                    completionBox.completion([])
                }
                return
            }
            defer { vc_decoder_close(previewDecoder) }

            var frame = VCDecodedFrame()
            let result = vc_decoder_seek(previewDecoder, target, exact ? 1 : 0, &frame)
            guard result > 0, let unmanagedPixelBuffer = frame.pixelBuffer else {
                vc_frame_release(&frame)
                DispatchQueue.main.async {
                    completionBox.completion([])
                }
                return
            }
            var frames = [
                NativeVideoFrame(
                    pixelBuffer: unmanagedPixelBuffer.takeRetainedValue(),
                    pts: frame.pts,
                    duration: frame.duration
                )
            ]
            while frames.count < maxFrames {
                var nextFrame = VCDecodedFrame()
                let nextResult = vc_decoder_next(previewDecoder, &nextFrame)
                guard nextResult > 0, let unmanagedNextPixelBuffer = nextFrame.pixelBuffer else {
                    vc_frame_release(&nextFrame)
                    break
                }
                frames.append(
                    NativeVideoFrame(
                        pixelBuffer: unmanagedNextPixelBuffer.takeRetainedValue(),
                        pts: nextFrame.pts,
                        duration: nextFrame.duration
                    )
                )
            }
            DispatchQueue.main.async {
                completionBox.completion(frames)
            }
        }
    }

    func presentSynchronizedFrame(_ frame: NativeVideoFrame) {
        record(frame)
        updateStatus { $0.timePosition = frame.pts }
        onFrameDecoded?(slot, frame.pixelBuffer, frame.pts)
    }

    private func presentPreviousFrameFromHistory(completion: @escaping (Double?) -> Void) -> Bool {
        guard Thread.isMainThread else { return false }
        guard frameHistory.count >= 2 else { return false }
        let currentIndex = frameHistoryIndex ?? frameHistory.lastIndex { $0.pts <= timePosition + 0.0001 } ?? frameHistory.count - 1
        let previousIndex = max(0, currentIndex - 1)
        guard previousIndex != currentIndex else { return false }
        let frame = frameHistory[previousIndex]
        frameHistoryIndex = previousIndex
        presentHistoricalFrame(frame)
        completion(frame.pts)
        return true
    }

    private func presentNextFrameFromHistory(completion: @escaping (Double?) -> Void) -> Bool {
        guard Thread.isMainThread else { return false }
        guard let currentIndex = frameHistoryIndex, currentIndex + 1 < frameHistory.count else { return false }
        let nextIndex = currentIndex + 1
        let frame = frameHistory[nextIndex]
        frameHistoryIndex = nextIndex
        presentHistoricalFrame(frame)
        completion(frame.pts)
        return true
    }

    private func presentHistoricalFrame(_ frame: NativeVideoFrame) {
        updateStatus { $0.timePosition = frame.pts }
        onFrameDecoded?(slot, frame.pixelBuffer, frame.pts)
    }

    private func presentStaticImageFrame(_ frame: NativeVideoFrame) {
        updateStatus { $0.timePosition = 0 }
        onFrameDecoded?(slot, frame.pixelBuffer, frame.pts)
    }

    private func record(_ frame: NativeVideoFrame) {
        cache(frame)
        if let current = frameHistoryIndex, current < frameHistory.count - 1 {
            frameHistory.removeSubrange((current + 1)..<frameHistory.count)
        }
        if let last = frameHistory.last, abs(last.pts - frame.pts) < 0.0001 {
            frameHistory[frameHistory.count - 1] = frame
            frameHistoryIndex = frameHistory.count - 1
        } else {
            frameHistory.append(frame)
            frameHistoryIndex = frameHistory.count - 1
        }
        if frameHistory.count > 240 {
            let removed = frameHistory.count - 240
            frameHistory.removeFirst(removed)
            if let index = frameHistoryIndex {
                frameHistoryIndex = max(0, index - removed)
            }
        }
    }

    private func cache(_ frame: NativeVideoFrame) {
        let key = frameNumber(frame.pts)
        if frameCache[key] == nil {
            frameCacheOrder.append(key)
        }
        frameCache[key] = frame
        while frameCacheOrder.count > 180 {
            let removed = frameCacheOrder.removeFirst()
            frameCache.removeValue(forKey: removed)
        }
    }

    private func cachedFrame(at seconds: Double) -> NativeVideoFrame? {
        frameCache[frameNumber(seconds)]
    }

    private func frameNumber(_ seconds: Double) -> Int {
        max(0, Int(round(seconds * max(1, fps))))
    }

    private func cacheDecodedFrame(_ frame: VCDecodedFrame) {
        guard let unmanagedPixelBuffer = frame.pixelBuffer else { return }
        let pixelBuffer = unmanagedPixelBuffer.retain().takeRetainedValue()
        let videoFrame = NativeVideoFrame(
            pixelBuffer: pixelBuffer,
            pts: frame.pts,
            duration: frame.duration
        )
        DispatchQueue.main.async {
            self.cache(videoFrame)
        }
    }

    private static let cacheDecodedFrameCallback: VCFrameCallback = { frame, context in
        guard let frame, let context else { return }
        let player = Unmanaged<NativeVideoPlayer>.fromOpaque(context).takeUnretainedValue()
        player.cacheDecodedFrame(frame.pointee)
    }

    private func startPlaybackLoop() {
        guard staticImageFrame == nil else {
            updateStatus { $0.isPaused = true }
            return
        }
        let generation = nextPlaybackGeneration()
        queue.async {
            self.decodePlaybackFrame(generation: generation)
        }
    }

    private func decodePlaybackFrame(generation: Int) {
        guard generation == currentPlaybackGeneration(), !isPaused, decoder != nil else { return }
        var frame = VCDecodedFrame()
        let result = vc_decoder_next(decoder, &frame)
        if result > 0, let unmanagedPixelBuffer = frame.pixelBuffer {
            let pixelBuffer = unmanagedPixelBuffer.takeRetainedValue()
            publish(frame: frame, pixelBuffer: pixelBuffer)
            let delay = max(1.0 / max(1, fps), 0.001)
            queue.asyncAfter(deadline: .now() + delay) {
                self.decodePlaybackFrame(generation: generation)
            }
        } else {
            DispatchQueue.main.async {
                self.setPause(true)
            }
        }
    }

    private func decodeSeek(seconds: Double, exact: Bool, publishStale: Bool, publishFrame: Bool = true, seekGeneration: Int? = nil, completion: SeekCompletionBox? = nil) {
        guard let decoder else {
            DispatchQueue.main.async { completion?.completion(false) }
            return
        }
        var frame = VCDecodedFrame()
        let started = CACurrentMediaTime()
        let result: Int32
        if let seekGeneration {
            result = vc_decoder_seek_collect(
                decoder,
                seconds,
                exact ? 1 : 0,
                &frame,
                seekCancelToken.pointer,
                Int32(seekGeneration),
                exact ? NativeVideoPlayer.cacheDecodedFrameCallback : nil,
                Unmanaged.passUnretained(self).toOpaque()
            )
        } else {
            result = vc_decoder_seek(decoder, seconds, exact ? 1 : 0, &frame)
        }
        let elapsed = CACurrentMediaTime() - started
        guard result > 0, let unmanagedPixelBuffer = frame.pixelBuffer else {
            vc_frame_release(&frame)
            DispatchQueue.main.async { completion?.completion(false) }
            return
        }
        if exact {
            DispatchQueue.main.async {
                self.onSeekCompleted?(self.slot, exact, elapsed)
            }
        }
        let pixelBuffer = unmanagedPixelBuffer.takeRetainedValue()
        Diagnostics.log("player.\(slot.rawValue).seek.decoded generation=\(seekGeneration.map(String.init) ?? "nil") requested=\(String(format: "%.6f", seconds)) pts=\(String(format: "%.6f", frame.pts)) exact=\(exact)")
        publish(frame: frame, pixelBuffer: pixelBuffer, publishStale: publishStale, publishFrame: publishFrame, seekGeneration: seekGeneration, completion: completion)
    }

    private func publish(frame: VCDecodedFrame, pixelBuffer: CVPixelBuffer, publishStale: Bool = true, publishFrame: Bool = true, seekGeneration: Int? = nil, completion: SeekCompletionBox? = nil) {
        let pts = frame.pts
        let videoFrame = NativeVideoFrame(pixelBuffer: pixelBuffer, pts: frame.pts, duration: frame.duration)
        DispatchQueue.main.async {
            if !publishStale, let seekGeneration, !self.isLatestCompletedSeek(seekGeneration) {
                Diagnostics.log("player.\(self.slot.rawValue).seek.dropStale generation=\(seekGeneration) pts=\(String(format: "%.6f", pts))")
                completion?.completion(false)
                return
            }
            if let seekGeneration {
                Diagnostics.log("player.\(self.slot.rawValue).seek.publish generation=\(seekGeneration) pts=\(String(format: "%.6f", pts))")
            }
            if publishFrame {
                self.presentSynchronizedFrame(videoFrame)
            }
            completion?.completion(true)
        }
    }

    private func isLatestCompletedSeek(_ generation: Int) -> Bool {
        seekLock.lock()
        let latest = generation == seekGeneration && pendingSeek == nil
        seekLock.unlock()
        return latest
    }

    private func updateStatus(_ update: (inout PlayerStatusSnapshot) -> Void) {
        statusLock.lock()
        update(&status)
        status.isSeekIdle = isSeekIdle
        statusLock.unlock()
        notifyStatus()
    }

    private func nextPlaybackGeneration() -> Int {
        playbackLock.lock()
        playbackGeneration += 1
        let generation = playbackGeneration
        playbackLock.unlock()
        return generation
    }

    private func currentPlaybackGeneration() -> Int {
        playbackLock.lock()
        let generation = playbackGeneration
        playbackLock.unlock()
        return generation
    }

    private func notifyStatus() {
        if Thread.isMainThread {
            onStatusChanged?()
        } else {
            DispatchQueue.main.async {
                self.onStatusChanged?()
            }
        }
    }

    private func loadStaticImage(url: URL) {
        let path = url.path
        queue.async {
            if let old = self.decoder {
                vc_decoder_close(old)
                self.decoder = nil
            }
            do {
                let decoded: (pixelBuffer: CVPixelBuffer, rawDefaults: RawNeutralDefaults?)
                if MediaFileSupport.isRawImage(url) {
                    let session = try self.rawRenderSession(for: url)
                    decoded = (
                        try session.render(adjustment: ColorAdjustmentState(), maxPixelSize: nil),
                        session.defaults
                    )
                } else {
                    decoded = try Self.makePixelBuffer(fromImageAt: url, rawAdjustment: ColorAdjustmentState(), rawDefaults: nil)
                }
                let pixelBuffer = decoded.pixelBuffer
                let frame = NativeVideoFrame(pixelBuffer: pixelBuffer, pts: 0, duration: 0)
                Diagnostics.log("player.\(self.slot.rawValue).image.opened path=\(path) width=\(CVPixelBufferGetWidth(pixelBuffer)) height=\(CVPixelBufferGetHeight(pixelBuffer))")
                DispatchQueue.main.async {
                    self.rawNeutralDefaults = decoded.rawDefaults
                    self.staticImageFrame = frame
                    self.updateStatus {
                        $0.duration = 0
                        $0.fps = 1
                        $0.timePosition = 0
                        $0.isPaused = true
                        $0.isStaticImage = true
                    }
                    self.presentStaticImageFrame(frame)
                }
            } catch {
                DispatchQueue.main.async {
                    self.onOpenFailed?(self.slot, error.localizedDescription)
                }
            }
        }
    }

    private func rawRenderSession(for url: URL) throws -> RawRenderSession {
        if let rawRenderSession, rawRenderSession.url == url {
            return rawRenderSession
        }
        let session = try RawRenderSession(url: url)
        rawRenderSession = session
        rawNeutralDefaults = session.defaults
        return session
    }

    private static func makePixelBuffer(fromImageAt url: URL, rawAdjustment: ColorAdjustmentState, rawDefaults: RawNeutralDefaults?) throws -> (pixelBuffer: CVPixelBuffer, rawDefaults: RawNeutralDefaults?) {
        if MediaFileSupport.isRawImage(url),
           let decoded = try? makeRawPixelBuffer(fromImageAt: url, adjustment: rawAdjustment, defaults: rawDefaults) {
            return decoded
        }
        guard let cgImage = makeCGImage(fromImageAt: url) else {
            throw NSError(domain: "VideoCompare.ImageLoad", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法解码照片"])
        }
        return (try makePixelBuffer(from: cgImage), nil)
    }

    private static func makeRawPixelBuffer(fromImageAt url: URL, adjustment: ColorAdjustmentState, defaults: RawNeutralDefaults?) throws -> (pixelBuffer: CVPixelBuffer, rawDefaults: RawNeutralDefaults) {
        guard let filter = CIFilter(imageURL: url) else {
            throw NSError(domain: "VideoCompare.RawLoad", code: 1, userInfo: [NSLocalizedDescriptionKey: "系统 RAW 解码器无法打开该文件"])
        }
        filter.setDefaults()
        let detectedDefaults = rawNeutralDefaults(from: filter)
        let rawDefaults = defaults ?? detectedDefaults
        let mapped = RawTemperatureTintMapper.mappedNeutral(defaults: rawDefaults, adjustment: adjustment)
        Diagnostics.log("raw.decode path=\(url.lastPathComponent) defaultTemp=\(String(format: "%.3f", rawDefaults.temperature)) defaultTint=\(String(format: "%.3f", rawDefaults.tint)) mappedTemp=\(String(format: "%.3f", mapped.temperature)) mappedTint=\(String(format: "%.3f", mapped.tint))")
        setFilterValueIfAvailable(mapped.temperature, key: "inputNeutralTemperature", filter: filter)
        setFilterValueIfAvailable(mapped.tint, key: "inputNeutralTint", filter: filter)
        setFilterValueIfAvailable(1.0, key: "inputBoost", filter: filter)

        guard var image = filter.outputImage else {
            throw NSError(domain: "VideoCompare.RawLoad", code: 2, userInfo: [NSLocalizedDescriptionKey: "系统 RAW 解码器无法生成图像"])
        }
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else {
            throw NSError(domain: "VideoCompare.RawLoad", code: 3, userInfo: [NSLocalizedDescriptionKey: "RAW 图像尺寸无效"])
        }
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let width = max(1, Int(ceil(extent.width)))
        let height = max(1, Int(ceil(extent.height)))
        let pixelBuffer = try makePixelBuffer(width: width, height: height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace
        ])
        context.render(
            image,
            to: pixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: colorSpace
        )
        return (pixelBuffer, rawDefaults)
    }

    private static func rawNeutralDefaults(from filter: CIFilter) -> RawNeutralDefaults {
        RawNeutralDefaults(
            temperature: (filter.value(forKey: "inputNeutralTemperature") as? NSNumber)?.doubleValue ?? 6500,
            tint: (filter.value(forKey: "inputNeutralTint") as? NSNumber)?.doubleValue ?? 0
        )
    }

    private static func setFilterValueIfAvailable(_ value: Double, key: String, filter: CIFilter) {
        guard filter.inputKeys.contains(key) else { return }
        filter.setValue(value, forKey: key)
    }

    private static func makePixelBuffer(from cgImage: CGImage) throws -> CVPixelBuffer {
        let width = max(1, cgImage.width)
        let height = max(1, cgImage.height)
        let pixelBuffer = try makePixelBuffer(width: width, height: height)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "VideoCompare.ImageLoad", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法写入照片缓冲区"])
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "VideoCompare.ImageLoad", code: 5, userInfo: [NSLocalizedDescriptionKey: "无法渲染照片"])
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pixelBuffer: CVPixelBuffer?
        let createResult = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard createResult == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "VideoCompare.ImageLoad", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法创建照片缓冲区"])
        }
        return pixelBuffer
    }

    private static func makeCGImage(fromImageAt url: URL) -> CGImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        if let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            let maxPixelSize = max(width, height)
            if maxPixelSize > 0 {
                let thumbnailOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ]
                if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
                    return image
                }
            }
            if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return image
            }
        }

        guard let image = NSImage(contentsOf: url) else { return nil }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

}
