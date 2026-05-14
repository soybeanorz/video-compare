import Foundation
import QuartzCore

final class ScrubSeekCoordinator {
    var onSeek: ((Double, Bool) -> Void)?
    var isDecoderIdle: (() -> Bool)?

    private struct Sample {
        let seconds: Double
        let time: CFTimeInterval
    }

    private var lastSample: Sample?
    private var smoothedSpeed = 0.0
    private var lastCoarseFrame: Int?
    private var lastExactFrame: Int?
    private var lastCoarseTime: CFTimeInterval = 0
    private var pendingRefine: DispatchWorkItem?
    private var refineToken = 0
    private var exactSeekCostEMA = 0.08

    func beginTracking() {
        pendingRefine?.cancel()
        pendingRefine = nil
        refineToken += 1
        lastSample = nil
        smoothedSpeed = 0
        lastCoarseTime = 0
        lastCoarseFrame = nil
        lastExactFrame = nil
    }

    func updateTarget(seconds: Double, fps: Double) {
        let now = CACurrentMediaTime()
        let frame = frameIndex(seconds: seconds, fps: fps)
        updateSpeed(seconds: seconds, now: now)

        if shouldIssueCoarse(frame: frame, now: now) {
            lastCoarseFrame = frame
            lastCoarseTime = now
            onSeek?(seconds, false)
        }

        scheduleRefineIfUseful(seconds: seconds, fps: fps)
    }

    func endTracking(seconds: Double, fps: Double) {
        pendingRefine?.cancel()
        pendingRefine = nil
        refineToken += 1
        issueExact(seconds: seconds, fps: fps, force: true)
        lastSample = nil
        smoothedSpeed = 0
    }

    func recordExactSeekCost(_ seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        exactSeekCostEMA = exactSeekCostEMA * 0.8 + min(seconds, 0.5) * 0.2
    }

    private func updateSpeed(seconds: Double, now: CFTimeInterval) {
        defer {
            lastSample = Sample(seconds: seconds, time: now)
        }
        guard let lastSample else {
            smoothedSpeed = 0
            return
        }
        let dt = max(0.001, now - lastSample.time)
        let instant = abs(seconds - lastSample.seconds) / dt
        smoothedSpeed = smoothedSpeed == 0 ? instant : smoothedSpeed * 0.72 + instant * 0.28
    }

    private func shouldIssueCoarse(frame: Int, now: CFTimeInterval) -> Bool {
        guard lastCoarseFrame != frame else { return false }
        let interval: CFTimeInterval
        if smoothedSpeed > 20 {
            interval = 1.0 / 20.0
        } else if smoothedSpeed > 3 {
            interval = 1.0 / 30.0
        } else {
            interval = 1.0 / 60.0
        }
        return now - lastCoarseTime >= interval
    }

    private func scheduleRefineIfUseful(seconds: Double, fps: Double) {
        let frame = frameIndex(seconds: seconds, fps: fps)
        guard lastExactFrame != frame else { return }
        guard smoothedSpeed < 20 else {
            pendingRefine?.cancel()
            pendingRefine = nil
            refineToken += 1
            return
        }

        pendingRefine?.cancel()
        refineToken += 1
        let token = refineToken
        let delay = refineDelay()
        let work = DispatchWorkItem { [weak self] in
            guard let self, token == self.refineToken else { return }
            guard self.isDecoderIdle?() ?? true else {
                self.scheduleRefineIfUseful(seconds: seconds, fps: fps)
                return
            }
            self.issueExact(seconds: seconds, fps: fps, force: false)
        }
        pendingRefine = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refineDelay() -> TimeInterval {
        let base = max(0.08, min(0.24, exactSeekCostEMA * 1.5))
        if smoothedSpeed < 3 {
            return base
        }
        return base + 0.08
    }

    private func issueExact(seconds: Double, fps: Double, force: Bool) {
        let frame = frameIndex(seconds: seconds, fps: fps)
        guard force || lastExactFrame != frame else { return }
        lastExactFrame = frame
        onSeek?(seconds, true)
    }

    private func frameIndex(seconds: Double, fps: Double) -> Int {
        max(0, Int(round(seconds * max(1, fps))))
    }
}
