import AppKit
import CFFmpeg
import CoreVideo
import Foundation

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

final class NativeVideoPlayer: @unchecked Sendable {
    let slot: VideoSlot

    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var decoder: OpaquePointer?
    private var pendingSeek: (seconds: Double, exact: Bool)?
    private var isSeeking = false
    private var playbackGeneration = 0
    private var visible = true
    private var frameHistory: [NativeVideoFrame] = []

    private(set) var fileURL: URL?
    private(set) var timePosition: Double = 0
    private(set) var duration: Double = 0
    private(set) var fps: Double = 60
    private(set) var isPaused = true

    var onStatusChanged: (() -> Void)?
    var onFrameDecoded: ((VideoSlot, CVPixelBuffer, Double) -> Void)?
    var onVisibilityChanged: ((VideoSlot, Bool) -> Void)?
    var onOpenFailed: ((VideoSlot, String) -> Void)?

    init(slot: VideoSlot) {
        self.slot = slot
        self.queue = DispatchQueue(label: "VideoCompare.native.decode.\(slot.rawValue)", qos: .userInitiated)
    }

    deinit {
        let decoder = self.decoder
        self.decoder = nil
        if let decoder {
            queue.async {
                vc_decoder_close(decoder)
            }
        }
    }

    func load(url: URL) {
        fileURL = url
        isPaused = true
        playbackGeneration += 1
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
        playbackGeneration += 1
        isPaused = !active
        notifyStatus()
    }

    func togglePause() {
        setPause(!isPaused)
    }

    func seekAbsolute(_ seconds: Double, exact: Bool = true) {
        DispatchQueue.main.async {
            self.frameHistory.removeAll(keepingCapacity: true)
        }
        stateLock.lock()
        pendingSeek = (max(0, seconds), exact)
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
                self.decodeSeek(seconds: request.seconds, exact: request.exact, publishStale: false)
            }
        }
    }

    func frameStep(_ direction: Int) {
        stepFrame(direction: direction) { _ in }
    }

    func stepFrame(direction: Int, completion: @escaping (Double?) -> Void) {
        setPause(true)
        if direction < 0, presentPreviousFrameFromHistory(completion: completion) {
            return
        }

        if direction > 0 {
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
        let currentIndex = frameHistory.lastIndex { $0.pts <= timePosition + 0.0001 } ?? frameHistory.count - 1
        let previousIndex = max(0, currentIndex - 1)
        guard previousIndex != currentIndex else { return false }
        let frame = frameHistory[previousIndex]
        frameHistory.removeSubrange((previousIndex + 1)..<frameHistory.count)
        timePosition = frame.pts
        onFrameDecoded?(slot, frame.pixelBuffer, frame.pts)
        notifyStatus()
        completion(frame.pts)
        return true
    }

    private func record(_ frame: NativeVideoFrame) {
        if let last = frameHistory.last, abs(last.pts - frame.pts) < 0.0001 {
            frameHistory[frameHistory.count - 1] = frame
        } else {
            frameHistory.append(frame)
        }
        if frameHistory.count > 240 {
            frameHistory.removeFirst(frameHistory.count - 240)
        }
    }

    private func startPlaybackLoop() {
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

    private func decodeSeek(seconds: Double, exact: Bool, publishStale: Bool) {
        guard let decoder else { return }
        var frame = VCDecodedFrame()
        let result = vc_decoder_seek(decoder, seconds, exact ? 1 : 0, &frame)
        guard result > 0, let unmanagedPixelBuffer = frame.pixelBuffer else {
            vc_frame_release(&frame)
            return
        }
        let pixelBuffer = unmanagedPixelBuffer.takeRetainedValue()
        publish(frame: frame, pixelBuffer: pixelBuffer)
        _ = publishStale
    }

    private func publish(frame: VCDecodedFrame, pixelBuffer: CVPixelBuffer) {
        let videoFrame = NativeVideoFrame(pixelBuffer: pixelBuffer, pts: frame.pts, duration: frame.duration)
        DispatchQueue.main.async {
            self.presentSynchronizedFrame(videoFrame)
        }
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
}
