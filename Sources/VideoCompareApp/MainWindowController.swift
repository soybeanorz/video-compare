import AppKit
import Foundation
import UniformTypeIdentifiers

final class ContinuousSeekSlider: NSSlider {
    var onTrackingChanged: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onTrackingChanged?(true)
        super.mouseDown(with: event)
        onTrackingChanged?(false)
    }
}

final class MainWindowController: NSWindowController {
    private let canvas = VideoCanvasView()
    private var playerA: NativeVideoPlayer!
    private var playerB: NativeVideoPlayer!

    private let layoutControl = NSSegmentedControl(labels: CompareLayout.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let syncPlayButton = NSButton(title: "同步播放", target: nil, action: nil)
    private let syncPauseButton = NSButton(title: "同步暂停", target: nil, action: nil)
    private let prevFrameButton = NSButton(title: "-1 帧", target: nil, action: nil)
    private let nextFrameButton = NSButton(title: "+1 帧", target: nil, action: nil)
    private let playAButton = NSButton(title: "A 播放/暂停", target: nil, action: nil)
    private let playBButton = NSButton(title: "B 播放/暂停", target: nil, action: nil)
    private let offsetAMinus = NSButton(title: "A 偏移 -1f", target: nil, action: nil)
    private let offsetAPlus = NSButton(title: "A 偏移 +1f", target: nil, action: nil)
    private let offsetBMinus = NSButton(title: "B 偏移 -1f", target: nil, action: nil)
    private let offsetBPlus = NSButton(title: "B 偏移 +1f", target: nil, action: nil)
    private let targetControl = NSSegmentedControl(labels: ["调 A", "调 B"], trackingMode: .selectOne, target: nil, action: nil)
    private let zoomOutButton = NSButton(title: "缩小", target: nil, action: nil)
    private let zoomInButton = NSButton(title: "放大", target: nil, action: nil)
    private let resetTransformButton = NSButton(title: "重置对齐", target: nil, action: nil)
    private let clearStateButton = NSButton(title: "清理本组", target: nil, action: nil)
    private let timeSlider = ContinuousSeekSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeInfoLabel = NSTextField(labelWithString: "同步 00:00.000 / 00:00.000  F0")
    private let videoASlider = ContinuousSeekSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let videoBSlider = ContinuousSeekSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let videoAInfoLabel = NSTextField(labelWithString: "A 00:00.000  F0")
    private let videoBInfoLabel = NSTextField(labelWithString: "B 00:00.000  F0")

    private var syncState = SyncState()
    private var currentPair: VideoPairIdentity?
    private var disableSubtitlesMenuItem: NSMenuItem?
    private let recentMenu = NSMenu(title: "最近视频组")
    private var statusRefreshPending = false
    private var isTrackingTimeSlider = false
    private var isTrackingVideoASlider = false
    private var isTrackingVideoBSlider = false
    private var pendingCoalescedSeek: Double?
    private var coalescedSeekScheduled = false
    private var isSynchronizedPlaying = false
    private var synchronizedPlaybackToken = 0
    private var selectedSlot: VideoSlot? {
        didSet {
            canvas.selectedSlot = selectedSlot
            switch selectedSlot {
            case .a: targetControl.selectedSegment = 0
            case .b: targetControl.selectedSegment = 1
            case nil: targetControl.selectedSegment = -1
            }
            scheduleStatusRefresh()
        }
    }

    convenience init() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        let window = VideoCompareWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VideoCompare"
        window.minSize = NSSize(width: 980, height: 620)
        self.init(window: window)
        window.contentView = content
        window.delegate = self
        window.onKeyPressed = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        window.onMouseDownInContent = { [weak self] point in
            self?.handleMouseDownInContent(point)
        }
        setup()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
    }

    private func setup() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        playerA = NativeVideoPlayer(slot: .a)
        playerB = NativeVideoPlayer(slot: .b)
        playerA.onStatusChanged = { [weak self] in self?.scheduleStatusRefresh() }
        playerB.onStatusChanged = { [weak self] in self?.scheduleStatusRefresh() }
        playerA.onFrameDecoded = { [weak self] slot, pixelBuffer, _ in self?.canvas.renderer.setFrame(pixelBuffer, slot: slot) }
        playerB.onFrameDecoded = { [weak self] slot, pixelBuffer, _ in self?.canvas.renderer.setFrame(pixelBuffer, slot: slot) }
        playerA.onVisibilityChanged = { [weak self] slot, visible in self?.canvas.renderer.setVisible(visible, slot: slot) }
        playerB.onVisibilityChanged = { [weak self] slot, visible in self?.canvas.renderer.setVisible(visible, slot: slot) }
        playerA.onOpenFailed = { [weak self] slot, message in self?.showLoadError(slot: slot, message: message) }
        playerB.onOpenFailed = { [weak self] slot, message in self?.showLoadError(slot: slot, message: message) }

        canvas.containerA.onFileDropped = { [weak self] _, url in self?.load(url: url, slot: .a) }
        canvas.containerB.onFileDropped = { [weak self] _, url in self?.load(url: url, slot: .b) }
        canvas.onPanDragged = { [weak self] slot, dx, dy in
            if self?.selectedSlot != slot {
                self?.selectedSlot = slot
            }
            self?.adjustTransform(slot: slot, dx: dx, dy: dy, dz: 0)
        }
        canvas.onZoomDragged = { [weak self] slot, dz in
            if self?.selectedSlot != slot {
                self?.selectedSlot = slot
            }
            self?.adjustTransform(slot: slot, dx: 0, dy: 0, dz: dz)
        }
        canvas.onAlignmentGestureEnded = { [weak self] in
            self?.saveState()
        }
        canvas.onToggleChanged = { [weak self] in
            self?.seekVisibleToggleFrame()
        }
        canvas.onSelectionChanged = { [weak self] slot in
            guard self?.selectedSlot != slot else { return }
            self?.selectedSlot = slot
        }

        let controls = [
            layoutControl,
            zoomOutButton, zoomInButton, resetTransformButton,
            timeSlider, timeInfoLabel,
            videoAInfoLabel, videoASlider,
            videoBInfoLabel, videoBSlider
        ] as [NSView]
        controls.forEach(content.addSubview)
        content.addSubview(canvas)

        setupMenu()
        configureControls()
        refreshRecentMenu()
        layoutControl.selectedSegment = CompareLayout.sideBySideHorizontal.rawValue
        selectedSlot = nil

    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        layoutContent()
    }

    func loadInitial(a: URL, b: URL) {
        Diagnostics.log("loadInitial")
        load(url: a, slot: .a)
        load(url: b, slot: .b)
    }

    func startSynchronizedPlayback() {
        syncPlay()
    }

    func runSeekStress() {
        let duration = max(playerA.duration, playerB.duration)
        guard duration > 0 else { return }
        syncPause()
        for index in 0..<60 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.05) {
                let fraction = Double(index % 30) / 29.0
                self.seekToBaseTime(fraction * duration, exact: false)
                if index == 59 {
                    self.seekToBaseTime(fraction * duration, exact: true)
                }
            }
        }
    }

    private func configureControls() {
        for button in [syncPlayButton, syncPauseButton, prevFrameButton, nextFrameButton,
                       playAButton, playBButton, offsetAMinus, offsetAPlus, offsetBMinus, offsetBPlus,
                       zoomOutButton, zoomInButton,
                       resetTransformButton, clearStateButton] {
            button.bezelStyle = .rounded
            button.target = self
        }

        syncPlayButton.action = #selector(syncPlay)
        syncPauseButton.action = #selector(syncPause)
        prevFrameButton.action = #selector(prevFrame)
        nextFrameButton.action = #selector(nextFrame)
        playAButton.action = #selector(toggleA)
        playBButton.action = #selector(toggleB)
        offsetAMinus.action = #selector(offsetAMinusFrame)
        offsetAPlus.action = #selector(offsetAPlusFrame)
        offsetBMinus.action = #selector(offsetBMinusFrame)
        offsetBPlus.action = #selector(offsetBPlusFrame)
        zoomOutButton.action = #selector(zoomOut)
        zoomInButton.action = #selector(zoomIn)
        resetTransformButton.action = #selector(resetTransform)
        clearStateButton.action = #selector(clearCurrentState)

        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged)
        targetControl.target = self
        targetControl.action = #selector(targetSelectionChanged)
        timeSlider.target = self
        timeSlider.action = #selector(sliderChanged)
        timeSlider.isContinuous = true
        timeSlider.onTrackingChanged = { [weak self] tracking in
            guard let self else { return }
            self.isTrackingTimeSlider = tracking
            if !tracking {
                self.seekToSliderPosition(exact: true)
            }
        }
        videoASlider.target = self
        videoASlider.action = #selector(videoASliderChanged)
        videoASlider.isContinuous = true
        videoASlider.onTrackingChanged = { [weak self] tracking in
            guard let self else { return }
            self.isTrackingVideoASlider = tracking
            if !tracking {
                self.seekIndividualVideo(slot: .a, exact: true)
                self.saveState()
            }
        }
        videoBSlider.target = self
        videoBSlider.action = #selector(videoBSliderChanged)
        videoBSlider.isContinuous = true
        videoBSlider.onTrackingChanged = { [weak self] tracking in
            guard let self else { return }
            self.isTrackingVideoBSlider = tracking
            if !tracking {
                self.seekIndividualVideo(slot: .b, exact: true)
                self.saveState()
            }
        }
        for label in [timeInfoLabel, videoAInfoLabel, videoBInfoLabel] {
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
        }
    }

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 VideoCompare", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        let loadAItem = NSMenuItem(title: "加载 A...", action: #selector(openA), keyEquivalent: "1")
        loadAItem.target = self
        fileMenu.addItem(loadAItem)
        let loadBItem = NSMenuItem(title: "加载 B...", action: #selector(openB), keyEquivalent: "2")
        loadBItem.target = self
        fileMenu.addItem(loadBItem)
        fileMenu.addItem(.separator())
        let recentItem = NSMenuItem(title: "最近视频组", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileItem.submenu = fileMenu

        let playbackItem = NSMenuItem()
        mainMenu.addItem(playbackItem)
        let playbackMenu = NSMenu(title: "播放")
        let subtitlesItem = NSMenuItem(title: "不加载字幕", action: #selector(toggleDisableSubtitles), keyEquivalent: "")
        subtitlesItem.target = self
        subtitlesItem.state = AppSettings.shared.disableSubtitles ? .on : .off
        playbackMenu.addItem(subtitlesItem)
        playbackItem.submenu = playbackMenu
        disableSubtitlesMenuItem = subtitlesItem

        NSApp.mainMenu = mainMenu
    }

    private func layoutContent() {
        guard let content = window?.contentView else { return }
        let w = content.bounds.width
        let h = content.bounds.height
        let pad: CGFloat = 12
        let rowH: CGFloat = 28
        var y = pad

        func place(_ view: NSView, x: CGFloat, width: CGFloat) {
            view.frame = NSRect(x: x, y: y, width: width, height: rowH)
        }

        let layoutWidth: CGFloat = 360
        let zoomWidth: CGFloat = 58
        let resetWidth: CGFloat = 84
        let gap: CGFloat = 8
        let groupWidth = layoutWidth + gap * 3 + zoomWidth * 2 + resetWidth
        let groupX = max(pad, floor((w - groupWidth) / 2))
        place(layoutControl, x: groupX, width: layoutWidth)
        place(zoomOutButton, x: groupX + layoutWidth + gap, width: zoomWidth)
        place(zoomInButton, x: groupX + layoutWidth + gap * 2 + zoomWidth, width: zoomWidth)
        place(resetTransformButton, x: groupX + layoutWidth + gap * 3 + zoomWidth * 2, width: resetWidth)

        y += rowH + 8
        let infoWidth: CGFloat = min(360, max(240, w * 0.28))
        timeSlider.frame = NSRect(x: pad, y: y, width: max(100, w - pad * 3 - infoWidth), height: rowH)
        timeInfoLabel.frame = NSRect(x: w - pad - infoWidth, y: y, width: infoWidth, height: rowH)

        y += rowH + 6
        let halfWidth = floor((w - pad * 2 - gap) / 2)
        let labelWidth: CGFloat = 150
        videoAInfoLabel.frame = NSRect(x: pad, y: y, width: min(labelWidth, halfWidth * 0.45), height: rowH)
        videoASlider.frame = NSRect(x: videoAInfoLabel.frame.maxX + gap, y: y, width: max(80, halfWidth - videoAInfoLabel.frame.width - gap), height: rowH)
        let bX = pad + halfWidth + gap
        videoBInfoLabel.frame = NSRect(x: bX, y: y, width: min(labelWidth, halfWidth * 0.45), height: rowH)
        videoBSlider.frame = NSRect(x: videoBInfoLabel.frame.maxX + gap, y: y, width: max(80, halfWidth - videoBInfoLabel.frame.width - gap), height: rowH)

        let top = y + rowH + pad
        canvas.frame = NSRect(x: 0, y: top, width: w, height: max(100, h - top))
    }

    @objc private func openA() { open(slot: .a) }
    @objc private func openB() { open(slot: .b) }

    private func open(slot: VideoSlot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["mp4", "mov", "mkv"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url, slot: slot)
        }
    }

    private func load(url: URL, slot: VideoSlot) {
        Diagnostics.log("load \(slot.rawValue): \(url.path)")
        switch slot {
        case .a:
            canvas.labelA.stringValue = "A: \(url.path)"
            playerA.load(url: url)
        case .b:
            canvas.labelB.stringValue = "B: \(url.path)"
            playerB.load(url: url)
        }
        loadPairStateIfReady()
    }

    private func loadPairStateIfReady() {
        guard let a = playerA.fileURL, let b = playerB.fileURL else { return }
        let pair = VideoPairIdentity(a: FileIdentity(url: a), b: FileIdentity(url: b))
        currentPair = pair
        syncState = PersistenceStore.shared.loadState(for: pair)
        playerA.applyTransform(syncState.transformA)
        playerB.applyTransform(syncState.transformB)
        canvas.renderer.transformA = syncState.transformA
        canvas.renderer.transformB = syncState.transformB
        PersistenceStore.shared.addRecent(a: a, b: b)
        refreshRecentMenu()
        refreshStatus()
    }

    @objc private func layoutChanged() {
        guard let layout = CompareLayout(rawValue: layoutControl.selectedSegment) else { return }
        canvas.layoutMode = layout
        canvas.needsDisplay = true
    }

    @objc private func targetSelectionChanged() {
        switch targetControl.selectedSegment {
        case 0: selectedSlot = .a
        case 1: selectedSlot = .b
        default: selectedSlot = nil
        }
    }

    @objc private func syncPlay() {
        startSynchronizedBarrierPlayback()
    }

    @objc private func syncPause() {
        pauseBothIfNeeded()
    }

    @objc private func toggleA() {
        guard !canvas.allowsAlignmentAdjustment else {
            toggleSynchronizedPlayback()
            return
        }
        stopSynchronizedBarrierPlayback()
        playerA.togglePause()
    }

    @objc private func toggleB() {
        guard !canvas.allowsAlignmentAdjustment else {
            toggleSynchronizedPlayback()
            return
        }
        stopSynchronizedBarrierPlayback()
        playerB.togglePause()
    }

    @objc private func prevFrame() { stepBySelection(-1) }
    @objc private func nextFrame() { stepBySelection(1) }

    @objc private func offsetAMinusFrame() { adjustOffset(slot: .a, delta: -1) }
    @objc private func offsetAPlusFrame() { adjustOffset(slot: .a, delta: 1) }
    @objc private func offsetBMinusFrame() { adjustOffset(slot: .b, delta: -1) }
    @objc private func offsetBPlusFrame() { adjustOffset(slot: .b, delta: 1) }

    private func adjustOffset(slot: VideoSlot, delta: Int) {
        pauseBothIfNeeded()
        switch slot {
        case .a: syncState.offsetFramesA += delta
        case .b: syncState.offsetFramesB += delta
        }
        seekPlayersToCurrentBase()
        saveState()
        refreshStatus()
    }

    private func stepBySelection(_ delta: Int) {
        if let selectedSlot {
            adjustOffset(slot: selectedSlot, delta: delta)
        } else {
            stepSyncFrames(delta)
        }
    }

    private func stepSyncFrames(_ delta: Int) {
        pauseBothIfNeeded()
        let fps = max(1, playerA.fps)
        let base = currentBaseTime() + Double(delta) / fps
        seekToBaseTime(base)
    }

    private func currentBaseTime() -> Double {
        if playerA.fileURL != nil {
            return max(0, playerA.timePosition - seconds(forFrames: syncState.offsetFramesA, fps: playerA.fps))
        }
        return max(0, playerB.timePosition - seconds(forFrames: syncState.offsetFramesB, fps: playerB.fps))
    }

    private func seekPlayersToCurrentBase() {
        seekToBaseTime(currentBaseTime())
    }

    private func seekToBaseTime(_ base: Double, exact: Bool = true) {
        let aTime = base + seconds(forFrames: syncState.offsetFramesA, fps: playerA.fps)
        let bTime = base + seconds(forFrames: syncState.offsetFramesB, fps: playerB.fps)
        if !exact && canvas.layoutMode == .overlapToggle {
            if canvas.showingAInToggle {
                display(playerA, at: aTime, exact: false)
            } else {
                display(playerB, at: bTime, exact: false)
            }
            return
        }
        display(playerA, at: aTime, exact: exact)
        display(playerB, at: bTime, exact: exact)
    }

    private func display(_ player: NativeVideoPlayer, at seconds: Double, exact: Bool = true) {
        let hasContent = seconds >= 0 && (player.duration <= 0 || seconds <= player.duration)
        player.setVideoVisible(hasContent)
        if hasContent {
            player.seekAbsolute(seconds, exact: exact)
        }
    }

    private func seconds(forFrames frames: Int, fps: Double) -> Double {
        Double(frames) / max(1, fps)
    }

    @objc private func sliderChanged() {
        seekToSliderPosition(exact: !isTrackingTimeSlider)
    }

    @objc private func videoASliderChanged() {
        seekIndividualVideo(slot: .a, exact: !isTrackingVideoASlider)
    }

    @objc private func videoBSliderChanged() {
        seekIndividualVideo(slot: .b, exact: !isTrackingVideoBSlider)
    }

    private func seekToSliderPosition(exact: Bool) {
        let duration = max(playerA.duration, playerB.duration)
        guard duration > 0 else { return }
        pauseBothIfNeeded()
        let base = timeSlider.doubleValue * duration
        if exact {
            seekToBaseTime(base, exact: true)
        } else {
            coalesceFastSeek(to: base)
        }
    }

    private func coalesceFastSeek(to base: Double) {
        pendingCoalescedSeek = base
        guard !coalescedSeekScheduled else { return }
        coalescedSeekScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) {
            self.coalescedSeekScheduled = false
            guard let base = self.pendingCoalescedSeek else { return }
            self.pendingCoalescedSeek = nil
            self.seekToBaseTime(base, exact: false)
        }
    }

    private func seekIndividualVideo(slot: VideoSlot, exact: Bool) {
        stopSynchronizedBarrierPlayback()
        let player = slot == .a ? playerA! : playerB!
        let slider = slot == .a ? videoASlider : videoBSlider
        guard player.duration > 0 else { return }
        if !player.isPaused {
            player.setPause(true)
        }
        let targetTime = slider.doubleValue * player.duration
        updateOffsetAfterIndividualSeek(slot: slot, targetTime: targetTime)
        player.setVideoVisible(targetTime >= 0 && targetTime <= player.duration)
        player.seekAbsolute(targetTime, exact: exact)
        refreshStatus()
    }

    private func updateOffsetAfterIndividualSeek(slot: VideoSlot, targetTime: Double) {
        switch slot {
        case .a:
            let base = playerB.fileURL != nil
                ? playerB.timePosition - seconds(forFrames: syncState.offsetFramesB, fps: playerB.fps)
                : 0
            syncState.offsetFramesA = Int(round((targetTime - base) * max(1, playerA.fps)))
        case .b:
            let base = playerA.fileURL != nil
                ? playerA.timePosition - seconds(forFrames: syncState.offsetFramesA, fps: playerA.fps)
                : 0
            syncState.offsetFramesB = Int(round((targetTime - base) * max(1, playerB.fps)))
        }
    }

    @objc private func zoomOut() {
        guard canvas.allowsAlignmentAdjustment else { return }
        adjustTransform(dx: 0, dy: 0, dz: -0.05)
        saveState()
    }

    @objc private func zoomIn() {
        guard canvas.allowsAlignmentAdjustment else { return }
        adjustTransform(dx: 0, dy: 0, dz: 0.05)
        saveState()
    }

    @objc private func toggleDisableSubtitles() {
        let value = !AppSettings.shared.disableSubtitles
        AppSettings.shared.disableSubtitles = value
        disableSubtitlesMenuItem?.state = value ? .on : .off
        playerA.setSubtitleLoadingDisabled(value)
        playerB.setSubtitleLoadingDisabled(value)
    }

    private func adjustTransform(dx: Double, dy: Double, dz: Double) {
        guard let selectedSlot else { return }
        adjustTransform(slot: selectedSlot, dx: dx, dy: dy, dz: dz)
    }

    private func adjustTransform(slot: VideoSlot, dx: Double, dy: Double, dz: Double) {
        guard canvas.allowsAlignmentAdjustment else { return }
        if slot == .a {
            syncState.transformA.panX += dx
            syncState.transformA.panY += dy
            syncState.transformA.zoom += dz
            canvas.renderer.transformA = syncState.transformA
            playerA.applyTransform(syncState.transformA)
        } else {
            syncState.transformB.panX += dx
            syncState.transformB.panY += dy
            syncState.transformB.zoom += dz
            canvas.renderer.transformB = syncState.transformB
            playerB.applyTransform(syncState.transformB)
        }
    }

    @objc private func resetTransform() {
        guard canvas.allowsAlignmentAdjustment, let slot = selectedSlot else { return }
        if slot == .a {
            syncState.transformA = TransformState()
            canvas.renderer.transformA = syncState.transformA
            playerA.applyTransform(syncState.transformA)
        } else {
            syncState.transformB = TransformState()
            canvas.renderer.transformB = syncState.transformB
            playerB.applyTransform(syncState.transformB)
        }
        saveState()
        refreshStatus()
    }

    @objc private func clearCurrentState() {
        guard let pair = currentPair else { return }
        PersistenceStore.shared.clearState(for: pair)
        syncState = SyncState()
        canvas.renderer.transformA = syncState.transformA
        canvas.renderer.transformB = syncState.transformB
        playerA.applyTransform(syncState.transformA)
        playerB.applyTransform(syncState.transformB)
        refreshStatus()
    }

    @objc private func openRecentPair(_ sender: NSMenuItem) {
        guard let paths = sender.representedObject as? [String], paths.count == 2 else { return }
        load(url: URL(fileURLWithPath: paths[0]), slot: .a)
        load(url: URL(fileURLWithPath: paths[1]), slot: .b)
    }

    private func refreshRecentMenu() {
        recentMenu.removeAllItems()
        let recents = PersistenceStore.shared.loadRecents()
        if recents.isEmpty {
            let empty = NSMenuItem(title: "无最近视频组", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            return
        }
        for recent in recents {
            let item = NSMenuItem(title: recent.title, action: #selector(openRecentPair(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [recent.aPath, recent.bPath]
            recentMenu.addItem(item)
        }
    }

    private func scheduleStatusRefresh() {
        guard !statusRefreshPending else { return }
        statusRefreshPending = true
        DispatchQueue.main.async {
            self.statusRefreshPending = false
            self.refreshStatus()
        }
    }

    private func refreshStatus() {
        let duration = max(playerA.duration, playerB.duration)
        if duration > 0 && !isTrackingTimeSlider {
            timeSlider.doubleValue = min(1, max(0, currentBaseTime() / duration))
        }
        if playerA.duration > 0 && !isTrackingVideoASlider {
            videoASlider.doubleValue = min(1, max(0, playerA.timePosition / playerA.duration))
        }
        if playerB.duration > 0 && !isTrackingVideoBSlider {
            videoBSlider.doubleValue = min(1, max(0, playerB.timePosition / playerB.duration))
        }
        let base = currentBaseTime()
        timeInfoLabel.stringValue = "同步 \(formatTime(base)) / \(formatTime(duration))  F\(frameNumber(base, fps: playerA.fps))"
        videoAInfoLabel.stringValue = "A \(formatTime(playerA.timePosition))  F\(frameNumber(playerA.timePosition, fps: playerA.fps))"
        videoBInfoLabel.stringValue = "B \(formatTime(playerB.timePosition))  F\(frameNumber(playerB.timePosition, fps: playerB.fps))"
        updateEndVisibility()
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00.000" }
        let minutes = Int(seconds / 60)
        let wholeSeconds = Int(seconds) % 60
        let milliseconds = Int((seconds - floor(seconds)) * 1000)
        return String(format: "%02d:%02d.%03d", minutes, wholeSeconds, milliseconds)
    }

    private func frameNumber(_ seconds: Double, fps: Double) -> Int {
        max(0, Int(round(seconds * max(1, fps))))
    }

    private func pauseBothIfNeeded() {
        stopSynchronizedBarrierPlayback()
        if !playerA.isPaused { playerA.setPause(true) }
        if !playerB.isPaused { playerB.setPause(true) }
    }

    private func toggleSynchronizedPlayback() {
        if isSynchronizedPlaying {
            syncPause()
        } else {
            syncPlay()
        }
    }

    private func startSynchronizedBarrierPlayback() {
        guard playerA.fileURL != nil || playerB.fileURL != nil else { return }
        if !playerA.isPaused { playerA.setPause(true) }
        if !playerB.isPaused { playerB.setPause(true) }
        isSynchronizedPlaying = true
        synchronizedPlaybackToken += 1
        let token = synchronizedPlaybackToken
        playerA.setSynchronizedPlaybackActive(true)
        playerB.setSynchronizedPlaybackActive(true)
        scheduleSynchronizedFrame(token: token)
    }

    private func stopSynchronizedBarrierPlayback() {
        guard isSynchronizedPlaying else { return }
        isSynchronizedPlaying = false
        synchronizedPlaybackToken += 1
        playerA.setSynchronizedPlaybackActive(false)
        playerB.setSynchronizedPlaybackActive(false)
    }

    private func scheduleSynchronizedFrame(token: Int) {
        guard isSynchronizedPlaying, token == synchronizedPlaybackToken else { return }
        let started = CACurrentMediaTime()
        var frameA: NativeVideoFrame?
        var frameB: NativeVideoFrame?
        var callbacks = 0

        func finishIfReady() {
            callbacks += 1
            guard callbacks == 2 else { return }
            guard self.isSynchronizedPlaying, token == self.synchronizedPlaybackToken else { return }

            if let frameA {
                self.playerA.setVideoVisible(true)
                self.playerA.presentSynchronizedFrame(frameA)
            } else {
                self.playerA.setVideoVisible(false)
            }

            if let frameB {
                self.playerB.setVideoVisible(true)
                self.playerB.presentSynchronizedFrame(frameB)
            } else {
                self.playerB.setVideoVisible(false)
            }

            if frameA == nil && frameB == nil {
                self.stopSynchronizedBarrierPlayback()
                return
            }

            let frameInterval = 1.0 / max(1, max(self.playerA.fps, self.playerB.fps))
            let elapsed = CACurrentMediaTime() - started
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, frameInterval - elapsed)) {
                self.scheduleSynchronizedFrame(token: token)
            }
        }

        playerA.decodeNextFrameForSynchronization { frame in
            frameA = frame
            finishIfReady()
        }
        playerB.decodeNextFrameForSynchronization { frame in
            frameB = frame
            finishIfReady()
        }
    }

    private func updateEndVisibility() {
        let base = currentBaseTime()
        let aTime = base + seconds(forFrames: syncState.offsetFramesA, fps: playerA.fps)
        let bTime = base + seconds(forFrames: syncState.offsetFramesB, fps: playerB.fps)
        playerA.setVideoVisible(aTime >= 0 && (playerA.duration <= 0 || aTime <= playerA.duration))
        playerB.setVideoVisible(bTime >= 0 && (playerB.duration <= 0 || bTime <= playerB.duration))
    }

    private func saveState() {
        guard let pair = currentPair else { return }
        PersistenceStore.shared.saveState(syncState, for: pair)
    }

    private func seekVisibleToggleFrame() {
        guard canvas.layoutMode == .overlapToggle else { return }
        let base = currentBaseTime()
        if canvas.showingAInToggle {
            display(playerA, at: base + seconds(forFrames: syncState.offsetFramesA, fps: playerA.fps), exact: false)
        } else {
            display(playerB, at: base + seconds(forFrames: syncState.offsetFramesB, fps: playerB.fps), exact: false)
        }
    }

    private func showLoadError(slot: VideoSlot, message: String) {
        let alert = NSAlert()
        alert.messageText = "加载 \(slot.rawValue.uppercased()) 失败"
        alert.informativeText = message
        alert.runModal()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 48:
            guard canvas.layoutMode == .overlapToggle else { return false }
            canvas.toggleOverlapDisplay()
            return true
        case 123:
            stepBySelection(-1)
            return true
        case 124:
            stepBySelection(1)
            return true
        case 49:
            togglePlaybackBySelection()
            return true
        default:
            return false
        }
    }

    private func togglePlaybackBySelection() {
        if canvas.allowsAlignmentAdjustment {
            toggleSynchronizedPlayback()
            return
        }
        switch selectedSlot {
        case .a:
            stopSynchronizedBarrierPlayback()
            playerA.togglePause()
        case .b:
            stopSynchronizedBarrierPlayback()
            playerB.togglePause()
        case nil:
            toggleSynchronizedPlayback()
        }
    }

    private func handleMouseDownInContent(_ point: NSPoint) {
        guard let content = window?.contentView else { return }
        if canvas.frame.contains(point) {
            let canvasPoint = canvas.convert(point, from: content)
            selectedSlot = canvas.selectSlot(at: canvasPoint)
        } else if [
            layoutControl,
            zoomOutButton,
            zoomInButton,
            resetTransformButton,
            timeSlider,
            timeInfoLabel,
            videoAInfoLabel,
            videoASlider,
            videoBInfoLabel,
            videoBSlider
        ].contains(where: { $0.frame.contains(point) }) {
            return
        } else {
            selectedSlot = nil
            canvas.clearSelection()
        }
    }
}

extension MainWindowController: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        layoutContent()
    }
}
