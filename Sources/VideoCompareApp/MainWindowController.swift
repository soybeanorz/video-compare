import AppKit
import Foundation
import UniformTypeIdentifiers

final class ContinuousSeekSlider: NSControl {
    var onTrackingChanged: ((Bool) -> Void)?
    var onLoopRangeSelected: ((ClosedRange<Double>) -> Void)?
    var onLoopRangeCancelled: (() -> Void)?
    var loopRange: ClosedRange<Double>? {
        didSet { needsDisplay = true }
    }
    private var value: Double = 0

    convenience init(value: Double, minValue: Double, maxValue: Double, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        doubleValue = value
        self.target = target
        self.action = action
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var doubleValue: Double {
        get { value }
        set {
            value = min(1, max(0, newValue))
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let trackH: CGFloat = 4
        let thumbW: CGFloat = 4
        let thumbH: CGFloat = min(bounds.height, 24)
        let track = NSRect(x: 0, y: floor((bounds.height - trackH) / 2), width: bounds.width, height: trackH)
        let progressW = max(0, min(bounds.width, bounds.width * CGFloat(value)))

        NSColor(calibratedWhite: 0.35, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

        NSColor(calibratedWhite: 0.86, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: progressW, height: track.height), xRadius: 2, yRadius: 2).fill()

        if let loopRange {
            let x1 = bounds.width * CGFloat(loopRange.lowerBound)
            let x2 = bounds.width * CGFloat(loopRange.upperBound)
            let rangeRect = NSRect(x: min(x1, x2), y: track.minY - 5, width: max(2, abs(x2 - x1)), height: track.height + 10)
            NSColor.systemYellow.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: rangeRect, xRadius: 2, yRadius: 2).fill()
            NSColor.systemYellow.withAlphaComponent(0.95).setFill()
            NSBezierPath(rect: NSRect(x: rangeRect.minX, y: rangeRect.minY - 2, width: 2, height: rangeRect.height + 4)).fill()
            NSBezierPath(rect: NSRect(x: rangeRect.maxX - 2, y: rangeRect.minY - 2, width: 2, height: rangeRect.height + 4)).fill()
        }

        let thumbX = min(bounds.width - thumbW, max(0, progressW - thumbW / 2))
        NSBezierPath(roundedRect: NSRect(x: thumbX, y: floor((bounds.height - thumbH) / 2), width: thumbW, height: thumbH), xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            trackLoopRange(from: event)
            return
        }
        onTrackingChanged?(true)
        updateValue(with: event)
        while true {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if next.type == .leftMouseUp { break }
            updateValue(with: next)
        }
        onTrackingChanged?(false)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let loopRange else { return }
        let fraction = fraction(for: event)
        if loopRange.contains(fraction) {
            onLoopRangeCancelled?()
        }
    }

    private func updateValue(with event: NSEvent) {
        doubleValue = fraction(for: event)
        sendAction(action, to: target)
    }

    private func trackLoopRange(from event: NSEvent) {
        let start = fraction(for: event)
        var end = start
        loopRange = min(start, end)...max(start, end)
        while true {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            end = fraction(for: next)
            loopRange = min(start, end)...max(start, end)
            if next.type == .leftMouseUp { break }
        }
        onLoopRangeSelected?(min(start, end)...max(start, end))
    }

    private func fraction(for event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0 else { return 0 }
        return min(1, max(0, Double(point.x / bounds.width)))
    }
}

final class TimelineControl: NSView {
    let previousButton = NSButton(title: "<", target: nil, action: nil)
    let playButton = NSButton(title: "▶", target: nil, action: nil)
    let nextButton = NSButton(title: ">", target: nil, action: nil)
    let slider = ContinuousSeekSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let currentLabel = NSTextField(labelWithString: "00:00")
    private let durationLabel = NSTextField(labelWithString: "00:00")
    var showsBackground = true {
        didSet {
            layer?.backgroundColor = showsBackground ? NSColor(calibratedWhite: 0.08, alpha: 0.78).cgColor : NSColor.clear.cgColor
            applyTheme()
        }
    }
    var showsTimeLabels = true {
        didSet {
            currentLabel.isHidden = !showsTimeLabels
            durationLabel.isHidden = !showsTimeLabels
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.78).cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        for button in [previousButton, playButton, nextButton] {
            button.isBordered = false
            button.contentTintColor = .white
            addSubview(button)
        }
        previousButton.font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        playButton.font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        nextButton.font = NSFont.systemFont(ofSize: 28, weight: .semibold)

        slider.isContinuous = true

        for label in [currentLabel, durationLabel] {
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
            label.backgroundColor = .clear
            label.drawsBackground = false
        }
        currentLabel.alignment = .left
        durationLabel.alignment = .right

        addSubview(slider)
        addSubview(currentLabel)
        addSubview(durationLabel)
        applyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14
        let buttonSize: CGFloat = 44
        let centerX = floor((bounds.width - buttonSize) / 2)
        playButton.frame = NSRect(x: centerX, y: 4, width: buttonSize, height: buttonSize)
        previousButton.frame = NSRect(x: centerX - 52, y: 4, width: buttonSize, height: buttonSize)
        nextButton.frame = NSRect(x: centerX + 52, y: 4, width: buttonSize, height: buttonSize)
        let labelY: CGFloat = bounds.height - 30
        let labelW: CGFloat = 72
        currentLabel.frame = NSRect(x: pad, y: labelY, width: labelW, height: 22)
        durationLabel.frame = NSRect(x: bounds.width - pad - labelW, y: labelY, width: labelW, height: 22)
        if showsTimeLabels {
            slider.frame = NSRect(x: pad + labelW + 10, y: labelY - 2, width: max(80, bounds.width - (pad + labelW + 10) * 2), height: 24)
        } else {
            slider.frame = NSRect(x: pad + 70, y: labelY - 2, width: max(80, bounds.width - (pad + 70) * 2), height: 24)
        }
    }

    func setTime(current: String, duration: String) {
        currentLabel.stringValue = current
        durationLabel.stringValue = duration
    }

    func setPlaying(_ playing: Bool) {
        playButton.title = playing ? "⏸" : "▶"
    }

    private func applyTheme() {
        let color: NSColor = showsBackground ? NSColor(calibratedWhite: 0.92, alpha: 1) : .labelColor
        for button in [previousButton, playButton, nextButton] {
            button.contentTintColor = color
        }
        currentLabel.textColor = color
        durationLabel.textColor = color
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
    private let clearStateButton = NSButton(title: "清理本组", target: nil, action: nil)
    private let syncTimeline = TimelineControl()
    private let videoATimeline = TimelineControl()
    private let videoBTimeline = TimelineControl()
    private var timeSlider: ContinuousSeekSlider { syncTimeline.slider }
    private var videoASlider: ContinuousSeekSlider { videoATimeline.slider }
    private var videoBSlider: ContinuousSeekSlider { videoBTimeline.slider }

    private var syncState = SyncState()
    private var currentPair: VideoPairIdentity?
    private var normalizedOffsetPair: VideoPairIdentity?
    private var disableSubtitlesMenuItem: NSMenuItem?
    private let recentMenu = NSMenu(title: "最近视频组")
    private var statusRefreshPending = false
    private var isTrackingTimeSlider = false
    private var isTrackingVideoASlider = false
    private var isTrackingVideoBSlider = false
    private var syncBaseTime: Double = 0
    private var syncLoopRange: ClosedRange<Double>?
    private var isSynchronizedPlaying = false
    private var synchronizedPlaybackToken = 0
    private var synchronizedDebugFrameCount = 0
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
        window.onScrollWheelInContent = { [weak self] event in
            self?.handleScrollWheel(event) ?? false
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
            self?.refreshStatus()
        }
        canvas.onSelectionChanged = { [weak self] slot in
            guard self?.selectedSlot != slot else { return }
            self?.selectedSlot = slot
        }
        syncTimeline.showsBackground = false
        syncTimeline.showsTimeLabels = false

        let controls = [
            layoutControl,
            syncTimeline,
            videoATimeline,
            videoBTimeline
        ] as [NSView]
        content.addSubview(canvas)
        controls.forEach(content.addSubview)

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
                       clearStateButton] {
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
        clearStateButton.action = #selector(clearCurrentState)
        syncTimeline.playButton.target = self
        syncTimeline.playButton.action = #selector(toggleSyncTimelinePlayback)
        syncTimeline.previousButton.target = self
        syncTimeline.previousButton.action = #selector(syncTimelinePreviousFrame)
        syncTimeline.nextButton.target = self
        syncTimeline.nextButton.action = #selector(syncTimelineNextFrame)
        videoATimeline.playButton.target = self
        videoATimeline.playButton.action = #selector(toggleVideoATimelinePlayback)
        videoATimeline.previousButton.target = self
        videoATimeline.previousButton.action = #selector(videoATimelinePreviousFrame)
        videoATimeline.nextButton.target = self
        videoATimeline.nextButton.action = #selector(videoATimelineNextFrame)
        videoBTimeline.playButton.target = self
        videoBTimeline.playButton.action = #selector(toggleVideoBTimelinePlayback)
        videoBTimeline.previousButton.target = self
        videoBTimeline.previousButton.action = #selector(videoBTimelinePreviousFrame)
        videoBTimeline.nextButton.target = self
        videoBTimeline.nextButton.action = #selector(videoBTimelineNextFrame)

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
        timeSlider.onLoopRangeSelected = { [weak self] range in
            self?.setSyncLoopRange(fromFractions: range)
        }
        timeSlider.onLoopRangeCancelled = { [weak self] in
            self?.clearSyncLoopRange()
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
    }

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关闭 VideoCompare", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "w")
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
        let gap: CGFloat = 8

        func place(_ view: NSView, x: CGFloat, y: CGFloat, width: CGFloat) {
            view.frame = NSRect(x: x, y: y, width: width, height: rowH)
        }

        let layoutWidth: CGFloat = 300
        let groupX = max(pad, floor((w - layoutWidth) / 2))
        let toolbarY = max(pad, h - pad - rowH)
        place(layoutControl, x: groupX, y: toolbarY, width: layoutWidth)

        syncTimeline.frame = NSRect(x: pad, y: pad, width: max(100, w - pad * 2), height: 78)

        let canvasY = syncTimeline.frame.maxY + gap
        let canvasTop = toolbarY - gap
        canvas.frame = NSRect(x: 0, y: canvasY, width: w, height: max(100, canvasTop - canvasY))
        canvas.layoutSubtreeIfNeeded()
        let hideIndependentTimelines = canvas.layoutMode != .sideBySideHorizontal
        layoutVideoTimeline(videoATimeline, over: canvas.containerA.frame, hidden: hideIndependentTimelines || canvas.containerA.isHidden, in: content)
        layoutVideoTimeline(videoBTimeline, over: canvas.containerB.frame, hidden: hideIndependentTimelines || canvas.containerB.isHidden, in: content)
    }

    private func layoutVideoTimeline(_ timeline: TimelineControl, over canvasRect: NSRect, hidden: Bool, in content: NSView) {
        guard !hidden else {
            timeline.isHidden = true
            return
        }
        let rect = canvas.convert(canvasRect, to: content)
        guard !rect.isEmpty, rect.width > 120, rect.height > 90 else {
            timeline.isHidden = true
            return
        }
        timeline.isHidden = false
        let pad: CGFloat = 14
        let width = min(rect.width - pad * 2, max(260, rect.width * 0.72))
        timeline.frame = NSRect(
            x: rect.midX - width / 2,
            y: rect.minY + pad,
            width: width,
            height: 72
        )
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
        syncBaseTime = 0
        normalizedOffsetPair = nil
        clearSyncLoopRange()
        debugTimelineState("load.reset slot=\(slot.rawValue)")
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
        Diagnostics.log("pair.state.loaded key=\(pair.key) offsetA=\(syncState.offsetFramesA) offsetB=\(syncState.offsetFramesB) transformA=(\(syncState.transformA.panX),\(syncState.transformA.panY),\(syncState.transformA.zoom)) transformB=(\(syncState.transformB.panX),\(syncState.transformB.panY),\(syncState.transformB.zoom))")
        debugTimelineState("pair.loaded")
        normalizeLoadedOffsetsIfReady()
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
        applyLayout(layout)
    }

    private func applyLayout(_ layout: CompareLayout) {
        layoutControl.selectedSegment = layout.rawValue
        canvas.layoutMode = layout
        canvas.needsDisplay = true
        layoutContent()
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

    @objc private func toggleSyncTimelinePlayback() {
        toggleSynchronizedPlayback()
    }

    @objc private func syncTimelinePreviousFrame() {
        stepSyncFrames(-1)
    }

    @objc private func syncTimelineNextFrame() {
        stepSyncFrames(1)
    }

    @objc private func toggleVideoATimelinePlayback() {
        if canvas.allowsAlignmentAdjustment {
            toggleSynchronizedPlayback()
        } else {
            toggleA()
        }
    }

    @objc private func videoATimelinePreviousFrame() {
        stepIndividualFrame(slot: .a, delta: -1)
    }

    @objc private func videoATimelineNextFrame() {
        stepIndividualFrame(slot: .a, delta: 1)
    }

    @objc private func toggleVideoBTimelinePlayback() {
        if canvas.allowsAlignmentAdjustment {
            toggleSynchronizedPlayback()
        } else {
            toggleB()
        }
    }

    @objc private func videoBTimelinePreviousFrame() {
        stepIndividualFrame(slot: .b, delta: -1)
    }

    @objc private func videoBTimelineNextFrame() {
        stepIndividualFrame(slot: .b, delta: 1)
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
        let base = baseTimeAnchoredOpposite(of: slot)
        switch slot {
        case .a: syncState.offsetFramesA += delta
        case .b: syncState.offsetFramesB += delta
        }
        let baseShift = normalizeSyncOffsets(adjustBaseTime: false)
        seekToBaseTime(base + baseShift)
        saveState()
        refreshStatus()
    }

    private func stepBySelection(_ delta: Int) {
        if let selectedSlot {
            stepIndividualFrame(slot: selectedSlot, delta: delta)
        } else {
            stepSyncFrames(delta)
        }
    }

    private func stepSyncFrames(_ delta: Int) {
        pauseBothIfNeeded()
        var callbacks = 0
        func done() {
            callbacks += 1
            guard callbacks == 2 else { return }
            refreshStatus()
        }
        playerA.stepFrame(direction: delta) { _ in done() }
        playerB.stepFrame(direction: delta) { _ in done() }
    }

    private func stepIndividualFrame(slot: VideoSlot, delta: Int) {
        pauseBothIfNeeded()
        let player = slot == .a ? playerA! : playerB!
        player.stepFrame(direction: delta) { newTime in
            guard let newTime else { return }
            self.updateOffsetAfterIndividualSeek(slot: slot, targetTime: newTime)
            self.saveState()
            self.refreshStatus()
        }
    }

    private func currentBaseTime() -> Double {
        syncBaseTime
    }

    private func seekPlayersToCurrentBase() {
        seekToBaseTime(currentBaseTime())
    }

    private func seekToBaseTime(_ base: Double, exact: Bool = true) {
        let alignedBase = frameAlignedBaseTime(base)
        syncBaseTime = alignedBase
        let aTime = alignedBase + seconds(forFrames: syncState.offsetFramesA, fps: playerA.fps)
        let bTime = alignedBase + seconds(forFrames: syncState.offsetFramesB, fps: playerB.fps)
        Diagnostics.log("sync.seekToBase requested=\(debugTime(base)) aligned=\(debugTime(alignedBase)) exact=\(exact) aTarget=\(debugTime(aTime)) bTarget=\(debugTime(bTime))")
        display(playerA, at: aTime, exact: exact)
        display(playerB, at: bTime, exact: exact)
        debugTimelineState("sync.seekToBase.issued")
    }

    private func baseTimeAnchoredOpposite(of slot: VideoSlot) -> Double {
        switch slot {
        case .a:
            if playerB.fileURL != nil {
                return max(0, playerB.timePosition - seconds(forFrames: syncState.offsetFramesB, fps: playerB.fps))
            }
        case .b:
            if playerA.fileURL != nil {
                return max(0, playerA.timePosition - seconds(forFrames: syncState.offsetFramesA, fps: playerA.fps))
            }
        }
        return currentBaseTime()
    }

    private func frameAlignedBaseTime(_ base: Double) -> Double {
        let fps = max(1, max(playerA.fps, playerB.fps))
        return frameAlignedTime(base, fps: fps)
    }

    private func frameAlignedTime(_ seconds: Double, fps: Double) -> Double {
        let fps = max(1, fps)
        return max(0, round(seconds * fps) / fps)
    }

    private func display(_ player: NativeVideoPlayer, at seconds: Double, exact: Bool = true) {
        let hasContent = seconds >= 0 && (player.duration <= 0 || seconds <= player.duration)
        Diagnostics.log("display slot=\(player.slot.rawValue) target=\(debugTime(seconds)) exact=\(exact) hasContent=\(hasContent) duration=\(debugTime(player.duration))")
        player.setVideoVisible(hasContent)
        if hasContent {
            player.seekAbsolute(seconds, exact: exact)
        }
    }

    private func seconds(forFrames frames: Int, fps: Double) -> Double {
        Double(frames) / max(1, fps)
    }

    @objc private func sliderChanged() {
        Diagnostics.log("slider.sync.changed value=\(timeSlider.doubleValue) tracking=\(isTrackingTimeSlider)")
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
        let base = frameAlignedBaseTime(timeSlider.doubleValue * duration)
        Diagnostics.log("slider.sync.seek value=\(timeSlider.doubleValue) duration=\(debugTime(duration)) exactArg=\(exact) base=\(debugTime(base))")
        _ = exact
        seekToBaseTime(base, exact: true)
    }

    private func setSyncLoopRange(fromFractions range: ClosedRange<Double>) {
        let duration = max(playerA.duration, playerB.duration)
        guard duration > 0 else {
            clearSyncLoopRange()
            return
        }
        let frameInterval = 1.0 / max(1, max(playerA.fps, playerB.fps))
        let lower = frameAlignedBaseTime(range.lowerBound * duration)
        var upper = frameAlignedBaseTime(range.upperBound * duration)
        if upper <= lower {
            upper = min(duration, lower + frameInterval)
        }
        syncLoopRange = lower...upper
        timeSlider.loopRange = (lower / duration)...(upper / duration)
        Diagnostics.log("loop.set fractions=(\(range.lowerBound),\(range.upperBound)) seconds=\(debugRange(syncLoopRange))")
        debugTimelineState("loop.set")
    }

    private func clearSyncLoopRange() {
        Diagnostics.log("loop.clear previous=\(debugRange(syncLoopRange))")
        syncLoopRange = nil
        timeSlider.loopRange = nil
        debugTimelineState("loop.clear")
    }

    private func seekIndividualVideo(slot: VideoSlot, exact: Bool) {
        stopSynchronizedBarrierPlayback()
        let player = slot == .a ? playerA! : playerB!
        let slider = slot == .a ? videoASlider : videoBSlider
        guard player.duration > 0 else { return }
        if !player.isPaused {
            player.setPause(true)
        }
        let targetTime = frameAlignedTime(slider.doubleValue * player.duration, fps: player.fps)
        updateOffsetAfterIndividualSeek(slot: slot, targetTime: targetTime)
        player.setVideoVisible(targetTime >= 0 && targetTime <= player.duration)
        _ = exact
        player.seekAbsolute(targetTime, exact: true)
        refreshStatus()
    }

    private func updateOffsetAfterIndividualSeek(slot: VideoSlot, targetTime: Double) {
        switch slot {
        case .a:
            let base = playerB.fileURL != nil
                ? playerB.timePosition - seconds(forFrames: syncState.offsetFramesB, fps: playerB.fps)
                : 0
            syncState.offsetFramesA = Int(round((targetTime - base) * max(1, playerA.fps)))
            syncBaseTime = base + normalizeSyncOffsets(adjustBaseTime: false)
        case .b:
            let base = playerA.fileURL != nil
                ? playerA.timePosition - seconds(forFrames: syncState.offsetFramesA, fps: playerA.fps)
                : 0
            syncState.offsetFramesB = Int(round((targetTime - base) * max(1, playerB.fps)))
            syncBaseTime = base + normalizeSyncOffsets(adjustBaseTime: false)
        }
    }

    private func normalizeLoadedOffsetsIfReady() {
        guard let pair = currentPair,
              normalizedOffsetPair != pair,
              playerA.fileURL != nil,
              playerB.fileURL != nil,
              playerA.duration > 0,
              playerB.duration > 0 else { return }
        normalizedOffsetPair = pair
        if normalizeSyncOffsets(adjustBaseTime: false) != 0 {
            PersistenceStore.shared.saveState(syncState, for: pair)
        }
        debugTimelineState("pair.offsets.normalized")
    }

    @discardableResult
    private func normalizeSyncOffsets(adjustBaseTime: Bool) -> Double {
        guard playerA.fileURL != nil, playerB.fileURL != nil else { return 0 }
        let fpsA = max(1, playerA.fps)
        let fpsB = max(1, playerB.fps)
        let offsetASeconds = seconds(forFrames: syncState.offsetFramesA, fps: fpsA)
        let offsetBSeconds = seconds(forFrames: syncState.offsetFramesB, fps: fpsB)
        let common = min(offsetASeconds, offsetBSeconds)
        guard abs(common) >= 0.5 / max(fpsA, fpsB) else { return 0 }
        let oldA = syncState.offsetFramesA
        let oldB = syncState.offsetFramesB
        syncState.offsetFramesA = Int(round((offsetASeconds - common) * fpsA))
        syncState.offsetFramesB = Int(round((offsetBSeconds - common) * fpsB))
        if adjustBaseTime {
            syncBaseTime += common
        }
        Diagnostics.log("offset.normalize common=\(debugTime(common)) oldA=\(oldA) oldB=\(oldB) newA=\(syncState.offsetFramesA) newB=\(syncState.offsetFramesB) adjustBase=\(adjustBaseTime) syncBase=\(debugTime(syncBaseTime))")
        return common
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
        normalizeLoadedOffsetsIfReady()
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
        syncTimeline.setTime(current: formatShortTime(base), duration: formatShortTime(duration))
        videoATimeline.setTime(current: formatShortTime(playerA.timePosition), duration: formatShortTime(playerA.duration))
        videoBTimeline.setTime(current: formatShortTime(playerB.timePosition), duration: formatShortTime(playerB.duration))
        let synchronizedPlaying = isSynchronizedPlaying || (!playerA.isPaused && !playerB.isPaused)
        syncTimeline.setPlaying(synchronizedPlaying)
        videoATimeline.setPlaying(canvas.allowsAlignmentAdjustment ? synchronizedPlaying : !playerA.isPaused)
        videoBTimeline.setPlaying(canvas.allowsAlignmentAdjustment ? synchronizedPlaying : !playerB.isPaused)
        updateEndVisibility()
    }

    private func formatShortTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func debugTime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "nil" }
        return String(format: "%.6f", seconds)
    }

    private func debugRange(_ range: ClosedRange<Double>?) -> String {
        guard let range else { return "nil" }
        return "\(debugTime(range.lowerBound))...\(debugTime(range.upperBound))"
    }

    private func debugTimelineState(_ event: String) {
        let duration = max(playerA?.duration ?? 0, playerB?.duration ?? 0)
        Diagnostics.log(
            "state.\(event) syncBase=\(debugTime(syncBaseTime)) loop=\(debugRange(syncLoopRange)) slider=\(timeSlider.doubleValue) duration=\(debugTime(duration)) " +
            "A(time=\(debugTime(playerA?.timePosition)),dur=\(debugTime(playerA?.duration)),fps=\(debugTime(playerA?.fps)),paused=\(playerA?.isPaused.description ?? "nil")) " +
            "B(time=\(debugTime(playerB?.timePosition)),dur=\(debugTime(playerB?.duration)),fps=\(debugTime(playerB?.fps)),paused=\(playerB?.isPaused.description ?? "nil")) " +
            "offsetA=\(syncState.offsetFramesA) offsetB=\(syncState.offsetFramesB) syncPlaying=\(isSynchronizedPlaying)"
        )
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
        synchronizedDebugFrameCount = 0
        let token = synchronizedPlaybackToken
        playerA.setSynchronizedPlaybackActive(true)
        playerB.setSynchronizedPlaybackActive(true)
        Diagnostics.log("sync.play.start token=\(token) loop=\(debugRange(syncLoopRange))")
        debugTimelineState("sync.play.start")
        if let loopRange = syncLoopRange {
            let base = currentBaseTime()
            if base < loopRange.lowerBound || base > loopRange.upperBound {
                Diagnostics.log("sync.play.loopClamp token=\(token) base=\(debugTime(base)) loop=\(debugRange(syncLoopRange))")
                seekToBaseTime(loopRange.lowerBound, exact: true)
            }
        }
        scheduleSynchronizedFrame(token: token)
    }

    private func stopSynchronizedBarrierPlayback() {
        guard isSynchronizedPlaying else { return }
        isSynchronizedPlaying = false
        synchronizedPlaybackToken += 1
        Diagnostics.log("sync.play.stop token=\(synchronizedPlaybackToken)")
        debugTimelineState("sync.play.stop")
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

            if let loopRange = self.syncLoopRange,
               let nextBase = self.baseTime(frameA: frameA, frameB: frameB),
               nextBase > loopRange.upperBound + (0.5 / max(1, max(self.playerA.fps, self.playerB.fps))) {
                Diagnostics.log("sync.loop.wrap token=\(token) nextBase=\(self.debugTime(nextBase)) loop=\(self.debugRange(self.syncLoopRange)) frameA=\(self.debugTime(frameA?.pts)) frameB=\(self.debugTime(frameB?.pts))")
                self.seekToBaseTime(loopRange.lowerBound, exact: true)
                DispatchQueue.main.async {
                    self.scheduleSynchronizedFrame(token: token)
                }
                return
            }

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

            if let nextBase = self.baseTime(frameA: frameA, frameB: frameB) {
                self.syncBaseTime = nextBase
            }
            self.synchronizedDebugFrameCount += 1
            if self.synchronizedDebugFrameCount <= 12 || self.synchronizedDebugFrameCount % 60 == 0 {
                Diagnostics.log("sync.play.frame token=\(token) count=\(self.synchronizedDebugFrameCount) nextBase=\(self.debugTime(self.syncBaseTime)) frameA=\(self.debugTime(frameA?.pts)) frameB=\(self.debugTime(frameB?.pts)) loop=\(self.debugRange(self.syncLoopRange))")
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

    private func baseTime(frameA: NativeVideoFrame?, frameB: NativeVideoFrame?) -> Double? {
        if let frameA {
            return max(0, frameA.pts - seconds(forFrames: syncState.offsetFramesA, fps: playerA.fps))
        }
        if let frameB {
            return max(0, frameB.pts - seconds(forFrames: syncState.offsetFramesB, fps: playerB.fps))
        }
        return nil
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
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "q":
                applyLayout(.sideBySideHorizontal)
                return true
            case "w":
                applyLayout(.overlapToggle)
                return true
            case "e":
                applyLayout(.overlapWipe)
                return true
            case "1":
                selectedSlot = .a
                return true
            case "2":
                selectedSlot = .b
                return true
            default:
                break
            }
        }

        switch event.keyCode {
        case 53:
            selectedSlot = nil
            canvas.clearSelection()
            return true
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

    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              canvas.allowsAlignmentAdjustment,
              let content = window?.contentView else { return false }
        let point = content.convert(event.locationInWindow, from: nil)
        guard canvas.frame.contains(point) else { return false }
        let canvasPoint = canvas.convert(point, from: content)
        let slot = selectedSlot ?? canvas.selectSlot(at: canvasPoint)
        guard let slot else { return false }
        selectedSlot = slot
        let rawDelta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        let dz = max(-0.25, min(0.25, Double(rawDelta) * 0.01))
        adjustTransform(slot: slot, dx: 0, dy: 0, dz: dz)
        saveState()
        return true
    }

    private func togglePlaybackBySelection() {
        if canvas.allowsAlignmentAdjustment {
            toggleSynchronizedPlayback()
            return
        }
        switch selectedSlot {
        case .a:
            toggleSelectedPlayback(selected: playerA, other: playerB)
        case .b:
            toggleSelectedPlayback(selected: playerB, other: playerA)
        case nil:
            toggleSynchronizedPlayback()
        }
    }

    private func toggleSelectedPlayback(selected: NativeVideoPlayer, other: NativeVideoPlayer) {
        if isSynchronizedPlaying {
            stopSynchronizedBarrierPlayback()
            selected.setPause(true)
            other.setPause(false)
        } else {
            stopSynchronizedBarrierPlayback()
            selected.togglePause()
        }
    }

    private func handleMouseDownInContent(_ point: NSPoint) {
        guard let content = window?.contentView else { return }
        if canvas.frame.contains(point) {
            let canvasPoint = canvas.convert(point, from: content)
            selectedSlot = canvas.selectSlot(at: canvasPoint)
        } else if [
            layoutControl,
            syncTimeline,
            videoATimeline,
            videoBTimeline
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
