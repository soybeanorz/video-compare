import AppKit
import CFFmpeg
import CoreVideo
import Foundation
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

final class NativeVideoPlayer: @unchecked Sendable {
    let slot: VideoSlot

    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var decoder: OpaquePointer?
    private var pendingSeek: (seconds: Double, exact: Bool, generation: Int)?
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

    private(set) var fileURL: URL?
    private(set) var timePosition: Double = 0
    private(set) var duration: Double = 0
    private(set) var fps: Double = 60
    private(set) var isPaused = true

    var onStatusChanged: (() -> Void)?
    var onFrameDecoded: ((VideoSlot, CVPixelBuffer, Double) -> Void)?
    var onVisibilityChanged: ((VideoSlot, Bool) -> Void)?
    var onOpenFailed: ((VideoSlot, String) -> Void)?
    var onSeekCompleted: ((VideoSlot, Bool, TimeInterval) -> Void)?

    init(slot: VideoSlot) {
        self.slot = slot
        self.queue = DispatchQueue(label: "VideoCompare.native.decode.\(slot.rawValue)", qos: .userInitiated)
    }

    deinit {
        let decoder = self.decoder
        self.decoder = nil
        seekCancelToken.pointer.pointee = Int32.max
        if let decoder {
            queue.async {
                vc_decoder_close(decoder)
            }
        }
    }

    var isSeekIdle: Bool {
        stateLock.lock()
        let idle = !isSeeking && pendingSeek == nil
        stateLock.unlock()
        return idle
    }

    func load(url: URL) {
        Diagnostics.log("player.\(slot.rawValue).load path=\(url.path)")
        fileURL = url
        isPaused = true
        playbackGeneration += 1
        frameHistory.removeAll(keepingCapacity: true)
        frameHistoryIndex = nil
        frameCache.removeAll(keepingCapacity: true)
        frameCacheOrder.removeAll(keepingCapacity: true)
        staticImageFrame = nil
        duration = 0
        timePosition = 0
        fps = 60
        notifyStatus()
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
                let message = String(cString: error)
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
                self.duration = duration
                self.fps = fps > 1 ? fps : 60
                self.timePosition = 0
                self.notifyStatus()
            }
            self.decodeSeek(seconds: 0, exact: true, publishStale: true)
        }
    }

    func setPause(_ paused: Bool, force: Bool = false) {
        if staticImageFrame != nil {
            isPaused = true
            notifyStatus()
            return
        }
        guard force || isPaused != paused else { return }
        isPaused = paused
        if paused {
            playbackGeneration += 1
        } else {
            startPlaybackLoop()
        }
        notifyStatus()
    }

    func setSynchronizedPlaybackActive(_ active: Bool) {
        if staticImageFrame != nil {
            isPaused = true
            notifyStatus()
            return
        }
        playbackGeneration += 1
        isPaused = !active
        notifyStatus()
    }

    func togglePause() {
        setPause(!isPaused)
    }

    func seekAbsolute(_ seconds: Double, exact: Bool = true) {
        if let staticImageFrame {
            presentStaticImageFrame(staticImageFrame)
            return
        }
        stateLock.lock()
        seekGeneration += 1
        let generation = seekGeneration
        seekCancelToken.pointer.pointee = Int32(generation)
        if exact, Thread.isMainThread, let cached = cachedFrame(at: seconds) {
            pendingSeek = nil
            stateLock.unlock()
            presentHistoricalFrame(cached)
            return
        }
        DispatchQueue.main.async {
            self.frameHistory.removeAll(keepingCapacity: true)
            self.frameHistoryIndex = nil
        }
        pendingSeek = (max(0, seconds), exact, generation)
        Diagnostics.log("player.\(slot.rawValue).seek.request generation=\(generation) seconds=\(String(format: "%.6f", max(0, seconds))) exact=\(exact) isSeeking=\(isSeeking)")
        guard !isSeeking else {
            stateLock.unlock()
            return
        }
        isSeeking = true
        stateLock.unlock()

        queue.async {
            while true {
                self.stateLock.lock()
                guard let request = self.pendingSeek else {
                    self.isSeeking = false
                    self.stateLock.unlock()
                    break
                }
                self.pendingSeek = nil
                self.stateLock.unlock()
                Diagnostics.log("player.\(self.slot.rawValue).seek.start generation=\(request.generation) seconds=\(String(format: "%.6f", request.seconds)) exact=\(request.exact)")
                self.decodeSeek(seconds: request.seconds, exact: request.exact, publishStale: false, seekGeneration: request.generation)
            }
        }
    }

    func frameStep(_ direction: Int) {
        stepFrame(direction: direction) { _ in }
    }

    func stepFrame(direction: Int, completion: @escaping (Double?) -> Void) {
        setPause(true)
        if let staticImageFrame {
            presentStaticImageFrame(staticImageFrame)
            completion(staticImageFrame.pts)
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
                    completion(nil)
                    return
                }
                self.presentSynchronizedFrame(frame)
                completion(frame.pts)
            }
            return
        }

        let target = max(0, timePosition + Double(direction) / max(1, fps))
        queue.async {
            guard let decoder = self.decoder else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var frame = VCDecodedFrame()
            let result = vc_decoder_seek(decoder, target, 1, &frame)
            guard result > 0, let unmanagedPixelBuffer = frame.pixelBuffer else {
                vc_frame_release(&frame)
                DispatchQueue.main.async { completion(nil) }
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
                completion(videoFrame.pts)
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
        if let staticImageFrame {
            completion(staticImageFrame)
            return
        }
        queue.async {
            guard self.decoder != nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var frame = VCDecodedFrame()
            let result = vc_decoder_next(self.decoder, &frame)
            guard result > 0, let unmanagedPixelBuffer = frame.pixelBuffer else {
                vc_frame_release(&frame)
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let videoFrame = NativeVideoFrame(
                pixelBuffer: unmanagedPixelBuffer.takeRetainedValue(),
                pts: frame.pts,
                duration: frame.duration
            )
            DispatchQueue.main.async {
                completion(videoFrame)
            }
        }
    }

    func presentSynchronizedFrame(_ frame: NativeVideoFrame) {
        record(frame)
        timePosition = frame.pts
        onFrameDecoded?(slot, frame.pixelBuffer, frame.pts)
        notifyStatus()
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
        timePosition = frame.pts
        onFrameDecoded?(slot, frame.pixelBuffer, frame.pts)
        notifyStatus()
    }

    private func presentStaticImageFrame(_ frame: NativeVideoFrame) {
        timePosition = 0
        onFrameDecoded?(slot, frame.pixelBuffer, frame.pts)
        notifyStatus()
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
            isPaused = true
            notifyStatus()
            return
        }
        playbackGeneration += 1
        let generation = playbackGeneration
        queue.async {
            self.decodePlaybackFrame(generation: generation)
        }
    }

    private func decodePlaybackFrame(generation: Int) {
        guard generation == playbackGeneration, !isPaused, decoder != nil else { return }
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

    private func decodeSeek(seconds: Double, exact: Bool, publishStale: Bool, seekGeneration: Int? = nil) {
        guard let decoder else { return }
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
            return
        }
        if exact {
            DispatchQueue.main.async {
                self.onSeekCompleted?(self.slot, exact, elapsed)
            }
        }
        let pixelBuffer = unmanagedPixelBuffer.takeRetainedValue()
        Diagnostics.log("player.\(slot.rawValue).seek.decoded generation=\(seekGeneration.map(String.init) ?? "nil") requested=\(String(format: "%.6f", seconds)) pts=\(String(format: "%.6f", frame.pts)) exact=\(exact)")
        publish(frame: frame, pixelBuffer: pixelBuffer, publishStale: publishStale, seekGeneration: seekGeneration)
    }

    private func publish(frame: VCDecodedFrame, pixelBuffer: CVPixelBuffer, publishStale: Bool = true, seekGeneration: Int? = nil) {
        let pts = frame.pts
        let videoFrame = NativeVideoFrame(pixelBuffer: pixelBuffer, pts: frame.pts, duration: frame.duration)
        DispatchQueue.main.async {
            if !publishStale, let seekGeneration, !self.isLatestCompletedSeek(seekGeneration) {
                Diagnostics.log("player.\(self.slot.rawValue).seek.dropStale generation=\(seekGeneration) pts=\(String(format: "%.6f", pts))")
                return
            }
            if let seekGeneration {
                Diagnostics.log("player.\(self.slot.rawValue).seek.publish generation=\(seekGeneration) pts=\(String(format: "%.6f", pts))")
            }
            self.presentSynchronizedFrame(videoFrame)
        }
    }

    private func isLatestCompletedSeek(_ generation: Int) -> Bool {
        stateLock.lock()
        let latest = generation == seekGeneration && pendingSeek == nil
        stateLock.unlock()
        return latest
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
                let pixelBuffer = try Self.makePixelBuffer(fromImageAt: url)
                let frame = NativeVideoFrame(pixelBuffer: pixelBuffer, pts: 0, duration: 0)
                Diagnostics.log("player.\(self.slot.rawValue).image.opened path=\(path) width=\(CVPixelBufferGetWidth(pixelBuffer)) height=\(CVPixelBufferGetHeight(pixelBuffer))")
                DispatchQueue.main.async {
                    self.staticImageFrame = frame
                    self.duration = 0
                    self.fps = 1
                    self.timePosition = 0
                    self.presentStaticImageFrame(frame)
                }
            } catch {
                DispatchQueue.main.async {
                    self.onOpenFailed?(self.slot, error.localizedDescription)
                }
            }
        }
    }

    private static func makePixelBuffer(fromImageAt url: URL) throws -> CVPixelBuffer {
        guard let image = NSImage(contentsOf: url) else {
            throw NSError(domain: "VideoCompare.ImageLoad", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法打开照片"])
        }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            throw NSError(domain: "VideoCompare.ImageLoad", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法解码照片"])
        }
        let width = max(1, cgImage.width)
        let height = max(1, cgImage.height)
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
}
