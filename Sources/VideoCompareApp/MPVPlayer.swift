import AppKit
import CMpv
import Foundation

final class MPVPlayer: @unchecked Sendable {
    let slot: VideoSlot

    private weak var hostView: NSView?
    private weak var renderView: MPVRenderView?
    private let queue: DispatchQueue
    private let eventQueue: DispatchQueue
    private var handle: OpaquePointer?
    private var eventLoopRunning = false
    private var videoVisible = true

    private(set) var fileURL: URL?
    private(set) var timePosition: Double = 0
    private(set) var duration: Double = 0
    private(set) var fps: Double = 60
    private(set) var isPaused = true
    var onStatusChanged: (() -> Void)?

    init(slot: VideoSlot, hostView: NSView) {
        self.slot = slot
        self.hostView = hostView
        self.renderView = hostView as? MPVRenderView
        self.queue = DispatchQueue(label: "VideoCompare.libmpv.\(slot.rawValue)")
        self.eventQueue = DispatchQueue(label: "VideoCompare.libmpv.events.\(slot.rawValue)")
    }

    @MainActor
    func startIfNeeded() {
        guard handle == nil, hostView != nil else { return }
        Diagnostics.log("starting libmpv \(slot.rawValue)")
        guard let ctx = mpv_create() else {
            DispatchQueue.main.async {
                self.showLaunchAlert("无法创建 libmpv 实例")
            }
            return
        }
        handle = ctx

        setOptionString("idle", "yes")
        setOptionString("terminal", "no")
        setOptionString("config", "no")
        setOptionString("load-scripts", "no")
        setOptionString("load-console", "no")
        setOptionString("load-stats-overlay", "no")
        setOptionString("ytdl", "no")
        setOptionString("osc", "no")
        setOptionString("scripts", "")
        setOptionString("hwdec", "videotoolbox")
        setOptionString("vo", "libmpv")
        setOptionString("profile", "fast")
        setOptionString("keep-open", "yes")
        setOptionString("pause", "yes")
        setOptionString("audio", "no")
        configureSubtitleOptions(disabled: AppSettings.shared.disableSubtitles)
        setOptionString("osd-level", "0")
        setOptionString("input-default-bindings", "no")
        setOptionString("input-vo-keyboard", "no")
        setOptionString("cursor-autohide", "no")

        let result = mpv_initialize(ctx)
        guard result >= 0 else {
            handle = nil
            mpv_terminate_destroy(ctx)
            DispatchQueue.main.async {
                self.showLaunchAlert("libmpv 初始化失败：\(result)")
            }
            return
        }
        guard renderView?.attach(handle: ctx) == true else {
            handle = nil
            mpv_terminate_destroy(ctx)
            DispatchQueue.main.async {
                self.showLaunchAlert("libmpv 渲染上下文初始化失败")
            }
            return
        }

        observeDouble("time-pos", id: 1)
        observeDouble("duration", id: 2)
        observeDouble("estimated-vf-fps", id: 3)
        observeDouble("container-fps", id: 4)
        startEventLoop()
    }

    @MainActor
    func terminate() {
        guard let ctx = handle else { return }
        handle = nil
        eventLoopRunning = false
        renderView?.detach()
        queue.async {
            mpv_terminate_destroy(ctx)
        }
    }

    @MainActor
    func load(url: URL) {
        Diagnostics.log("libmpv load \(slot.rawValue): \(url.path)")
        fileURL = url
        startIfNeeded()
        command(["loadfile", url.path, "replace"])
        setPause(true, force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.queryPlaybackInfo()
        }
    }

    func setPause(_ paused: Bool, force: Bool = false) {
        guard force || isPaused != paused else { return }
        isPaused = paused
        setFlagProperty("pause", paused)
        notifyStatus()
    }

    func togglePause() {
        setPause(!isPaused)
    }

    func seekAbsolute(_ seconds: Double, exact: Bool = true) {
        command(["seek", String(max(0, seconds)), exact ? "absolute+exact" : "absolute"])
    }

    func setVideoVisible(_ visible: Bool) {
        guard videoVisible != visible else { return }
        videoVisible = visible
        DispatchQueue.main.async {
            self.hostView?.isHidden = !visible
        }
    }

    func frameStep(_ direction: Int) {
        command([direction >= 0 ? "frame-step" : "frame-back-step"])
    }

    func applyTransform(_ transform: TransformState) {
        setDoubleProperty("video-pan-x", transform.panX)
        setDoubleProperty("video-pan-y", transform.panY)
        setDoubleProperty("video-zoom", transform.zoom)
    }

    func setSubtitleLoadingDisabled(_ disabled: Bool) {
        if disabled {
            setStringProperty("sub-auto", "no")
            setStringProperty("sid", "no")
            setFlagProperty("sub-visibility", false)
        } else {
            setStringProperty("sub-auto", "fuzzy")
            setStringProperty("sid", "auto")
            setFlagProperty("sub-visibility", true)
        }
    }

    func queryPlaybackInfo() {
        getDoubleProperty("time-pos") { [weak self] value in self?.updateTimePosition(value) }
        getDoubleProperty("duration") { [weak self] value in self?.updateDuration(value) }
        getDoubleProperty("estimated-vf-fps") { [weak self] value in self?.updateFPS(value) }
        getDoubleProperty("container-fps") { [weak self] value in self?.updateFPS(value) }
    }

    private func setOptionString(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_option_string(handle, name, value)
    }

    private func configureSubtitleOptions(disabled: Bool) {
        if disabled {
            setOptionString("sub-auto", "no")
            setOptionString("sid", "no")
            setOptionString("sub-visibility", "no")
        } else {
            setOptionString("sub-auto", "fuzzy")
            setOptionString("sid", "auto")
            setOptionString("sub-visibility", "yes")
        }
    }

    private func observeDouble(_ name: String, id: UInt64) {
        guard let handle else { return }
        mpv_observe_property(handle, id, name, MPV_FORMAT_DOUBLE)
    }

    private func command(_ arguments: [String]) {
        queue.async {
            guard let handle = self.handle else { return }
            withCStringArray(arguments) { argv in
                mpv_command(handle, argv)
            }
        }
    }

    private func setFlagProperty(_ name: String, _ value: Bool) {
        queue.async {
            guard let handle = self.handle else { return }
            var flag: Int32 = value ? 1 : 0
            mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
        }
    }

    private func setDoubleProperty(_ name: String, _ value: Double) {
        queue.async {
            guard let handle = self.handle else { return }
            var doubleValue = value
            mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &doubleValue)
        }
    }

    private func setStringProperty(_ name: String, _ value: String) {
        queue.async {
            guard let handle = self.handle else { return }
            value.withCString { pointer in
                var mutablePointer: UnsafePointer<CChar>? = pointer
                mpv_set_property(handle, name, MPV_FORMAT_STRING, &mutablePointer)
            }
        }
    }

    private func getDoubleProperty(_ name: String, completion: @escaping (NSNumber) -> Void) {
        queue.async {
            guard let handle = self.handle else { return }
            var value: Double = 0
            let result = mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)
            if result >= 0 {
                completion(NSNumber(value: value))
            }
        }
    }

    private func startEventLoop() {
        guard !eventLoopRunning else { return }
        eventLoopRunning = true
        eventQueue.async {
            while self.eventLoopRunning {
                guard let handle = self.handle,
                      let event = mpv_wait_event(handle, 0.1) else {
                    continue
                }
                self.handle(event: event)
            }
        }
    }

    private func handle(event: UnsafeMutablePointer<mpv_event>) {
        guard event.pointee.event_id == MPV_EVENT_PROPERTY_CHANGE,
              let data = event.pointee.data else { return }
        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        guard property.format == MPV_FORMAT_DOUBLE,
              let rawName = property.name,
              let rawData = property.data else { return }
        let name = String(cString: rawName)
        let value = rawData.assumingMemoryBound(to: Double.self).pointee

        switch name {
        case "time-pos":
            updateTimePosition(NSNumber(value: value))
        case "duration":
            updateDuration(NSNumber(value: value))
        case "estimated-vf-fps", "container-fps":
            updateFPS(NSNumber(value: value))
        default:
            break
        }
    }

    private func updateTimePosition(_ value: NSNumber) {
        let doubleValue = value.doubleValue
        DispatchQueue.main.async {
            self.timePosition = doubleValue
            self.notifyStatus()
        }
    }

    private func updateDuration(_ value: NSNumber) {
        let doubleValue = value.doubleValue
        DispatchQueue.main.async {
            self.duration = doubleValue
            self.notifyStatus()
        }
    }

    private func updateFPS(_ value: NSNumber) {
        guard value.doubleValue > 1 else { return }
        let doubleValue = value.doubleValue
        DispatchQueue.main.async {
            self.fps = doubleValue
            self.notifyStatus()
        }
    }

    private func notifyStatus() {
        if Thread.isMainThread {
            self.onStatusChanged?()
        } else {
            DispatchQueue.main.async {
                self.onStatusChanged?()
            }
        }
    }

    @MainActor
    private func showLaunchAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "启动播放器失败"
        alert.informativeText = message
        alert.runModal()
    }
}

private func withCStringArray<R>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> R) -> R {
    var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    defer {
        for cString in cStrings {
            free(cString)
        }
    }
    cStrings.append(nil)
    return cStrings.withUnsafeMutableBufferPointer { buffer in
        let rebound = UnsafeMutableRawPointer(buffer.baseAddress!).assumingMemoryBound(to: Optional<UnsafePointer<CChar>>.self)
        return body(rebound)
    }
}
