import AppKit
import CoreVideo
import Foundation
import QuartzCore
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

final class ShortcutHelpView: NSView {
    private struct HelpRow {
        let key: String
        let detail: String
    }

    private struct HelpSection {
        let title: String
        let rows: [HelpRow]
    }

    private let leftSections: [HelpSection] = [
        HelpSection(title: "播放", rows: [
            HelpRow(key: "Space", detail: "播放或暂停"),
            HelpRow(key: "← / →", detail: "逐帧移动")
        ]),
        HelpSection(title: "选择与布局", rows: [
            HelpRow(key: "1 / 2", detail: "选择视频 A / B"),
            HelpRow(key: "Esc", detail: "取消当前选中"),
            HelpRow(key: "Cmd+1 / Cmd+2", detail: "切换对比模式"),
            HelpRow(key: "Tab", detail: "切换遮罩边界")
        ])
    ]

    private let rightSections: [HelpSection] = [
        HelpSection(title: "画面辅助", rows: [
            HelpRow(key: "F", detail: "显示当前帧序号"),
            HelpRow(key: "O", detail: "按住查看原始画面"),
            HelpRow(key: "Opt+Cmd+C", detail: "打开调整面板"),
            HelpRow(key: "Drag", detail: "同步拖动画面"),
            HelpRow(key: "Cmd+Drag", detail: "单独拖动画面"),
            HelpRow(key: "Scroll", detail: "同步缩放画面"),
            HelpRow(key: "Cmd+Scroll", detail: "单独缩放画面"),
            HelpRow(key: "Ctrl+Drag", detail: "框选 ROI 自动对齐")
        ]),
        HelpSection(title: "文件与片段", rows: [
            HelpRow(key: "Cmd+B", detail: "展开文件面板"),
            HelpRow(key: "Cmd+Drag Bar", detail: "创建循环片段"),
            HelpRow(key: "RightClick Bar", detail: "取消循环片段")
        ])
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let columnGap: CGFloat = 12
        let columnWidth = floor((bounds.width - columnGap) / 2)
        drawSections(leftSections, x: 0, width: columnWidth)
        drawSections(rightSections, x: columnWidth + columnGap, width: columnWidth)
    }

    private func drawSections(_ sections: [HelpSection], x: CGFloat, width: CGFloat) {
        var y: CGFloat = 0
        for section in sections {
            let height = sectionHeight(section)
            drawSection(section, in: NSRect(x: x, y: y, width: width, height: height))
            y += height + 10
        }
    }

    private func sectionHeight(_ section: HelpSection) -> CGFloat {
        31 + CGFloat(section.rows.count) * 22
    }

    private func drawSection(_ section: HelpSection, in rect: NSRect) {
        NSColor(calibratedWhite: 1, alpha: 1).setFill()
        let card = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        card.fill()
        NSColor(calibratedWhite: 0.76, alpha: 1).setStroke()
        card.lineWidth = 1
        card.stroke()

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.alignment = .center
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.28, alpha: 1),
            .paragraphStyle: titleParagraph
        ]
        (section.title as NSString).draw(
            in: NSRect(x: rect.minX + 10, y: rect.minY + 8, width: rect.width - 20, height: 14),
            withAttributes: titleAttributes
        )

        var rowY = rect.minY + 29
        for row in section.rows {
            drawRow(row, x: rect.minX + 10, y: rowY, width: rect.width - 20)
            rowY += 22
        }
    }

    private func drawRow(_ row: HelpRow, x: CGFloat, y: CGFloat, width: CGFloat) {
        let keyColumnWidth: CGFloat = 104
        let keyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1)
        ]
        let detailParagraph = NSMutableParagraphStyle()
        detailParagraph.lineBreakMode = .byTruncatingTail
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.18, alpha: 1),
            .paragraphStyle: detailParagraph
        ]

        let keySize = (row.key as NSString).size(withAttributes: keyAttributes)
        let keyWidth = min(keyColumnWidth, max(32, ceil(keySize.width) + 14))
        let keyRect = NSRect(
            x: x + keyColumnWidth - keyWidth,
            y: y + 1,
            width: keyWidth,
            height: 17
        )
        NSColor(calibratedWhite: 0.90, alpha: 1).setFill()
        let keyPath = NSBezierPath(roundedRect: keyRect, xRadius: 4, yRadius: 4)
        keyPath.fill()
        NSColor(calibratedWhite: 0.68, alpha: 1).setStroke()
        keyPath.lineWidth = 1
        keyPath.stroke()
        (row.key as NSString).draw(
            in: keyRect.insetBy(dx: 6, dy: 2),
            withAttributes: keyAttributes
        )

        let detailX = x + keyColumnWidth + 10
        (row.detail as NSString).draw(
            in: NSRect(x: detailX, y: y + 1, width: max(20, width - (detailX - x)), height: 18),
            withAttributes: detailAttributes
        )
    }
}

final class MainWindowController: NSWindowController {
    private let canvas = VideoCanvasView()
    private var playerA: NativeVideoPlayer!
    private var playerB: NativeVideoPlayer!

    private let layoutControl = NSSegmentedControl(labels: CompareLayout.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let targetControl = NSSegmentedControl(labels: ["调 A", "调 B"], trackingMode: .selectOne, target: nil, action: nil)
    private let syncTimeline = TimelineControl()
    private let videoATimeline = TimelineControl()
    private let videoBTimeline = TimelineControl()
    private let fileTreeToggleButton = NSButton()
    private let helpButton = NSButton(title: "?", target: nil, action: nil)
    private let mediaFileTrees = MediaFileTreesView(defaultRoot: FileManager.default.homeDirectoryForCurrentUser)
    private let shortcutHelpPanel = NSView()
    private let shortcutHelpView = ShortcutHelpView()
    private let transientMessageLabel = NSTextField(labelWithString: "")
    private var timeSlider: ContinuousSeekSlider { syncTimeline.slider }
    private var videoASlider: ContinuousSeekSlider { videoATimeline.slider }
    private var videoBSlider: ContinuousSeekSlider { videoBTimeline.slider }

    private var syncState = SyncState()
    private var currentPair: VideoPairIdentity?
    private var normalizedOffsetPair: VideoPairIdentity?
    private var disableSubtitlesMenuItem: NSMenuItem?
    private let recentMenu = NSMenu(title: "最近视频组")
    private var statusRefreshPending = false
    private let syncScrub = ScrubSeekCoordinator()
    private let videoAScrub = ScrubSeekCoordinator()
    private let videoBScrub = ScrubSeekCoordinator()
    private var isTrackingTimeSlider = false
    private var isTrackingVideoASlider = false
    private var isTrackingVideoBSlider = false
    private var syncScrubPresentationID = 0
    private var pendingSyncScrubPresentation: SyncScrubPresentation?
    private var lastTimelineStaticState = (a: false, b: false)
    private var syncBaseTime: Double = 0
    private var syncLoopRange: ClosedRange<Double>?
    private var loopSeekInProgress = false
    private var loopSeekGeneration = 0
    private var loopPreviewGeneration = 0
    private var loopPreviewPlaybackGeneration = 0
    private var loopPreviewFramesA: [NativeVideoFrame] = []
    private var loopPreviewFramesB: [NativeVideoFrame] = []
    private var isSynchronizedPlaying = false
    private var fileTreesExpanded = true
    private var fileTreeAnimationTimer: Timer?
    private var synchronizedPlaybackToken = 0
    private var synchronizedDebugFrameCount = 0
    private var colorAdjustmentA = ColorAdjustmentState()
    private var colorAdjustmentB = ColorAdjustmentState()
    private var rawTemperatureTintTrackingSlots: Set<VideoSlot> = []
    private var colorHistogramA = ColorHistogram.empty
    private var colorHistogramB = ColorHistogram.empty
    private var lastPixelBufferA: CVPixelBuffer?
    private var lastPixelBufferB: CVPixelBuffer?
    private var lastFrameTimeA: Double?
    private var lastFrameTimeB: Double?
    private var filePanelRootA: URL?
    private var filePanelRootB: URL?
    private var filePanelDisplayA: URL?
    private var filePanelDisplayB: URL?
    private var colorAdjustmentPanel: ColorAdjustmentPanelController?
    private var originalBypassSlot: VideoSlot?
    private var lastHistogramUpdate: TimeInterval = 0
    private var colorHistogramGeneration = 0
    private let colorHistogramWorker = ColorHistogramWorker()
    private var showsFrameNumbers = false
    private var undoStack: [PreviewEditState] = []
    private var redoStack: [PreviewEditState] = []
    private var pendingUndoSnapshot: PreviewEditState?
    private var pendingUndoCommitTimer: Timer?
    private var isApplyingPreviewHistory = false
    private let roiAlignmentQueue = DispatchQueue(label: "VideoCompare.roiAlignment", qos: .userInitiated)
    private var roiAlignmentGeneration = 0
    private var isROIAlignmentRunning = false
    private var transientMessageGeneration = 0
    private var isWhiteBalanceSampling = false
    private var rawWhiteBalanceGeneration = 0
    private var rawWhiteBalanceIsSolving = false
    private var pendingRawWhiteBalanceRequest: RawWhiteBalancePickRequest?
    private var lastRawWhiteBalancePreview: (slot: VideoSlot, adjustment: ColorAdjustmentState)?
    private static let loopPreviewFrameCount = 8
    private static let loopSeekTimeout: TimeInterval = 1.5

    private struct RawWhiteBalancePickRequest {
        var generation: Int
        var slot: VideoSlot
        var canvasPoint: NSPoint
        var phase: WhiteBalancePickPhase
    }

    private var selectedSlot: VideoSlot? {
        didSet {
            canvas.selectedSlot = selectedSlot
            switch selectedSlot {
            case .a: targetControl.selectedSegment = 0
            case .b: targetControl.selectedSegment = 1
            case nil: targetControl.selectedSegment = -1
            }
            if originalBypassSlot != nil {
                originalBypassSlot = selectedSlot
                canvas.renderer.originalBypassSlot = selectedSlot
            }
            refreshColorAdjustmentPanel()
            scheduleStatusRefresh()
        }
    }

    private struct SyncScrubPresentation {
        let id: Int
        let expectA: Bool
        let expectB: Bool
        var frameA: (CVPixelBuffer, Double)?
        var frameB: (CVPixelBuffer, Double)?
    }

    private struct PreviewEditState: Equatable {
        var transformA: TransformState
        var transformB: TransformState
        var colorAdjustmentA: ColorAdjustmentState
        var colorAdjustmentB: ColorAdjustmentState
    }

    private struct ROIAlignmentSnapshot: @unchecked Sendable {
        let generation: Int
        let sourceSlot: VideoSlot
        let sourcePixelBuffer: CVPixelBuffer
        let targetPixelBuffer: CVPixelBuffer
        let sourceFrameTime: Double?
        let targetFrameTime: Double?
        let sourceTransform: TransformState
        let targetTransform: TransformState
        let sourceCanvasRect: CGRect
        let contentRect: CGRect
    }

    private struct GrayImage: Sendable {
        let width: Int
        let height: Int
        let pixels: [Float]

        subscript(x: Int, y: Int) -> Float {
            pixels[y * width + x]
        }
    }

    private struct TemplateMatchResult: Sendable {
        let targetRect: CGRect
        let score: Double
        let scale: Double
    }

    private struct ROIAlignmentResult: Sendable {
        let sourceRect: CGRect
        let targetRect: CGRect
        let score: Double
        let scale: Double
    }

    private struct ColorHistogramResult {
        let slot: VideoSlot
        let generation: Int
        let histogram: ColorHistogram
    }

    private final class ColorHistogramWorker {
        private final class PixelBufferBox: @unchecked Sendable {
            let pixelBuffer: CVPixelBuffer

            init(_ pixelBuffer: CVPixelBuffer) {
                self.pixelBuffer = pixelBuffer
            }
        }

        private final class CompletionBox: @unchecked Sendable {
            let completion: (ColorHistogramResult) -> Void

            init(_ completion: @escaping (ColorHistogramResult) -> Void) {
                self.completion = completion
            }
        }

        private let queue = DispatchQueue(label: "VideoCompare.colorHistogram", qos: .utility)

        func sample(
            slot: VideoSlot,
            generation: Int,
            pixelBuffer: CVPixelBuffer,
            adjustment: ColorAdjustmentState,
            completion: @escaping (ColorHistogramResult) -> Void
        ) {
            let box = PixelBufferBox(pixelBuffer)
            let completionBox = CompletionBox(completion)
            queue.async {
                let histogram = MainWindowController.sampleColorHistogram(pixelBuffer: box.pixelBuffer, adjustment: adjustment)
                DispatchQueue.main.async {
                    completionBox.completion(ColorHistogramResult(slot: slot, generation: generation, histogram: histogram))
                }
            }
        }
    }

    private enum DroppedItem {
        case media(URL)
        case directory(URL)
    }

    private static let filePanelRootADefaultsKey = "mediaFileTree.root.a.v1"
    private static let filePanelRootBDefaultsKey = "mediaFileTree.root.b.v1"

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
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.contentView = content
        window.delegate = self
        window.onKeyPressed = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        window.onKeyReleased = { [weak self] event in
            self?.handleKeyUp(event) ?? false
        }
        window.onMouseDownInContent = { [weak self] point in
            self?.handleMouseDownInContent(point)
        }
        window.onScrollWheelInContent = { [weak self] event in
            self?.handleScrollWheel(event) ?? false
        }
        window.onUndo = { [weak self] in
            self?.undoPreviewEdit()
        }
        window.onRedo = { [weak self] in
            self?.redoPreviewEdit()
        }
        window.center()
        setup()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
    }

    private func configureScrubCoordinators() {
        syncScrub.onSeek = { [weak self] seconds, exact in
            guard let self else { return }
            self.pauseBothIfNeeded()
            self.beginSyncScrubPresentation(base: seconds)
            self.seekToBaseTime(seconds, exact: exact)
        }
        syncScrub.isDecoderIdle = { [weak self] in
            guard let self else { return true }
            return self.playerA.isSeekIdle && self.playerB.isSeekIdle
        }

        videoAScrub.onSeek = { [weak self] seconds, exact in
            self?.seekIndividualVideo(slot: .a, targetTime: seconds, exact: exact)
        }
        videoAScrub.isDecoderIdle = { [weak self] in
            self?.playerA.isSeekIdle ?? true
        }

        videoBScrub.onSeek = { [weak self] seconds, exact in
            self?.seekIndividualVideo(slot: .b, targetTime: seconds, exact: exact)
        }
        videoBScrub.isDecoderIdle = { [weak self] in
            self?.playerB.isSeekIdle ?? true
        }
    }

    private func recordSeekCompleted(exact: Bool, elapsed: TimeInterval) {
        guard exact else { return }
        syncScrub.recordExactSeekCost(elapsed)
        videoAScrub.recordExactSeekCost(elapsed)
        videoBScrub.recordExactSeekCost(elapsed)
    }

    private func beginSyncScrubPresentation(base: Double) {
        syncScrubPresentationID += 1
        let id = syncScrubPresentationID
        let aTime = base + seconds(forFrames: syncState.offsetFramesA, fps: playerA.fps)
        let bTime = base + seconds(forFrames: syncState.offsetFramesB, fps: playerB.fps)
        let expectA = visualDisplayTime(for: playerA, at: aTime) != nil
        let expectB = visualDisplayTime(for: playerB, at: bTime) != nil
        pendingSyncScrubPresentation = SyncScrubPresentation(id: id, expectA: expectA, expectB: expectB)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.flushSyncScrubPresentation(id: id, allowPartial: true)
        }
    }

    private func handleFrameDecoded(slot: VideoSlot, pixelBuffer: CVPixelBuffer, pts: Double) {
        switch slot {
        case .a:
            lastPixelBufferA = pixelBuffer
            lastFrameTimeA = pts
        case .b:
            lastPixelBufferB = pixelBuffer
            lastFrameTimeB = pts
        }
        updateHistogramIfNeeded(slot: slot, pixelBuffer: pixelBuffer)
        guard var pending = pendingSyncScrubPresentation else {
            canvas.renderer.setFrame(pixelBuffer, slot: slot)
            return
        }

        switch slot {
        case .a:
            guard pending.expectA else {
                canvas.renderer.setFrame(pixelBuffer, slot: slot)
                return
            }
            pending.frameA = (pixelBuffer, pts)
        case .b:
            guard pending.expectB else {
                canvas.renderer.setFrame(pixelBuffer, slot: slot)
                return
            }
            pending.frameB = (pixelBuffer, pts)
        }
        pendingSyncScrubPresentation = pending
        flushSyncScrubPresentation(id: pending.id, allowPartial: false)
    }

    private func flushSyncScrubPresentation(id: Int, allowPartial: Bool) {
        guard let pending = pendingSyncScrubPresentation, pending.id == id else { return }
        let readyA = !pending.expectA || pending.frameA != nil
        let readyB = !pending.expectB || pending.frameB != nil
        guard allowPartial || (readyA && readyB) else { return }

        if let frameA = pending.frameA {
            canvas.renderer.setFrame(frameA.0, slot: .a)
        }
        if let frameB = pending.frameB {
            canvas.renderer.setFrame(frameB.0, slot: .b)
        }
        pendingSyncScrubPresentation = nil
    }

    private func setup() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        playerA = NativeVideoPlayer(slot: .a)
        playerB = NativeVideoPlayer(slot: .b)
        playerA.onStatusChanged = { [weak self] in self?.scheduleStatusRefresh() }
        playerB.onStatusChanged = { [weak self] in self?.scheduleStatusRefresh() }
        playerA.onFrameDecoded = { [weak self] slot, pixelBuffer, pts in self?.handleFrameDecoded(slot: slot, pixelBuffer: pixelBuffer, pts: pts) }
        playerB.onFrameDecoded = { [weak self] slot, pixelBuffer, pts in self?.handleFrameDecoded(slot: slot, pixelBuffer: pixelBuffer, pts: pts) }
        playerA.onVisibilityChanged = { [weak self] slot, visible in self?.canvas.renderer.setVisible(visible, slot: slot) }
        playerB.onVisibilityChanged = { [weak self] slot, visible in self?.canvas.renderer.setVisible(visible, slot: slot) }
        playerA.onOpenFailed = { [weak self] slot, message in self?.showLoadError(slot: slot, message: message) }
        playerB.onOpenFailed = { [weak self] slot, message in self?.showLoadError(slot: slot, message: message) }
        playerA.onSeekCompleted = { [weak self] _, exact, elapsed in self?.recordSeekCompleted(exact: exact, elapsed: elapsed) }
        playerB.onSeekCompleted = { [weak self] _, exact, elapsed in self?.recordSeekCompleted(exact: exact, elapsed: elapsed) }
        restoreFilePanelRoots()
        configureScrubCoordinators()

        canvas.containerA.onFileDropped = { [weak self] slot, url in self?.handleDroppedItems([url], targetSlot: slot) }
        canvas.containerB.onFileDropped = { [weak self] slot, url in self?.handleDroppedItems([url], targetSlot: slot) }
        canvas.containerA.onFilesDropped = { [weak self] slot, urls in self?.handleDroppedItems(urls, targetSlot: slot) }
        canvas.containerB.onFilesDropped = { [weak self] slot, urls in self?.handleDroppedItems(urls, targetSlot: slot) }
        canvas.onPanDragged = { [weak self] slot, dx, dy in
            guard let self else { return }
            self.beginPreviewUndoGroup()
            if let slot {
                if self.selectedSlot != slot {
                    self.selectedSlot = slot
                }
                self.adjustTransform(slot: slot, dx: dx, dy: dy, dz: 0)
            } else {
                self.adjustTransform(slot: .a, dx: dx, dy: dy, dz: 0)
                self.adjustTransform(slot: .b, dx: dx, dy: dy, dz: 0)
            }
        }
        canvas.onZoomDragged = { [weak self] slot, dz in
            self?.beginPreviewUndoGroup()
            if self?.selectedSlot != slot {
                self?.selectedSlot = slot
            }
            self?.adjustTransform(slot: slot, dx: 0, dy: 0, dz: dz)
        }
        canvas.onAlignmentGestureEnded = { [weak self] in
            self?.commitPreviewUndoGroup()
            self?.refreshStatus()
        }
        canvas.onROIAlignmentRequested = { [weak self] slot, rect in
            self?.performROIAlignment(sourceSlot: slot, sourceCanvasRect: rect)
        }
        canvas.onWhiteBalanceSampleRequested = { [weak self] slot, point, phase in
            self?.handleWhiteBalancePick(slot: slot, canvasPoint: point, phase: phase)
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
        mediaFileTrees.setExpanded(fileTreesExpanded)
        mediaFileTrees.treeA.onFileOpened = { [weak self] slot, url in self?.load(url: url, slot: slot) }
        mediaFileTrees.treeB.onFileOpened = { [weak self] slot, url in self?.load(url: url, slot: slot) }
        mediaFileTrees.treeA.onLocationChanged = { [weak self] slot, root, display in
            self?.setFilePanelLocation(root: root, display: display, slot: slot)
        }
        mediaFileTrees.treeB.onLocationChanged = { [weak self] slot, root, display in
            self?.setFilePanelLocation(root: root, display: display, slot: slot)
        }
        mediaFileTrees.onHeightChanged = { [weak self] _ in
            self?.layoutContent(animated: false)
        }

        let controls = [
            layoutControl,
            fileTreeToggleButton,
            helpButton,
            mediaFileTrees,
            syncTimeline,
            videoATimeline,
            videoBTimeline,
            shortcutHelpPanel
        ] as [NSView]
        content.addSubview(canvas)
        controls.forEach(content.addSubview)
        content.addSubview(transientMessageLabel)

        setupMenu()
        configureControls()
        configureShortcutHelp()
        configureTransientMessage()
        refreshRecentMenu()
        layoutControl.selectedSegment = CompareLayout.sideBySideHorizontal.rawValue
        applyColorAdjustmentsToRenderer()
        selectedSlot = nil
        reloadMediaFileTrees()

    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        layoutContent()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(nil)
        }
    }

    func loadInitial(a: URL, b: URL) {
        Diagnostics.log("loadInitial")
        load(url: a, slot: .a)
        load(url: b, slot: .b)
    }

    func startSynchronizedPlayback() {
        syncPlay()
    }

    private func configureControls() {
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
            if tracking {
                self.syncScrub.beginTracking()
            }
            if !tracking {
                self.syncScrub.endTracking(seconds: self.currentSliderBaseTime(), fps: self.syncScrubFPS())
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
            if tracking {
                self.videoAScrub.beginTracking()
            }
            if !tracking {
                self.videoAScrub.endTracking(seconds: self.individualSliderTime(slot: .a), fps: self.playerA.fps)
                self.saveState()
            }
        }
        videoBSlider.target = self
        videoBSlider.action = #selector(videoBSliderChanged)
        videoBSlider.isContinuous = true
        videoBSlider.onTrackingChanged = { [weak self] tracking in
            guard let self else { return }
            self.isTrackingVideoBSlider = tracking
            if tracking {
                self.videoBScrub.beginTracking()
            }
            if !tracking {
                self.videoBScrub.endTracking(seconds: self.individualSliderTime(slot: .b), fps: self.playerB.fps)
                self.saveState()
            }
        }
    }

    private func configureShortcutHelp() {
        fileTreeToggleButton.target = self
        fileTreeToggleButton.action = #selector(toggleMediaFileTrees)
        fileTreeToggleButton.isBordered = false
        fileTreeToggleButton.imagePosition = .imageOnly
        fileTreeToggleButton.contentTintColor = .labelColor
        fileTreeToggleButton.toolTip = "展开/收起文件面板 (Cmd+B)"
        fileTreeToggleButton.wantsLayer = true
        fileTreeToggleButton.layer?.cornerRadius = 8
        fileTreeToggleButton.layer?.borderWidth = 1
        fileTreeToggleButton.layer?.borderColor = NSColor.separatorColor.cgColor
        fileTreeToggleButton.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        updateFileTreeToggleButton()

        helpButton.target = self
        helpButton.action = #selector(toggleShortcutHelp)
        helpButton.isBordered = false
        helpButton.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        helpButton.contentTintColor = .labelColor
        helpButton.wantsLayer = true
        helpButton.layer?.cornerRadius = 13
        helpButton.layer?.borderWidth = 1
        helpButton.layer?.borderColor = NSColor.separatorColor.cgColor
        helpButton.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        shortcutHelpPanel.wantsLayer = true
        shortcutHelpPanel.layer?.cornerRadius = 8
        shortcutHelpPanel.layer?.backgroundColor = NSColor(calibratedWhite: 0.91, alpha: 1).cgColor
        shortcutHelpPanel.layer?.borderWidth = 1
        shortcutHelpPanel.layer?.borderColor = NSColor(calibratedWhite: 0.68, alpha: 1).cgColor
        shortcutHelpPanel.isHidden = true

        shortcutHelpPanel.addSubview(shortcutHelpView)
    }

    private func configureTransientMessage() {
        transientMessageLabel.isHidden = true
        transientMessageLabel.alignment = .center
        transientMessageLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        transientMessageLabel.textColor = .white
        transientMessageLabel.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.82)
        transientMessageLabel.drawsBackground = true
        transientMessageLabel.wantsLayer = true
        transientMessageLabel.layer?.cornerRadius = 7
        transientMessageLabel.layer?.masksToBounds = true
    }

    @objc private func toggleShortcutHelp() {
        shortcutHelpPanel.isHidden.toggle()
        bringShortcutHelpToFront()
    }

    private func bringShortcutHelpToFront() {
        guard let content = window?.contentView, shortcutHelpPanel.superview === content else { return }
        content.addSubview(shortcutHelpPanel, positioned: .above, relativeTo: nil)
    }

    private func updateFileTreeToggleButton() {
        let symbolName = fileTreesExpanded ? "chevron.up" : "chevron.down"
        fileTreeToggleButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: fileTreesExpanded ? "Collapse file panel" : "Expand file panel")
    }

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let closeItem = NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command]
        closeItem.target = nil
        appMenu.addItem(closeItem)
        appMenu.addItem(withTitle: "退出 VideoCompare", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        let undoItem = NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = [.command]
        undoItem.target = nil
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = nil
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        let loadAItem = NSMenuItem(title: "加载 A...", action: #selector(openA), keyEquivalent: "")
        loadAItem.target = self
        fileMenu.addItem(loadAItem)
        let loadBItem = NSMenuItem(title: "加载 B...", action: #selector(openB), keyEquivalent: "")
        loadBItem.target = self
        fileMenu.addItem(loadBItem)
        fileMenu.addItem(.separator())
        let recentItem = NSMenuItem(title: "最近视频组", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(.separator())
        let toggleTreeItem = NSMenuItem(title: "展开/收起文件树", action: #selector(toggleMediaFileTrees), keyEquivalent: "b")
        toggleTreeItem.keyEquivalentModifierMask = [.command]
        toggleTreeItem.target = self
        fileMenu.addItem(toggleTreeItem)
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

        let imageItem = NSMenuItem()
        mainMenu.addItem(imageItem)
        let imageMenu = NSMenu(title: "画面")
        let colorItem = NSMenuItem(title: "调整选中视频...", action: #selector(openColorAdjustmentPanel(_:)), keyEquivalent: "c")
        colorItem.keyEquivalentModifierMask = [.command, .option]
        colorItem.target = self
        imageMenu.addItem(colorItem)
        imageItem.submenu = imageMenu

        NSApp.mainMenu = mainMenu
    }

    private func layoutContent() {
        layoutContent(animated: false)
    }

    private struct ContentLayoutFrames {
        let layoutControl: NSRect
        let helpButton: NSRect
        let fileTreeToggleButton: NSRect
        let shortcutHelpPanel: NSRect
        let syncTimeline: NSRect
        let mediaFileTrees: NSRect
        let canvas: NSRect
    }

    private func rectDebug(_ rect: NSRect) -> String {
        "x=\(String(format: "%.1f", rect.origin.x)) y=\(String(format: "%.1f", rect.origin.y)) w=\(String(format: "%.1f", rect.width)) h=\(String(format: "%.1f", rect.height))"
    }

    private func interpolatedRect(from start: NSRect, to end: NSRect, progress: CGFloat) -> NSRect {
        let p = max(0, min(1, progress))
        return NSRect(
            x: start.origin.x + (end.origin.x - start.origin.x) * p,
            y: start.origin.y + (end.origin.y - start.origin.y) * p,
            width: start.width + (end.width - start.width) * p,
            height: start.height + (end.height - start.height) * p
        )
    }

    private func easeInOut(_ progress: CGFloat) -> CGFloat {
        let p = max(0, min(1, progress))
        return p * p * (3 - 2 * p)
    }

    private func contentLayoutFrames(expanded: Bool) -> ContentLayoutFrames? {
        guard let content = window?.contentView else { return nil }
        let w = content.bounds.width
        let h = content.bounds.height
        let pad: CGFloat = 12
        let rowH: CGFloat = 28
        let gap: CGFloat = 8
        let toolbarY = max(pad, h - pad - rowH)
        let fileTreeTop = toolbarY - gap
        let syncTimelineFrame = NSRect(x: pad, y: pad, width: max(100, w - pad * 2), height: 78)
        let canvasY = syncTimelineFrame.maxY + gap
        let maxExpandedHeight = max(
            MediaFileTreesView.collapsedHeight,
            min(520, fileTreeTop - gap - canvasY - 100)
        )
        mediaFileTrees.setExpandedHeightRange(MediaFileTreesView.collapsedHeight...maxExpandedHeight)
        let fileTreeHeight: CGFloat = expanded ? mediaFileTrees.currentExpandedHeight : MediaFileTreesView.collapsedHeight
        let fileTreeFrame = NSRect(
            x: pad,
            y: fileTreeTop - fileTreeHeight,
            width: max(100, w - pad * 2),
            height: fileTreeHeight
        )

        let layoutWidth = min(max(300, w * 0.2), 420)
        let layoutX = floor(content.bounds.midX - layoutWidth / 2)
        let canvasTop = fileTreeFrame.minY - gap
        let helpW: CGFloat = 540
        let helpH: CGFloat = 340
        let helpFrame = NSRect(
            x: max(pad, w - pad - helpW),
            y: max(pad, toolbarY - helpH - 8),
            width: min(helpW, w - pad * 2),
            height: helpH
        )
        let helpButtonFrame = NSRect(x: w - pad - 26, y: toolbarY + 1, width: 26, height: 26)
        let fileTreeButtonFrame = NSRect(x: helpButtonFrame.minX - 38, y: toolbarY, width: 30, height: 28)

        return ContentLayoutFrames(
            layoutControl: NSRect(x: layoutX, y: toolbarY, width: layoutWidth, height: rowH),
            helpButton: helpButtonFrame,
            fileTreeToggleButton: fileTreeButtonFrame,
            shortcutHelpPanel: helpFrame,
            syncTimeline: syncTimelineFrame,
            mediaFileTrees: fileTreeFrame,
            canvas: NSRect(x: 0, y: canvasY, width: w, height: max(100, canvasTop - canvasY))
        )
    }

    private func layoutContent(animated: Bool) {
        guard let content = window?.contentView else { return }
        guard let frames = contentLayoutFrames(expanded: fileTreesExpanded) else { return }
        Diagnostics.log(
            "layoutContent animated=\(animated) expanded=\(fileTreesExpanded) mediaTarget=(\(rectDebug(frames.mediaFileTrees))) canvasTarget=(\(rectDebug(frames.canvas))) mediaCurrent=(\(rectDebug(mediaFileTrees.frame))) canvasCurrent=(\(rectDebug(canvas.frame)))"
        )

        func setFrame(_ view: NSView, _ frame: NSRect) {
            if animated {
                view.animator().frame = frame
            } else {
                view.frame = frame
            }
        }

        layoutControl.setWidth(frames.layoutControl.width / 2, forSegment: 0)
        layoutControl.setWidth(frames.layoutControl.width / 2, forSegment: 1)
        setFrame(layoutControl, frames.layoutControl)
        setFrame(fileTreeToggleButton, frames.fileTreeToggleButton)
        setFrame(helpButton, frames.helpButton)
        setFrame(shortcutHelpPanel, frames.shortcutHelpPanel)
        bringShortcutHelpToFront()
        shortcutHelpView.frame = shortcutHelpPanel.bounds.insetBy(dx: 12, dy: 12)

        setFrame(syncTimeline, frames.syncTimeline)
        setFrame(mediaFileTrees, frames.mediaFileTrees)
        mediaFileTrees.alphaValue = 1
        setFrame(canvas, frames.canvas)
        canvas.layoutSubtreeIfNeeded()
        let messageWidth = min(420, max(160, frames.canvas.width - 40))
        transientMessageLabel.frame = NSRect(
            x: frames.canvas.midX - messageWidth / 2,
            y: frames.canvas.maxY - 42,
            width: messageWidth,
            height: 28
        )
        content.addSubview(transientMessageLabel, positioned: .above, relativeTo: nil)
        let hideIndependentTimelines = canvas.layoutMode != .sideBySideHorizontal
        layoutVideoTimeline(videoATimeline, over: canvas.containerA.frame, hidden: hideIndependentTimelines || canvas.containerA.isHidden || playerA.isStaticImage, in: content)
        layoutVideoTimeline(videoBTimeline, over: canvas.containerB.frame, hidden: hideIndependentTimelines || canvas.containerB.isHidden || playerB.isStaticImage, in: content)
    }

    private func animateFileTreeTransition(to expanded: Bool, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let targetFrames = contentLayoutFrames(expanded: expanded) else { return }
        let startMediaFrame = mediaFileTrees.frame
        let startCanvasFrame = canvas.frame
        let startHelpFrame = shortcutHelpPanel.frame
        Diagnostics.log(
            "fileTree.anim.request expanded=\(expanded) mediaStart=(\(rectDebug(startMediaFrame))) mediaTarget=(\(rectDebug(targetFrames.mediaFileTrees))) canvasStart=(\(rectDebug(startCanvasFrame))) canvasTarget=(\(rectDebug(targetFrames.canvas)))"
        )
        layoutControl.setWidth(targetFrames.layoutControl.width / 2, forSegment: 0)
        layoutControl.setWidth(targetFrames.layoutControl.width / 2, forSegment: 1)
        mediaFileTrees.alphaValue = 1
        fileTreeAnimationTimer?.invalidate()

        let duration: TimeInterval = 0.24
        let startTime = CACurrentMediaTime()
        Diagnostics.log("fileTree.anim.manual.start expanded=\(expanded) duration=\(duration)")
        fileTreeAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                let raw = CGFloat((CACurrentMediaTime() - startTime) / duration)
                let progress = self.easeInOut(raw)
                self.mediaFileTrees.frame = self.interpolatedRect(from: startMediaFrame, to: targetFrames.mediaFileTrees, progress: progress)
                self.canvas.frame = self.interpolatedRect(from: startCanvasFrame, to: targetFrames.canvas, progress: progress)
                if !self.shortcutHelpPanel.isHidden {
                    self.shortcutHelpPanel.frame = self.interpolatedRect(from: startHelpFrame, to: targetFrames.shortcutHelpPanel, progress: progress)
                }

                if raw >= 1 {
                    self.fileTreeAnimationTimer?.invalidate()
                    self.fileTreeAnimationTimer = nil
                    self.layoutControl.frame = targetFrames.layoutControl
                    self.fileTreeToggleButton.frame = targetFrames.fileTreeToggleButton
                    self.helpButton.frame = targetFrames.helpButton
                    self.shortcutHelpPanel.frame = targetFrames.shortcutHelpPanel
                    self.syncTimeline.frame = targetFrames.syncTimeline
                    self.mediaFileTrees.frame = targetFrames.mediaFileTrees
                    self.canvas.frame = targetFrames.canvas
                    self.canvas.layoutSubtreeIfNeeded()
                    Diagnostics.log(
                        "fileTree.anim.manual.complete expanded=\(expanded) mediaActual=(\(self.rectDebug(self.mediaFileTrees.frame))) canvasActual=(\(self.rectDebug(self.canvas.frame)))"
                    )
                    self.layoutContent(animated: false)
                    completion?()
                }
            }
        }
        RunLoop.main.add(fileTreeAnimationTimer!, forMode: .common)
        logFileTreeAnimationSamples(expanded: expanded)
    }

    private func logFileTreeAnimationSamples(expanded: Bool) {
        for delay in [0.04, 0.12, 0.22, 0.32] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                Diagnostics.log(
                    "fileTree.anim.sample expanded=\(expanded) t=\(String(format: "%.2f", delay)) media=(\(self.rectDebug(self.mediaFileTrees.frame))) canvas=(\(self.rectDebug(self.canvas.frame)))"
                )
            }
        }
    }

    @objc private func toggleMediaFileTrees() {
        let previous = fileTreesExpanded
        fileTreesExpanded.toggle()
        Diagnostics.log("fileTree.toggle previous=\(previous) next=\(fileTreesExpanded)")
        let targetExpanded = fileTreesExpanded
        if !targetExpanded {
            mediaFileTrees.clearFocusAndSelectionForCollapse()
            window?.makeFirstResponder(nil)
        }
        updateFileTreeToggleButton()
        mediaFileTrees.setBrowserContentSuppressed(true)
        mediaFileTrees.setExpanded(targetExpanded, animated: true)
        animateFileTreeTransition(to: targetExpanded) { [weak self] in
            self?.mediaFileTrees.setBrowserContentSuppressed(!targetExpanded)
            if !targetExpanded {
                self?.mediaFileTrees.clearFocusAndSelectionForCollapse()
                self?.window?.makeFirstResponder(nil)
            }
        }
    }

    private func reloadMediaFileTrees() {
        mediaFileTrees.reload(
            rootA: mediaRoot(for: .a),
            displayA: mediaDisplayURL(for: .a),
            rootB: mediaRoot(for: .b),
            displayB: mediaDisplayURL(for: .b)
        )
    }

    private func restoreFilePanelRoots() {
        filePanelRootA = Self.loadSavedFilePanelRoot(slot: .a)
        filePanelRootB = Self.loadSavedFilePanelRoot(slot: .b)
    }

    private func mediaRoot(for slot: VideoSlot) -> URL {
        switch slot {
        case .a: filePanelRootA ?? playerA?.fileURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        case .b: filePanelRootB ?? playerB?.fileURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        }
    }

    private func mediaDisplayURL(for slot: VideoSlot) -> URL? {
        switch slot {
        case .a: filePanelDisplayA ?? playerA?.fileURL
        case .b: filePanelDisplayB ?? playerB?.fileURL
        }
    }

    private func setFilePanelLocation(root: URL, display: URL?, slot: VideoSlot) {
        switch slot {
        case .a:
            filePanelRootA = root.standardizedFileURL
            filePanelDisplayA = display?.standardizedFileURL
        case .b:
            filePanelRootB = root.standardizedFileURL
            filePanelDisplayB = display?.standardizedFileURL
        }
        Self.saveFilePanelRoot(root, slot: slot)
    }

    private static func filePanelRootDefaultsKey(slot: VideoSlot) -> String {
        switch slot {
        case .a: filePanelRootADefaultsKey
        case .b: filePanelRootBDefaultsKey
        }
    }

    private static func saveFilePanelRoot(_ root: URL, slot: VideoSlot) {
        UserDefaults.standard.set(root.standardizedFileURL.path, forKey: filePanelRootDefaultsKey(slot: slot))
    }

    private static func loadSavedFilePanelRoot(slot: VideoSlot) -> URL? {
        let path = UserDefaults.standard.string(forKey: filePanelRootDefaultsKey(slot: slot)) ?? ""
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private func expandMediaFileTreesIfNeeded() {
        guard !fileTreesExpanded else { return }
        fileTreesExpanded = true
        updateFileTreeToggleButton()
        mediaFileTrees.setBrowserContentSuppressed(true)
        mediaFileTrees.setExpanded(true, animated: true)
        animateFileTreeTransition(to: true) { [weak self] in
            self?.mediaFileTrees.setBrowserContentSuppressed(false)
        }
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
        ensureMainWindowVisible()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaFileSupport.allowedContentTypes
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url, slot: slot)
        }
    }

    private func handleDroppedItems(_ urls: [URL], targetSlot: VideoSlot) {
        let items = urls.compactMap(droppedItem(for:))
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }
        if items.count == 1, let item = items.first {
            switch item {
            case .media:
                applyDroppedItem(item, slot: targetSlot)
            case .directory(let url):
                applyDroppedDirectoryToBothPanels(url)
            }
            return
        }
        for (slot, item) in zip([VideoSlot.a, .b], items.prefix(2)) {
            applyDroppedItem(item, slot: slot)
        }
    }

    private func droppedItem(for url: URL) -> DroppedItem? {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return .directory(standardized)
        }
        guard MediaFileSupport.isSupported(standardized) else {
            return nil
        }
        return .media(standardized)
    }

    private func applyDroppedItem(_ item: DroppedItem, slot: VideoSlot) {
        switch item {
        case .media(let url):
            load(url: url, slot: slot)
        case .directory(let url):
            Diagnostics.log("drop.directory slot=\(slot.rawValue): \(url.path)")
            setFilePanelLocation(root: url, display: nil, slot: slot)
            reloadMediaFileTrees()
            expandMediaFileTreesIfNeeded()
        }
    }

    private func applyDroppedDirectoryToBothPanels(_ url: URL) {
        Diagnostics.log("drop.directory.both: \(url.path)")
        setFilePanelLocation(root: url, display: nil, slot: .a)
        setFilePanelLocation(root: url, display: nil, slot: .b)
        reloadMediaFileTrees()
        expandMediaFileTreesIfNeeded()
    }

    private func load(url: URL, slot: VideoSlot) {
        Diagnostics.log("load \(slot.rawValue): \(url.path)")
        clearPreviewUndoHistory()
        setFilePanelLocation(root: url.deletingLastPathComponent(), display: url, slot: slot)
        syncBaseTime = 0
        normalizedOffsetPair = nil
        clearSyncLoopRange()
        cancelWhiteBalanceSampling()
        debugTimelineState("load.reset slot=\(slot.rawValue)")
        switch slot {
        case .a:
            canvas.containerA.showsPlaceholder = false
            colorAdjustmentA = ColorAdjustmentState()
            rawTemperatureTintTrackingSlots.remove(.a)
            colorHistogramA = ColorHistogram.empty
            lastPixelBufferA = nil
            lastFrameTimeA = nil
            playerA.load(url: url)
        case .b:
            canvas.containerB.showsPlaceholder = false
            colorAdjustmentB = ColorAdjustmentState()
            rawTemperatureTintTrackingSlots.remove(.b)
            colorHistogramB = ColorHistogram.empty
            lastPixelBufferB = nil
            lastFrameTimeB = nil
            playerB.load(url: url)
        }
        applyColorAdjustmentsToRenderer()
        refreshColorAdjustmentPanel()
        layoutContent()
        reloadMediaFileTrees()
        loadPairStateIfReady()
    }

    private func loadPairStateIfReady() {
        guard let a = playerA.fileURL, let b = playerB.fileURL else { return }
        let pair = VideoPairIdentity(a: FileIdentity(url: a), b: FileIdentity(url: b))
        currentPair = pair
        syncState = PersistenceStore.shared.loadState(for: pair)
        Diagnostics.log("pair.state.loaded key=\(pair.key) offsetA=\(syncState.offsetFramesA) offsetB=\(syncState.offsetFramesB) ignoredTransformA=(\(syncState.transformA.panX),\(syncState.transformA.panY),\(syncState.transformA.zoom)) ignoredTransformB=(\(syncState.transformB.panX),\(syncState.transformB.panY),\(syncState.transformB.zoom))")
        syncState.transformA = TransformState()
        syncState.transformB = TransformState()
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

    private func adjustOffset(slot: VideoSlot, delta: Int) {
        pauseBothIfNeeded()
        let base = baseTimeAnchoredOpposite(of: slot)
        switch slot {
        case .a: syncState.offsetFramesA += delta
        case .b: syncState.offsetFramesB += delta
        }
        let baseShift = normalizeSyncOffsets(adjustBaseTime: false)
        refreshSyncLoopPreviewIfNeeded()
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

    private func seekToBaseTime(_ base: Double, exact: Bool = true, allowCachedFrame: Bool = true, publishFrame: Bool = true, completion: ((Bool) -> Void)? = nil) {
        let alignedBase = frameAlignedBaseTime(base)
        syncBaseTime = alignedBase
        let aTime = alignedBase + seconds(forFrames: syncState.offsetFramesA, fps: playerA.fps)
        let bTime = alignedBase + seconds(forFrames: syncState.offsetFramesB, fps: playerB.fps)
        Diagnostics.log("sync.seekToBase requested=\(debugTime(base)) aligned=\(debugTime(alignedBase)) exact=\(exact) aTarget=\(debugTime(aTime)) bTarget=\(debugTime(bTime))")
        var callbacks = 0
        var succeeded = false
        func finish(_ ok: Bool) {
            callbacks += 1
            succeeded = succeeded || ok
            guard callbacks == 2 else { return }
            completion?(succeeded)
        }
        let seekCompletion: ((Bool) -> Void)? = completion == nil ? nil : { ok in finish(ok) }
        display(playerA, at: aTime, exact: exact, allowCachedFrame: allowCachedFrame, publishFrame: publishFrame, completion: seekCompletion)
        display(playerB, at: bTime, exact: exact, allowCachedFrame: allowCachedFrame, publishFrame: publishFrame, completion: seekCompletion)
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

    private func syncScrubFPS() -> Double {
        max(1, max(playerA.fps, playerB.fps))
    }

    private func currentSliderBaseTime() -> Double {
        let duration = max(playerA.duration, playerB.duration)
        guard duration > 0 else { return 0 }
        return frameAlignedBaseTime(timeSlider.doubleValue * duration)
    }

    private func individualSliderTime(slot: VideoSlot) -> Double {
        let player = slot == .a ? playerA! : playerB!
        let slider = slot == .a ? videoASlider : videoBSlider
        guard player.duration > 0 else { return 0 }
        return frameAlignedTime(slider.doubleValue * player.duration, fps: player.fps)
    }

    private func display(_ player: NativeVideoPlayer, at seconds: Double, exact: Bool = true, allowCachedFrame: Bool = true, publishFrame: Bool = true, completion: ((Bool) -> Void)? = nil) {
        let visualTarget = visualDisplayTime(for: player, at: seconds)
        let hasContent = visualTarget != nil
        Diagnostics.log("display slot=\(player.slot.rawValue) target=\(debugTime(seconds)) visual=\(debugTime(visualTarget)) exact=\(exact) hasContent=\(hasContent) duration=\(debugTime(player.duration))")
        player.setVideoVisible(hasContent)
        if let visualTarget {
            player.seekAbsolute(visualTarget, exact: exact, allowCachedFrame: allowCachedFrame, publishFrame: publishFrame, completion: completion)
        } else {
            completion?(false)
        }
    }

    private func visualDisplayTime(for player: NativeVideoPlayer, at seconds: Double) -> Double? {
        guard player.fileURL != nil else { return nil }
        if player.isStaticImage {
            return 0
        }
        guard player.duration > 0 else {
            return seconds >= 0 ? seconds : nil
        }
        let fps = max(1, player.fps)
        let lastFrameTime = max(0, player.duration - 0.5 / fps)
        return min(max(0, seconds), lastFrameTime)
    }

    private func seconds(forFrames frames: Int, fps: Double) -> Double {
        Double(frames) / max(1, fps)
    }

    @objc private func sliderChanged() {
        Diagnostics.log("slider.sync.changed value=\(timeSlider.doubleValue) tracking=\(isTrackingTimeSlider)")
        if isTrackingTimeSlider {
            syncScrub.updateTarget(seconds: currentSliderBaseTime(), fps: syncScrubFPS())
        } else {
            seekToSliderPosition(exact: true)
        }
    }

    @objc private func videoASliderChanged() {
        if isTrackingVideoASlider {
            videoAScrub.updateTarget(seconds: individualSliderTime(slot: .a), fps: playerA.fps)
        } else {
            seekIndividualVideo(slot: .a, exact: true)
        }
    }

    @objc private func videoBSliderChanged() {
        if isTrackingVideoBSlider {
            videoBScrub.updateTarget(seconds: individualSliderTime(slot: .b), fps: playerB.fps)
        } else {
            seekIndividualVideo(slot: .b, exact: true)
        }
    }

    private func seekToSliderPosition(exact: Bool) {
        let duration = max(playerA.duration, playerB.duration)
        guard duration > 0 else { return }
        pauseBothIfNeeded()
        let base = currentSliderBaseTime()
        Diagnostics.log("slider.sync.seek value=\(timeSlider.doubleValue) duration=\(debugTime(duration)) exactArg=\(exact) base=\(debugTime(base))")
        seekToBaseTime(base, exact: exact)
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
        preheatSyncLoopStart(range: lower...upper)
        Diagnostics.log("loop.set fractions=(\(range.lowerBound),\(range.upperBound)) seconds=\(debugRange(syncLoopRange))")
        debugTimelineState("loop.set")
    }

    private func clearSyncLoopRange() {
        Diagnostics.log("loop.clear previous=\(debugRange(syncLoopRange))")
        cancelLoopSeekState(reason: "clear")
        loopPreviewGeneration += 1
        loopPreviewFramesA = []
        loopPreviewFramesB = []
        syncLoopRange = nil
        timeSlider.loopRange = nil
        debugTimelineState("loop.clear")
    }

    private func preheatSyncLoopStart(range: ClosedRange<Double>) {
        loopPreviewGeneration += 1
        loopPreviewFramesA = []
        loopPreviewFramesB = []
        let generation = loopPreviewGeneration
        preheatLoopPreviewFrames(slot: .a, base: range.lowerBound, range: range, generation: generation)
        preheatLoopPreviewFrames(slot: .b, base: range.lowerBound, range: range, generation: generation)
    }

    private func refreshSyncLoopPreviewIfNeeded() {
        guard let syncLoopRange else { return }
        preheatSyncLoopStart(range: syncLoopRange)
    }

    private func preheatLoopPreviewFrames(slot: VideoSlot, base: Double, range: ClosedRange<Double>, generation: Int) {
        let player = slot == .a ? playerA! : playerB!
        guard player.fileURL != nil else { return }
        let offsetFrames = slot == .a ? syncState.offsetFramesA : syncState.offsetFramesB
        let offsetSeconds = seconds(forFrames: offsetFrames, fps: player.fps)
        let targetTime = base + offsetSeconds
        guard canDisplay(player, at: targetTime) else { return }
        player.decodeFramesForLoopPreview(seconds: targetTime, exact: true, maxFrames: Self.loopPreviewFrameCount) { [weak self] frames in
            guard let self,
                  generation == self.loopPreviewGeneration,
                  let currentRange = self.syncLoopRange,
                  abs(currentRange.lowerBound - range.lowerBound) < 0.0001,
                  abs(currentRange.upperBound - range.upperBound) < 0.0001 else {
                return
            }
            let frameInterval = 1.0 / max(1, max(self.playerA.fps, self.playerB.fps))
            let validFrames = frames.filter { frame in
                let baseTime = max(0, frame.pts - offsetSeconds)
                return baseTime <= range.upperBound + frameInterval * 0.5
            }
            switch slot {
            case .a:
                self.loopPreviewFramesA = validFrames
            case .b:
                self.loopPreviewFramesB = validFrames
            }
            Diagnostics.log("sync.loop.preview.ready slot=\(slot.rawValue) generation=\(generation) target=\(self.debugTime(targetTime)) frames=\(validFrames.count) first=\(self.debugTime(validFrames.first?.pts)) last=\(self.debugTime(validFrames.last?.pts))")
        }
    }

    @discardableResult
    private func presentLoopStartPreview(loopRange: ClosedRange<Double>) -> Bool {
        syncBaseTime = loopRange.lowerBound
        var didPresent = false
        if let frame = loopPreviewFramesA.first {
            playerA.setVideoVisible(true)
            playerA.presentSynchronizedFrame(frame)
            didPresent = true
        }
        if let frame = loopPreviewFramesB.first {
            playerB.setVideoVisible(true)
            playerB.presentSynchronizedFrame(frame)
            didPresent = true
        }
        if didPresent {
            Diagnostics.log("sync.loop.preview.present base=\(debugTime(loopRange.lowerBound)) frameA=\(debugTime(loopPreviewFramesA.first?.pts)) frameB=\(debugTime(loopPreviewFramesB.first?.pts))")
            refreshStatus()
        }
        return didPresent
    }

    private func hasCompleteLoopPreview(loopRange: ClosedRange<Double>) -> Bool {
        hasLoopPreview(slot: .a, loopRange: loopRange) && hasLoopPreview(slot: .b, loopRange: loopRange)
    }

    private func hasLoopPreview(slot: VideoSlot, loopRange: ClosedRange<Double>) -> Bool {
        let player = slot == .a ? playerA! : playerB!
        guard player.fileURL != nil else { return true }
        let offsetFrames = slot == .a ? syncState.offsetFramesA : syncState.offsetFramesB
        let targetTime = loopRange.lowerBound + seconds(forFrames: offsetFrames, fps: player.fps)
        guard canDisplay(player, at: targetTime) else { return true }
        switch slot {
        case .a:
            return !loopPreviewFramesA.isEmpty
        case .b:
            return !loopPreviewFramesB.isEmpty
        }
    }

    private func cancelLoopPreviewPlayback() {
        loopPreviewPlaybackGeneration += 1
    }

    private func cancelLoopSeekState(reason: String) {
        cancelLoopPreviewPlayback()
        loopSeekGeneration += 1
        if loopSeekInProgress {
            Diagnostics.log("sync.loop.seekCancel reason=\(reason) generation=\(loopSeekGeneration)")
        }
        loopSeekInProgress = false
    }

    private func playLoopPreviewFramesWhileSeeking(token: Int, loopRange: ClosedRange<Double>) {
        let maxCount = max(loopPreviewFramesA.count, loopPreviewFramesB.count)
        guard maxCount > 1 else { return }
        loopPreviewPlaybackGeneration += 1
        let generation = loopPreviewPlaybackGeneration
        let frameInterval = 1.0 / max(1, max(playerA.fps, playerB.fps))
        Diagnostics.log("sync.loop.preview.play token=\(token) generation=\(generation) framesA=\(loopPreviewFramesA.count) framesB=\(loopPreviewFramesB.count)")
        scheduleLoopPreviewFrame(
            index: 1,
            maxCount: maxCount,
            token: token,
            generation: generation,
            loopRange: loopRange,
            frameInterval: frameInterval
        )
    }

    private func scheduleLoopPreviewFrame(
        index: Int,
        maxCount: Int,
        token: Int,
        generation: Int,
        loopRange: ClosedRange<Double>,
        frameInterval: Double
    ) {
        guard index < maxCount else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + frameInterval) { [weak self] in
            guard let self,
                  self.loopPreviewPlaybackGeneration == generation,
                  self.isSynchronizedPlaying,
                  token == self.synchronizedPlaybackToken,
                  self.loopSeekInProgress,
                  self.syncLoopRange != nil else {
                return
            }
            var frameA: NativeVideoFrame?
            var frameB: NativeVideoFrame?
            if self.loopPreviewFramesA.indices.contains(index) {
                frameA = self.loopPreviewFramesA[index]
                self.playerA.setVideoVisible(true)
                self.playerA.presentSynchronizedFrame(frameA!)
            }
            if self.loopPreviewFramesB.indices.contains(index) {
                frameB = self.loopPreviewFramesB[index]
                self.playerB.setVideoVisible(true)
                self.playerB.presentSynchronizedFrame(frameB!)
            }
            if let nextBase = self.baseTime(frameA: frameA, frameB: frameB),
               nextBase <= loopRange.upperBound + frameInterval * 0.5 {
                self.syncBaseTime = nextBase
                self.refreshStatus()
                Diagnostics.log("sync.loop.preview.frame token=\(token) generation=\(generation) index=\(index) base=\(self.debugTime(nextBase)) frameA=\(self.debugTime(frameA?.pts)) frameB=\(self.debugTime(frameB?.pts))")
                self.scheduleLoopPreviewFrame(
                    index: index + 1,
                    maxCount: maxCount,
                    token: token,
                    generation: generation,
                    loopRange: loopRange,
                    frameInterval: frameInterval
                )
            }
        }
    }

    private func canDisplay(_ player: NativeVideoPlayer, at seconds: Double) -> Bool {
        seconds >= 0 && (player.duration <= 0 || seconds <= player.duration)
    }

    private func synchronizedTargetTime(for slot: VideoSlot, base: Double) -> Double {
        switch slot {
        case .a:
            return base + seconds(forFrames: syncState.offsetFramesA, fps: playerA.fps)
        case .b:
            return base + seconds(forFrames: syncState.offsetFramesB, fps: playerB.fps)
        }
    }

    private func shouldDecodeSynchronizedFrame(slot: VideoSlot, base: Double) -> Bool {
        let player = slot == .a ? playerA! : playerB!
        guard player.fileURL != nil, !player.isStaticImage else { return false }
        let target = synchronizedTargetTime(for: slot, base: base)
        guard player.duration > 0 else { return target >= 0 }
        let halfFrame = 0.5 / max(1, player.fps)
        return target >= -halfFrame && target <= player.duration + halfFrame
    }

    private func seekIndividualVideo(slot: VideoSlot, exact: Bool) {
        seekIndividualVideo(slot: slot, targetTime: individualSliderTime(slot: slot), exact: exact)
    }

    private func seekIndividualVideo(slot: VideoSlot, targetTime: Double, exact: Bool) {
        stopSynchronizedBarrierPlayback()
        let player = slot == .a ? playerA! : playerB!
        guard player.duration > 0 else { return }
        if !player.isPaused {
            player.setPause(true)
        }
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
            syncBaseTime = base + normalizeSyncOffsets(adjustBaseTime: false)
        case .b:
            let base = playerA.fileURL != nil
                ? playerA.timePosition - seconds(forFrames: syncState.offsetFramesA, fps: playerA.fps)
                : 0
            syncState.offsetFramesB = Int(round((targetTime - base) * max(1, playerB.fps)))
            syncBaseTime = base + normalizeSyncOffsets(adjustBaseTime: false)
        }
        refreshSyncLoopPreviewIfNeeded()
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
        beginPreviewUndoGroup()
        adjustTransform(dx: 0, dy: 0, dz: -0.05)
        commitPreviewUndoGroup()
        refreshStatus()
    }

    @objc private func zoomIn() {
        guard canvas.allowsAlignmentAdjustment else { return }
        beginPreviewUndoGroup()
        adjustTransform(dx: 0, dy: 0, dz: 0.05)
        commitPreviewUndoGroup()
        refreshStatus()
    }

    @objc private func toggleDisableSubtitles() {
        let value = !AppSettings.shared.disableSubtitles
        AppSettings.shared.disableSubtitles = value
        disableSubtitlesMenuItem?.state = value ? .on : .off
        playerA.setSubtitleLoadingDisabled(value)
        playerB.setSubtitleLoadingDisabled(value)
    }

    @objc func openColorAdjustmentPanel(_ sender: Any?) {
        Diagnostics.log(
            "colorPanel.open.begin sender=\(String(describing: sender.map { type(of: $0) })) " +
            "exe=\(Bundle.main.executableURL?.path ?? "unknown") " +
            "selected=\(selectedSlot?.rawValue ?? "nil") " +
            "fileA=\(playerA.fileURL?.path ?? "nil") fileB=\(playerB.fileURL?.path ?? "nil") " +
            "hasPanel=\(colorAdjustmentPanel != nil)"
        )
        if selectedSlot == nil {
            if playerA.fileURL != nil {
                selectedSlot = .a
            } else if playerB.fileURL != nil {
                selectedSlot = .b
            }
        }
        let panel = colorAdjustmentPanel ?? makeColorAdjustmentPanel()
        colorAdjustmentPanel = panel
        refreshColorAdjustmentPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
        panel.window?.orderFrontRegardless()
        Diagnostics.log(
            "colorPanel.open.end selected=\(selectedSlot?.rawValue ?? "nil") " +
            "visible=\(panel.window?.isVisible ?? false) key=\(panel.window?.isKeyWindow ?? false)"
        )
    }

    private func makeColorAdjustmentPanel() -> ColorAdjustmentPanelController {
        Diagnostics.log("colorPanel.make.begin")
        let panel = ColorAdjustmentPanelController()
        panel.onStateChanged = { [weak self] state in
            guard let self, let slot = self.selectedSlot else { return }
            self.setColorAdjustment(state, slot: slot)
        }
        panel.onStateChangeTracking = { [weak self] state, tracking in
            guard let self, let slot = self.selectedSlot else { return }
            self.setColorAdjustmentTracking(state, slot: slot, tracking: tracking)
        }
        panel.onReset = { [weak self] in
            guard let self, let slot = self.selectedSlot else { return }
            self.setColorAdjustment(ColorAdjustmentState(), slot: slot)
        }
        panel.onWhiteBalanceRequested = { [weak self] in
            self?.toggleWhiteBalanceSampling()
        }
        Diagnostics.log("colorPanel.make.end window=\(panel.window != nil)")
        return panel
    }

    private func setColorAdjustment(_ adjustment: ColorAdjustmentState, slot: VideoSlot) {
        let deferRawCommit = isRawImageLoaded(in: slot) && rawTemperatureTintTrackingSlots.contains(slot)
        setColorAdjustment(adjustment, slot: slot, rawPreview: deferRawCommit, forceRawReload: false)
    }

    private func setColorAdjustmentTracking(_ adjustment: ColorAdjustmentState, slot: VideoSlot, tracking: Bool) {
        guard isRawImageLoaded(in: slot) else { return }
        if tracking {
            rawTemperatureTintTrackingSlots.insert(slot)
            return
        }
        rawTemperatureTintTrackingSlots.remove(slot)
        setColorAdjustment(adjustment, slot: slot, rawPreview: false, forceRawReload: true)
    }

    private func setColorAdjustment(_ adjustment: ColorAdjustmentState, slot: VideoSlot, rawPreview: Bool, forceRawReload: Bool) {
        let previous = colorAdjustment(for: slot)
        let changed = previous != adjustment
        let rawTemperatureTintChanged = previous.temperature != adjustment.temperature || previous.tint != adjustment.tint
        let rawDecodeAdjustmentChanged = previous.isEnabled != adjustment.isEnabled || (adjustment.isEnabled && rawTemperatureTintChanged)
        guard changed || forceRawReload else { return }
        if changed && !isApplyingPreviewHistory {
            beginPreviewUndoGroup()
        }
        if changed {
            switch slot {
            case .a:
                colorAdjustmentA = adjustment
                canvas.renderer.colorAdjustmentA = rendererColorAdjustment(for: .a)
            case .b:
                colorAdjustmentB = adjustment
                canvas.renderer.colorAdjustmentB = rendererColorAdjustment(for: .b)
            }
        }
        if isRawImageLoaded(in: slot), rawDecodeAdjustmentChanged || forceRawReload {
            reloadRawStaticImageIfNeeded(slot: slot, adjustment: adjustment, preview: rawPreview)
        }
        refreshHistogramForCurrentFrame(slot: slot)
        refreshColorAdjustmentPanel()
        if changed && !isApplyingPreviewHistory {
            schedulePreviewUndoCommit()
        }
    }

    private func applyColorAdjustmentsToRenderer() {
        canvas.renderer.colorAdjustmentA = rendererColorAdjustment(for: .a)
        canvas.renderer.colorAdjustmentB = rendererColorAdjustment(for: .b)
        canvas.renderer.originalBypassSlot = originalBypassSlot
    }

    private func rendererColorAdjustment(for slot: VideoSlot) -> ColorAdjustmentState {
        let adjustment = colorAdjustment(for: slot)
        guard isRawImageLoaded(in: slot) else {
            return adjustment
        }
        var rendererAdjustment = adjustment
        rendererAdjustment.temperature = 0
        rendererAdjustment.tint = 0
        return rendererAdjustment
    }

    private func reloadRawStaticImageIfNeeded(slot: VideoSlot, adjustment: ColorAdjustmentState, preview: Bool = false) {
        guard isRawImageLoaded(in: slot) else { return }
        let player = slot == .a ? playerA! : playerB!
        player.reloadStaticImage(rawAdjustment: adjustment, preview: preview) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.applyColorAdjustmentsToRenderer()
                self.refreshHistogramForCurrentFrame(slot: slot)
            } else if !preview {
                self.showTransientMessage("该 RAW 文件不支持解码级调色")
            }
        }
    }

    private func toggleWhiteBalanceSampling() {
        if isWhiteBalanceSampling {
            cancelWhiteBalanceSampling()
            return
        }
        guard let selectedSlot, pixelBuffer(for: selectedSlot) != nil else {
            showTransientMessage("请先选择有画面的 A/B")
            return
        }
        isWhiteBalanceSampling = true
        canvas.isWhiteBalanceSampling = true
        colorAdjustmentPanel?.setWhiteBalanceSampling(true)
        showTransientMessage("点击画面中的白色或中性灰区域")
    }

    private func cancelWhiteBalanceSampling(invalidatePending: Bool = true) {
        guard isWhiteBalanceSampling else { return }
        isWhiteBalanceSampling = false
        canvas.isWhiteBalanceSampling = false
        colorAdjustmentPanel?.setWhiteBalanceSampling(false)
        if invalidatePending {
            rawWhiteBalanceGeneration += 1
            pendingRawWhiteBalanceRequest = nil
            lastRawWhiteBalancePreview = nil
        }
    }

    private func handleWhiteBalancePick(slot: VideoSlot, canvasPoint: NSPoint, phase: WhiteBalancePickPhase) {
        guard isWhiteBalanceSampling else { return }
        selectedSlot = slot
        if !isRawImageLoaded(in: slot) {
            if phase == .begin {
                applyWhiteBalanceSample(slot: slot, canvasPoint: canvasPoint)
            }
            return
        }
        if phase == .begin {
            showTransientMessage("正在计算 RAW 白平衡...")
            submitRawWhiteBalancePick(slot: slot, canvasPoint: canvasPoint, phase: phase)
        } else if phase == .cancel {
            cancelWhiteBalanceSampling()
        }
    }

    private func submitRawWhiteBalancePick(slot: VideoSlot, canvasPoint: NSPoint, phase: WhiteBalancePickPhase) {
        rawWhiteBalanceGeneration += 1
        let request = RawWhiteBalancePickRequest(
            generation: rawWhiteBalanceGeneration,
            slot: slot,
            canvasPoint: canvasPoint,
            phase: phase
        )
        if rawWhiteBalanceIsSolving {
            pendingRawWhiteBalanceRequest = request
            return
        }
        startRawWhiteBalancePick(request)
    }

    private func startRawWhiteBalancePick(_ request: RawWhiteBalancePickRequest) {
        guard let pixelBuffer = pixelBuffer(for: request.slot),
              let pixelPoint = pixelPoint(for: request.canvasPoint, slot: request.slot, pixelBuffer: pixelBuffer),
              isRawImageLoaded(in: request.slot) else {
            showTransientMessage("请点击画面内容区域")
            return
        }
        let player = request.slot == .a ? playerA! : playerB!
        let baseAdjustment = colorAdjustment(for: request.slot)
        var solvingBaseAdjustment = baseAdjustment
        solvingBaseAdjustment.isEnabled = true
        var preferredAdjustment = lastRawWhiteBalancePreview?.slot == request.slot
            ? lastRawWhiteBalancePreview?.adjustment
            : solvingBaseAdjustment
        preferredAdjustment?.isEnabled = true
        let searchMode: RawWhiteBalanceSearchMode = .finalCommit
        let started = CACurrentMediaTime()
        rawWhiteBalanceIsSolving = true
        player.solveRawWhiteBalance(
            canvasPixelPoint: pixelPoint,
            baseAdjustment: solvingBaseAdjustment,
            preferredAdjustment: preferredAdjustment,
            searchMode: searchMode,
            sampleRadius: 7
        ) { [weak self] result in
            guard let self else { return }
            self.rawWhiteBalanceIsSolving = false
            let solveElapsed = CACurrentMediaTime() - started
            Diagnostics.log("raw.wb.solve slot=\(request.slot.rawValue) phase=\(request.phase) mode=\(searchMode) elapsed=\(String(format: "%.4f", solveElapsed))")
            defer {
                if let pending = self.pendingRawWhiteBalanceRequest {
                    self.pendingRawWhiteBalanceRequest = nil
                    self.startRawWhiteBalancePick(pending)
                }
            }
            guard request.generation == self.rawWhiteBalanceGeneration else { return }
            guard let result,
                  self.isRawImageLoaded(in: request.slot) else {
                self.showTransientMessage("取样区域不适合白平衡")
                return
            }
            var adjustment = self.colorAdjustment(for: request.slot)
            adjustment.temperature = result.adjustmentTemperature
            adjustment.tint = result.adjustmentTint
            self.lastRawWhiteBalancePreview = (request.slot, adjustment)
            self.applyRawWhiteBalanceAdjustment(
                adjustment,
                slot: request.slot,
                commitFullResolution: true
            )
            self.showTransientMessage(adjustment.isEnabled ? "已应用 RAW 取色白平衡，可继续点击取样" : "已记录 RAW 取色白平衡，勾选启用后应用")
            self.lastRawWhiteBalancePreview = nil
        }
    }

    private func applyWhiteBalanceSample(slot: VideoSlot, canvasPoint: NSPoint) {
        guard isWhiteBalanceSampling else { return }
        selectedSlot = slot
        guard let pixelBuffer = pixelBuffer(for: slot) else {
            showTransientMessage("当前画面不可取样")
            return
        }
        guard let pixelPoint = pixelPoint(for: canvasPoint, slot: slot, pixelBuffer: pixelBuffer) else {
            showTransientMessage("请点击画面内容区域")
            return
        }
        if isRawImageLoaded(in: slot) {
            let player = slot == .a ? playerA! : playerB!
            let baseAdjustment = colorAdjustment(for: slot)
            var solvingBaseAdjustment = baseAdjustment
            solvingBaseAdjustment.isEnabled = true
            showTransientMessage("正在计算 RAW 白平衡...")
            player.solveRawWhiteBalance(
                canvasPixelPoint: pixelPoint,
                baseAdjustment: solvingBaseAdjustment,
                sampleRadius: 7
            ) { [weak self] result in
                guard let self else { return }
                guard let result,
                      self.isRawImageLoaded(in: slot) else {
                    self.showTransientMessage("取样区域不适合白平衡")
                    return
                }
                var adjustment = self.colorAdjustment(for: slot)
                adjustment.temperature = result.adjustmentTemperature
                adjustment.tint = result.adjustmentTint
                self.applyRawWhiteBalanceAdjustment(adjustment, slot: slot)
                self.showTransientMessage(adjustment.isEnabled ? "已应用 RAW 取色白平衡，可继续点击取样" : "已记录 RAW 取色白平衡，勾选启用后应用")
            }
            return
        }
        guard let sample = Self.sampleRGB(pixelBuffer: pixelBuffer, center: pixelPoint, radius: 7) else {
            showTransientMessage("取样失败，请换一个位置")
            return
        }
        let range = ColorAdjustmentControlRanges.standardTemperatureTint
        var adjustment = colorAdjustment(for: slot)
        guard let correction = WhiteBalanceSolver.temperatureTintCorrection(
            sample: sample,
            baseAdjustment: adjustment,
            range: range
        ) else {
            showTransientMessage("取样区域不适合白平衡")
            return
        }
        adjustment.temperature = correction.temperature
        adjustment.tint = correction.tint
        setColorAdjustment(adjustment, slot: slot)
        showTransientMessage(adjustment.isEnabled ? "已应用取色白平衡，可继续点击取样" : "已记录取色白平衡，勾选启用后应用")
    }

    private func applyRawWhiteBalanceAdjustment(_ adjustment: ColorAdjustmentState, slot: VideoSlot, commitFullResolution: Bool = true) {
        let previous = colorAdjustment(for: slot)
        let changed = previous != adjustment
        if changed && !isApplyingPreviewHistory {
            beginPreviewUndoGroup()
        }
        if changed {
            switch slot {
            case .a:
                colorAdjustmentA = adjustment
                canvas.renderer.colorAdjustmentA = rendererColorAdjustment(for: .a)
            case .b:
                colorAdjustmentB = adjustment
                canvas.renderer.colorAdjustmentB = rendererColorAdjustment(for: .b)
            }
            refreshHistogramForCurrentFrame(slot: slot)
            refreshColorAdjustmentPanel()
            if !isApplyingPreviewHistory {
                schedulePreviewUndoCommit()
            }
        }

        guard adjustment.isEnabled else { return }

        let player = slot == .a ? playerA! : playerB!
        let previewStarted = CACurrentMediaTime()
        player.reloadStaticImage(rawAdjustment: adjustment, preview: true) { [weak self] ok in
            guard let self else { return }
            Diagnostics.log("raw.wb.preview slot=\(slot.rawValue) elapsed=\(String(format: "%.4f", CACurrentMediaTime() - previewStarted))")
            guard ok else {
                self.showTransientMessage("该 RAW 文件不支持解码级调色")
                return
            }
            self.refreshHistogramForCurrentFrame(slot: slot)
            guard commitFullResolution else { return }
            guard self.colorAdjustment(for: slot) == adjustment,
                  self.isRawImageLoaded(in: slot) else { return }
            let commitStarted = CACurrentMediaTime()
            player.reloadStaticImage(rawAdjustment: adjustment, preview: false) { [weak self] ok in
                guard let self else { return }
                Diagnostics.log("raw.wb.commit slot=\(slot.rawValue) elapsed=\(String(format: "%.4f", CACurrentMediaTime() - commitStarted))")
                if ok {
                    self.refreshHistogramForCurrentFrame(slot: slot)
                } else {
                    self.showTransientMessage("该 RAW 文件不支持解码级调色")
                }
            }
        }
    }

    private func pixelBuffer(for slot: VideoSlot) -> CVPixelBuffer? {
        switch slot {
        case .a: lastPixelBufferA
        case .b: lastPixelBufferB
        }
    }

    private func transform(for slot: VideoSlot) -> TransformState {
        switch slot {
        case .a: syncState.transformA
        case .b: syncState.transformB
        }
    }

    private func pixelPoint(for canvasPoint: NSPoint, slot: VideoSlot, pixelBuffer: CVPixelBuffer) -> CGPoint? {
        let contentRect = canvas.videoRect(for: slot)
        let videoRect = Self.displayedVideoRect(
            pixelBuffer: pixelBuffer,
            transform: transform(for: slot),
            contentRect: contentRect
        )
        guard videoRect.width > 0,
              videoRect.height > 0,
              videoRect.contains(CGPoint(x: canvasPoint.x, y: canvasPoint.y)) else {
            return nil
        }
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard width > 0, height > 0 else { return nil }
        return CGPoint(
            x: min(width - 1, max(0, (canvasPoint.x - videoRect.minX) / videoRect.width * width)),
            y: min(height - 1, max(0, (canvasPoint.y - videoRect.minY) / videoRect.height * height))
        )
    }

    private func currentPreviewEditState() -> PreviewEditState {
        PreviewEditState(
            transformA: syncState.transformA,
            transformB: syncState.transformB,
            colorAdjustmentA: colorAdjustmentA,
            colorAdjustmentB: colorAdjustmentB
        )
    }

    private func beginPreviewUndoGroup() {
        guard !isApplyingPreviewHistory, pendingUndoSnapshot == nil else { return }
        pendingUndoSnapshot = currentPreviewEditState()
    }

    private func commitPreviewUndoGroup() {
        pendingUndoCommitTimer?.invalidate()
        pendingUndoCommitTimer = nil
        guard let before = pendingUndoSnapshot else { return }
        pendingUndoSnapshot = nil
        guard before != currentPreviewEditState() else { return }
        undoStack.append(before)
        redoStack.removeAll()
    }

    private func schedulePreviewUndoCommit() {
        guard pendingUndoSnapshot != nil else { return }
        pendingUndoCommitTimer?.invalidate()
        pendingUndoCommitTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.commitPreviewUndoGroup()
            }
        }
        RunLoop.main.add(pendingUndoCommitTimer!, forMode: .common)
    }

    private func clearPreviewUndoHistory() {
        pendingUndoCommitTimer?.invalidate()
        pendingUndoCommitTimer = nil
        pendingUndoSnapshot = nil
        undoStack.removeAll()
        redoStack.removeAll()
    }

    @objc private func undoPreviewEdit() {
        commitPreviewUndoGroup()
        guard let previous = undoStack.popLast() else {
            NSSound.beep()
            return
        }
        redoStack.append(currentPreviewEditState())
        applyPreviewEditState(previous)
    }

    @objc private func redoPreviewEdit() {
        commitPreviewUndoGroup()
        guard let next = redoStack.popLast() else {
            NSSound.beep()
            return
        }
        undoStack.append(currentPreviewEditState())
        applyPreviewEditState(next)
    }

    private func applyPreviewEditState(_ state: PreviewEditState) {
        isApplyingPreviewHistory = true
        syncState.transformA = state.transformA
        syncState.transformB = state.transformB
        colorAdjustmentA = state.colorAdjustmentA
        colorAdjustmentB = state.colorAdjustmentB

        canvas.renderer.transformA = syncState.transformA
        canvas.renderer.transformB = syncState.transformB
        playerA.applyTransform(syncState.transformA)
        playerB.applyTransform(syncState.transformB)
        applyColorAdjustmentsToRenderer()
        reloadRawStaticImageIfNeeded(slot: .a, adjustment: colorAdjustmentA)
        reloadRawStaticImageIfNeeded(slot: .b, adjustment: colorAdjustmentB)
        refreshHistogramForCurrentFrame(slot: .a)
        refreshHistogramForCurrentFrame(slot: .b)
        refreshColorAdjustmentPanel()
        refreshStatus()
        isApplyingPreviewHistory = false
    }

    private func performROIAlignment(sourceSlot: VideoSlot, sourceCanvasRect: NSRect) {
        guard canvas.layoutMode == .overlapWipe else {
            rejectROIAlignment("roi.align.reject layout")
            return
        }
        guard playerA.fileURL != nil, playerB.fileURL != nil,
              let bufferA = lastPixelBufferA,
              let bufferB = lastPixelBufferB else {
            rejectROIAlignment("roi.align.reject missing-frame")
            return
        }
        guard !isSynchronizedPlaying, playerA.isPaused, playerB.isPaused else {
            rejectROIAlignment("roi.align.reject playing")
            return
        }
        guard !isROIAlignmentRunning else {
            rejectROIAlignment("roi.align.reject busy")
            return
        }

        canvas.layoutSubtreeIfNeeded()
        let contentRect = canvas.videoRect(for: sourceSlot)
        guard contentRect.width > 1, contentRect.height > 1 else {
            rejectROIAlignment("roi.align.reject empty-content")
            return
        }

        roiAlignmentGeneration += 1
        isROIAlignmentRunning = true
        let generation = roiAlignmentGeneration
        let snapshot = ROIAlignmentSnapshot(
            generation: generation,
            sourceSlot: sourceSlot,
            sourcePixelBuffer: sourceSlot == .a ? bufferA : bufferB,
            targetPixelBuffer: sourceSlot == .a ? bufferB : bufferA,
            sourceFrameTime: sourceSlot == .a ? lastFrameTimeA : lastFrameTimeB,
            targetFrameTime: sourceSlot == .a ? lastFrameTimeB : lastFrameTimeA,
            sourceTransform: sourceSlot == .a ? syncState.transformA : syncState.transformB,
            targetTransform: sourceSlot == .a ? syncState.transformB : syncState.transformA,
            sourceCanvasRect: sourceCanvasRect,
            contentRect: contentRect
        )

        Diagnostics.log("roi.align.start slot=\(sourceSlot.rawValue) rect=(\(rectDebug(sourceCanvasRect)))")
        roiAlignmentQueue.async { [weak self] in
            let result = Self.computeROIAlignment(snapshot: snapshot)
            DispatchQueue.main.async {
                self?.finishROIAlignment(snapshot: snapshot, result: result)
            }
        }
    }

    private func rejectROIAlignment(_ reason: String) {
        Diagnostics.log(reason)
        NSSound.beep()
        showTransientMessage(messageForROIAlignmentRejection(reason))
    }

    private func messageForROIAlignmentRejection(_ reason: String) -> String {
        if reason.contains("layout") { return "请先切换到拖动遮罩模式" }
        if reason.contains("missing-frame") { return "请先加载 A/B 并停在当前帧" }
        if reason.contains("playing") { return "自动对齐仅在暂停时可用" }
        if reason.contains("busy") { return "正在计算自动对齐" }
        if reason.contains("empty-content") { return "当前画面区域不可用" }
        if reason.contains("no-match") { return "没有找到可靠的匹配区域" }
        return "无法执行自动对齐"
    }

    private func showTransientMessage(_ message: String) {
        transientMessageGeneration += 1
        let generation = transientMessageGeneration
        transientMessageLabel.stringValue = message
        transientMessageLabel.isHidden = false
        transientMessageLabel.alphaValue = 1
        transientMessageLabel.superview?.addSubview(transientMessageLabel, positioned: .above, relativeTo: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.transientMessageGeneration == generation else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                self.transientMessageLabel.animator().alphaValue = 0
            } completionHandler: {
                guard self.transientMessageGeneration == generation else { return }
                self.transientMessageLabel.isHidden = true
                self.transientMessageLabel.alphaValue = 1
            }
        }
    }

    private func finishROIAlignment(snapshot: ROIAlignmentSnapshot, result: ROIAlignmentResult?) {
        defer { isROIAlignmentRunning = false }
        guard roiAlignmentGeneration == snapshot.generation,
              canvas.layoutMode == .overlapWipe,
              snapshot.sourceTransform == (snapshot.sourceSlot == .a ? syncState.transformA : syncState.transformB),
              snapshot.targetTransform == (snapshot.sourceSlot == .a ? syncState.transformB : syncState.transformA),
              snapshot.sourceFrameTime == (snapshot.sourceSlot == .a ? lastFrameTimeA : lastFrameTimeB),
              snapshot.targetFrameTime == (snapshot.sourceSlot == .a ? lastFrameTimeB : lastFrameTimeA) else {
            Diagnostics.log("roi.align.discard stale")
            return
        }
        guard let result else {
            rejectROIAlignment("roi.align.fail no-match")
            return
        }

        beginPreviewUndoGroup()
        applyROIAlignment(snapshot: snapshot, result: result)
        commitPreviewUndoGroup()
        refreshStatus()
        Diagnostics.log("roi.align.applied slot=\(snapshot.sourceSlot.rawValue) score=\(String(format: "%.3f", result.score)) scale=\(String(format: "%.3f", result.scale))")
    }

    private func applyROIAlignment(snapshot: ROIAlignmentSnapshot, result: ROIAlignmentResult) {
        var sourceTransform = snapshot.sourceTransform
        var targetTransform = snapshot.targetTransform
        let sourceSize = Self.pixelBufferSize(snapshot.sourcePixelBuffer)
        let targetSize = Self.pixelBufferSize(snapshot.targetPixelBuffer)
        let sourceFit = Self.fitScale(sourceSize: sourceSize, contentRect: snapshot.contentRect)
        let targetFit = Self.fitScale(sourceSize: targetSize, contentRect: snapshot.contentRect)
        let sourceScreenWidth = result.sourceRect.width * sourceFit * pow(2.0, sourceTransform.zoom)
        let sourceScreenHeight = result.sourceRect.height * sourceFit * pow(2.0, sourceTransform.zoom)
        let targetScreenWidth = result.targetRect.width * targetFit * pow(2.0, targetTransform.zoom)
        let targetScreenHeight = result.targetRect.height * targetFit * pow(2.0, targetTransform.zoom)
        let widthRatio = targetScreenWidth / max(1, sourceScreenWidth)
        let heightRatio = targetScreenHeight / max(1, sourceScreenHeight)
        let ratio = sqrt(max(0.01, widthRatio * heightRatio))
        let zoomDelta = max(-0.2, min(0.2, log2(ratio) / 2))
        sourceTransform.zoom += zoomDelta
        targetTransform.zoom -= zoomDelta

        sourceTransform = Self.transformCentering(
            point: CGPoint(x: result.sourceRect.midX, y: result.sourceRect.midY),
            pixelBuffer: snapshot.sourcePixelBuffer,
            contentRect: snapshot.contentRect,
            transform: sourceTransform
        )
        targetTransform = Self.transformCentering(
            point: CGPoint(x: result.targetRect.midX, y: result.targetRect.midY),
            pixelBuffer: snapshot.targetPixelBuffer,
            contentRect: snapshot.contentRect,
            transform: targetTransform
        )

        switch snapshot.sourceSlot {
        case .a:
            syncState.transformA = sourceTransform
            syncState.transformB = targetTransform
        case .b:
            syncState.transformB = sourceTransform
            syncState.transformA = targetTransform
        }
        canvas.wipeFraction = 0.5
        canvas.renderer.wipeFraction = 0.5
        canvas.needsLayout = true
        canvas.layoutSubtreeIfNeeded()
        canvas.renderer.transformA = syncState.transformA
        canvas.renderer.transformB = syncState.transformB
        playerA.applyTransform(syncState.transformA)
        playerB.applyTransform(syncState.transformB)
    }

    nonisolated private static func computeROIAlignment(snapshot: ROIAlignmentSnapshot) -> ROIAlignmentResult? {
        guard let sourceRect = pixelRect(
            fromCanvasRect: snapshot.sourceCanvasRect,
            pixelBuffer: snapshot.sourcePixelBuffer,
            transform: snapshot.sourceTransform,
            contentRect: snapshot.contentRect
        ) else {
            Diagnostics.log("roi.align.fail source-rect")
            return nil
        }
        guard sourceRect.width >= 24, sourceRect.height >= 24 else {
            Diagnostics.log("roi.align.fail source-rect-small")
            return nil
        }
        guard let target = makeFullGrayImage(pixelBuffer: snapshot.targetPixelBuffer, maxLongSide: 640) else {
            Diagnostics.log("roi.align.fail target-gray")
            return nil
        }

        let expectedTargetRect = pixelRect(
            fromCanvasRect: snapshot.sourceCanvasRect,
            pixelBuffer: snapshot.targetPixelBuffer,
            transform: snapshot.targetTransform,
            contentRect: snapshot.contentRect
        )
        let targetScale = CGFloat(target.width) / max(1, CGFloat(CVPixelBufferGetWidth(snapshot.targetPixelBuffer)))
        let scaleCandidates = [0.80, 0.86, 0.92, 0.98, 1.04, 1.10, 1.17, 1.25]
        var best: TemplateMatchResult?
        for candidateScale in scaleCandidates {
            let templateWidth = Int((sourceRect.width * targetScale * candidateScale).rounded())
            let templateHeight = Int((sourceRect.height * targetScale * candidateScale).rounded())
            guard templateWidth >= 18, templateHeight >= 18,
                  templateWidth < target.width,
                  templateHeight < target.height,
                  let template = makeGrayPatch(
                    pixelBuffer: snapshot.sourcePixelBuffer,
                    sourceRect: sourceRect,
                    outputWidth: templateWidth,
                    outputHeight: templateHeight
                  ) else { continue }
            let searchRect = expectedTargetRect.map {
                scaledSearchRect(expectedRect: $0, targetScale: targetScale, target: target, templateWidth: templateWidth, templateHeight: templateHeight)
            }
            guard let match = matchTemplate(template: template, target: target, targetScale: targetScale, scale: candidateScale, searchRect: searchRect) else {
                continue
            }
            if best == nil || match.score > best!.score {
                best = match
            }
        }

        guard let best, best.score >= 0.58 else {
            Diagnostics.log("roi.align.fail score=\(String(format: "%.3f", best?.score ?? 0))")
            return nil
        }
        return ROIAlignmentResult(sourceRect: sourceRect, targetRect: best.targetRect, score: best.score, scale: best.scale)
    }

    nonisolated private static func scaledSearchRect(expectedRect: CGRect, targetScale: CGFloat, target: GrayImage, templateWidth: Int, templateHeight: Int) -> CGRect {
        let scaled = CGRect(
            x: expectedRect.minX * targetScale,
            y: expectedRect.minY * targetScale,
            width: expectedRect.width * targetScale,
            height: expectedRect.height * targetScale
        )
        let marginX = max(CGFloat(templateWidth) * 4.0, CGFloat(target.width) * 0.14)
        let marginY = max(CGFloat(templateHeight) * 4.0, CGFloat(target.height) * 0.14)
        return scaled.insetBy(dx: -marginX, dy: -marginY)
    }

    nonisolated private static func pixelBufferSize(_ pixelBuffer: CVPixelBuffer) -> CGSize {
        CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    }

    nonisolated private static func fitScale(sourceSize: CGSize, contentRect: CGRect) -> CGFloat {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return 1 }
        return min(contentRect.width / sourceSize.width, contentRect.height / sourceSize.height)
    }

    nonisolated private static func displayedVideoRect(pixelBuffer: CVPixelBuffer, transform: TransformState, contentRect: CGRect) -> CGRect {
        let sourceSize = pixelBufferSize(pixelBuffer)
        let fit = fitScale(sourceSize: sourceSize, contentRect: contentRect)
        let finalScale = fit * CGFloat(pow(2.0, transform.zoom))
        let videoSize = CGSize(width: sourceSize.width * finalScale, height: sourceSize.height * finalScale)
        return CGRect(
            x: contentRect.midX - videoSize.width / 2 + CGFloat(transform.panX) * contentRect.width / 2,
            y: contentRect.midY - videoSize.height / 2 + CGFloat(transform.panY) * contentRect.height / 2,
            width: videoSize.width,
            height: videoSize.height
        )
    }

    nonisolated private static func pixelRect(fromCanvasRect canvasRect: CGRect, pixelBuffer: CVPixelBuffer, transform: TransformState, contentRect: CGRect) -> CGRect? {
        let videoRect = displayedVideoRect(pixelBuffer: pixelBuffer, transform: transform, contentRect: contentRect)
        let clipped = canvasRect.intersection(videoRect).intersection(contentRect)
        guard !clipped.isNull, clipped.width > 1, clipped.height > 1, canvasRect.width > 1, canvasRect.height > 1 else {
            return nil
        }
        let coverage = (clipped.width * clipped.height) / max(1, canvasRect.width * canvasRect.height)
        guard coverage >= 0.70 else { return nil }

        let sourceWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let x0 = (clipped.minX - videoRect.minX) / max(1, videoRect.width) * sourceWidth
        let x1 = (clipped.maxX - videoRect.minX) / max(1, videoRect.width) * sourceWidth
        let y0 = (clipped.minY - videoRect.minY) / max(1, videoRect.height) * sourceHeight
        let y1 = (clipped.maxY - videoRect.minY) / max(1, videoRect.height) * sourceHeight
        let rect = CGRect(
            x: max(0, min(sourceWidth - 1, min(x0, x1))),
            y: max(0, min(sourceHeight - 1, min(y0, y1))),
            width: max(1, min(sourceWidth, max(x0, x1)) - max(0, min(x0, x1))),
            height: max(1, min(sourceHeight, max(y0, y1)) - max(0, min(y0, y1)))
        )
        return rect.width >= 1 && rect.height >= 1 ? rect : nil
    }

    nonisolated private static func transformCentering(point: CGPoint, pixelBuffer: CVPixelBuffer, contentRect: CGRect, transform: TransformState) -> TransformState {
        var result = transform
        let videoRect = displayedVideoRect(pixelBuffer: pixelBuffer, transform: result, contentRect: contentRect)
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard sourceWidth > 0, sourceHeight > 0, videoRect.width > 0, videoRect.height > 0 else { return result }
        let scaleX = videoRect.width / sourceWidth
        let scaleY = videoRect.height / sourceHeight
        let baseX = contentRect.midX - videoRect.width / 2
        let baseY = contentRect.midY - videoRect.height / 2
        result.panX = Double((contentRect.midX - (baseX + point.x * scaleX)) * 2 / max(1, contentRect.width))
        result.panY = Double((contentRect.midY - (baseY + point.y * scaleY)) * 2 / max(1, contentRect.height))
        return result
    }

    nonisolated private static func makeFullGrayImage(pixelBuffer: CVPixelBuffer, maxLongSide: Int) -> GrayImage? {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let scale = min(1, Double(maxLongSide) / Double(max(sourceWidth, sourceHeight)))
        let width = max(2, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(2, Int((Double(sourceHeight) * scale).rounded()))
        return makeGrayPatch(
            pixelBuffer: pixelBuffer,
            sourceRect: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
            outputWidth: width,
            outputHeight: height
        )
    }

    nonisolated private static func makeGrayPatch(pixelBuffer: CVPixelBuffer, sourceRect: CGRect, outputWidth: Int, outputHeight: Int) -> GrayImage? {
        guard outputWidth > 1, outputHeight > 1 else { return nil }
        let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockResult == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        var pixels = Array(repeating: Float(0), count: outputWidth * outputHeight)
        for y in 0..<outputHeight {
            let fy = sourceRect.minY + (CGFloat(y) + 0.5) / CGFloat(outputHeight) * sourceRect.height
            for x in 0..<outputWidth {
                let fx = sourceRect.minX + (CGFloat(x) + 0.5) / CGFloat(outputWidth) * sourceRect.width
                pixels[y * outputWidth + x] = sampleLumaLocked(pixelBuffer: pixelBuffer, x: fx, y: fy)
            }
        }
        return GrayImage(width: outputWidth, height: outputHeight, pixels: pixels)
    }

    nonisolated private static func sampleLumaLocked(pixelBuffer: CVPixelBuffer, x: CGFloat, y: CGFloat) -> Float {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
           let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let planeWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let planeHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let px = min(max(0, Int(x.rounded(.down))), max(0, planeWidth - 1))
            let py = min(max(0, Int(y.rounded(.down))), max(0, planeHeight - 1))
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            if pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange {
                let pointer = base.assumingMemoryBound(to: UInt16.self)
                let rowStride = max(1, bytesPerRow / MemoryLayout<UInt16>.stride)
                let raw = pointer[py * rowStride + px]
                let tenBit = raw > 1023 ? raw >> 6 : raw
                return Float(normalizedVideoLuma(Double(tenBit), maxValue: 1023, fullRange: pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange))
            }
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            return Float(normalizedVideoLuma(Double(pointer[py * bytesPerRow + px]), maxValue: 255, fullRange: pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let px = min(max(0, Int(x.rounded(.down))), max(0, width - 1))
        let py = min(max(0, Int(y.rounded(.down))), max(0, height - 1))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let offset = py * bytesPerRow + px * 4
        let b = Double(pointer[offset]) / 255.0
        let g = Double(pointer[offset + 1]) / 255.0
        let r = Double(pointer[offset + 2]) / 255.0
        return Float(r * 0.2126 + g * 0.7152 + b * 0.0722)
    }

    nonisolated private static func matchTemplate(template: GrayImage, target: GrayImage, targetScale: CGFloat, scale: Double, searchRect: CGRect?) -> TemplateMatchResult? {
        guard template.width >= 8, template.height >= 8,
              template.width < target.width, template.height < target.height else { return nil }
        let samplesX = min(56, max(12, template.width / 2))
        let samplesY = min(56, max(12, template.height / 2))
        var offsets: [(x: Int, y: Int)] = []
        var templateValues: [Float] = []
        offsets.reserveCapacity(samplesX * samplesY)
        templateValues.reserveCapacity(samplesX * samplesY)
        for sy in 0..<samplesY {
            let y = samplesY == 1 ? template.height / 2 : min(template.height - 1, Int((Double(sy) / Double(samplesY - 1)) * Double(template.height - 1)))
            for sx in 0..<samplesX {
                let x = samplesX == 1 ? template.width / 2 : min(template.width - 1, Int((Double(sx) / Double(samplesX - 1)) * Double(template.width - 1)))
                offsets.append((x, y))
                templateValues.append(template[x, y])
            }
        }
        let stats = sampleStats(templateValues)
        guard stats.std >= 0.035 else {
            Diagnostics.log("roi.align.fail low-texture std=\(String(format: "%.4f", stats.std))")
            return nil
        }

        func score(at originX: Int, _ originY: Int) -> Double {
            var targetSum = 0.0
            for offset in offsets {
                targetSum += Double(target[originX + offset.x, originY + offset.y])
            }
            let targetMean = targetSum / Double(offsets.count)
            var numerator = 0.0
            var targetVariance = 0.0
            for index in offsets.indices {
                let value = Double(target[originX + offsets[index].x, originY + offsets[index].y])
                let td = Double(templateValues[index]) - stats.mean
                let vd = value - targetMean
                numerator += td * vd
                targetVariance += vd * vd
            }
            guard targetVariance > 0.000001 else { return -1 }
            return numerator / sqrt(stats.variance * targetVariance)
        }

        let maxX = target.width - template.width
        let maxY = target.height - template.height
        let searchBounds = searchBounds(searchRect: searchRect, maxX: maxX, maxY: maxY)
        let coarseStep = max(4, min(template.width, template.height) / 12)
        var bestX = searchBounds.minX
        var bestY = searchBounds.minY
        var bestScore = -Double.infinity
        for y in strideValues(from: searchBounds.minY, through: searchBounds.maxY, by: coarseStep) {
            for x in strideValues(from: searchBounds.minX, through: searchBounds.maxX, by: coarseStep) {
                let current = score(at: x, y)
                if current > bestScore {
                    bestScore = current
                    bestX = x
                    bestY = y
                }
            }
        }

        let refineStep = max(1, coarseStep / 4)
        let refineRadius = coarseStep
        let startY = max(searchBounds.minY, bestY - refineRadius)
        let endY = min(searchBounds.maxY, bestY + refineRadius)
        let startX = max(searchBounds.minX, bestX - refineRadius)
        let endX = min(searchBounds.maxX, bestX + refineRadius)
        for y in strideValues(from: startY, through: endY, by: refineStep) {
            for x in strideValues(from: startX, through: endX, by: refineStep) {
                let current = score(at: x, y)
                if current > bestScore {
                    bestScore = current
                    bestX = x
                    bestY = y
                }
            }
        }

        guard bestScore.isFinite else { return nil }
        let inverseScale = 1 / max(0.0001, targetScale)
        let rect = CGRect(
            x: CGFloat(bestX) * inverseScale,
            y: CGFloat(bestY) * inverseScale,
            width: CGFloat(template.width) * inverseScale,
            height: CGFloat(template.height) * inverseScale
        )
        return TemplateMatchResult(targetRect: rect, score: bestScore, scale: scale)
    }

    nonisolated private static func searchBounds(searchRect: CGRect?, maxX: Int, maxY: Int) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        guard let searchRect, !searchRect.isNull, searchRect.width > 1, searchRect.height > 1 else {
            return (0, maxX, 0, maxY)
        }
        let minX = min(maxX, max(0, Int(searchRect.minX.rounded(.down))))
        let maxSearchX = min(maxX, max(0, Int(searchRect.maxX.rounded(.up))))
        let minY = min(maxY, max(0, Int(searchRect.minY.rounded(.down))))
        let maxSearchY = min(maxY, max(0, Int(searchRect.maxY.rounded(.up))))
        guard minX <= maxSearchX, minY <= maxSearchY else {
            return (0, maxX, 0, maxY)
        }
        return (minX, maxSearchX, minY, maxSearchY)
    }

    nonisolated private static func strideValues(from start: Int, through end: Int, by step: Int) -> [Int] {
        guard start <= end else { return [] }
        let step = max(1, step)
        var values = Array(stride(from: start, through: end, by: step))
        if values.last != end {
            values.append(end)
        }
        return values
    }

    nonisolated private static func sampleStats(_ values: [Float]) -> (mean: Double, variance: Double, std: Double) {
        guard !values.isEmpty else { return (0, 0, 0) }
        let mean = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        let variance = max(0, values.reduce(0.0) { partial, value in
            let d = Double(value) - mean
            return partial + d * d
        })
        return (mean, variance, sqrt(variance / Double(values.count)))
    }

    private func colorAdjustment(for slot: VideoSlot?) -> ColorAdjustmentState {
        switch slot {
        case .a: colorAdjustmentA
        case .b: colorAdjustmentB
        case nil: ColorAdjustmentState()
        }
    }

    private func histogram(for slot: VideoSlot?) -> ColorHistogram {
        switch slot {
        case .a: colorHistogramA
        case .b: colorHistogramB
        case nil: ColorHistogram.empty
        }
    }

    private func isRawImageLoaded(in slot: VideoSlot?) -> Bool {
        switch slot {
        case .a:
            guard let url = playerA.fileURL else { return false }
            return MediaFileSupport.isRawImage(url)
        case .b:
            guard let url = playerB.fileURL else { return false }
            return MediaFileSupport.isRawImage(url)
        case nil:
            return false
        }
    }

    private func canWhiteBalanceLoaded(in slot: VideoSlot?) -> Bool {
        guard let slot else { return false }
        return pixelBuffer(for: slot) != nil
    }

    private func refreshColorAdjustmentPanel() {
        let isRawImage = isRawImageLoaded(in: selectedSlot)
        if let selectedSlot {
            refreshHistogramForCurrentFrame(slot: selectedSlot)
        }
        guard let colorAdjustmentPanel else { return }
        colorAdjustmentPanel.update(
            slot: selectedSlot,
            state: colorAdjustment(for: selectedSlot),
            histogram: histogram(for: selectedSlot),
            isRawImage: isRawImage,
            canWhiteBalance: canWhiteBalanceLoaded(in: selectedSlot)
        )
    }

    private func updateHistogramIfNeeded(slot: VideoSlot, pixelBuffer: CVPixelBuffer) {
        guard selectedSlot == slot,
              let colorAdjustmentPanel,
              colorAdjustmentPanel.window?.isVisible == true else { return }
        let now = CACurrentMediaTime()
        guard now - lastHistogramUpdate >= 0.18 else { return }
        lastHistogramUpdate = now
        scheduleHistogramSample(slot: slot, pixelBuffer: pixelBuffer, updatePanelState: false)
    }

    private func refreshHistogramForCurrentFrame(slot: VideoSlot) {
        guard selectedSlot == slot,
              colorAdjustmentPanel?.window?.isVisible == true else { return }
        let pixelBuffer = slot == .a ? lastPixelBufferA : lastPixelBufferB
        guard let pixelBuffer else { return }
        scheduleHistogramSample(slot: slot, pixelBuffer: pixelBuffer, updatePanelState: true)
    }

    private func scheduleHistogramSample(slot: VideoSlot, pixelBuffer: CVPixelBuffer, updatePanelState: Bool) {
        colorHistogramGeneration += 1
        let generation = colorHistogramGeneration
        let adjustment = rendererColorAdjustment(for: slot)
        colorHistogramWorker.sample(slot: slot, generation: generation, pixelBuffer: pixelBuffer, adjustment: adjustment) { [weak self] result in
            guard let self,
                  result.generation == self.colorHistogramGeneration,
                  self.selectedSlot == result.slot,
                  self.colorAdjustmentPanel?.window?.isVisible == true else { return }
            switch result.slot {
            case .a: self.colorHistogramA = result.histogram
            case .b: self.colorHistogramB = result.histogram
            }
            if updatePanelState {
                self.colorAdjustmentPanel?.update(
                    slot: self.selectedSlot,
                    state: self.colorAdjustment(for: self.selectedSlot),
                    histogram: self.histogram(for: self.selectedSlot),
                    isRawImage: self.isRawImageLoaded(in: self.selectedSlot),
                    canWhiteBalance: self.canWhiteBalanceLoaded(in: self.selectedSlot)
                )
            } else {
                self.colorAdjustmentPanel?.updateHistogram(result.histogram)
            }
        }
    }

    nonisolated private static func sampleRGB(pixelBuffer: CVPixelBuffer, center: CGPoint, radius: Int) -> WhiteBalanceSolver.RGBSample? {
        let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockResult == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        let centerX = min(width - 1, max(0, Int(center.x.rounded())))
        let centerY = min(height - 1, max(0, Int(center.y.rounded())))
        let xRange = max(0, centerX - radius)...min(width - 1, centerX + radius)
        let yRange = max(0, centerY - radius)...min(height - 1, centerY + radius)
        var red: [Double] = []
        var green: [Double] = []
        var blue: [Double] = []
        let sampleCapacity = xRange.count * yRange.count
        red.reserveCapacity(sampleCapacity)
        green.reserveCapacity(sampleCapacity)
        blue.reserveCapacity(sampleCapacity)

        func append(r: Double, g: Double, b: Double) {
            red.append(r)
            green.append(g)
            blue.append(b)
        }

        if CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
           let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            if pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange {
                let pointer = base.assumingMemoryBound(to: UInt16.self)
                let rowStride = max(1, bytesPerRow / MemoryLayout<UInt16>.stride)
                for y in yRange {
                    for x in xRange {
                        let raw = pointer[y * rowStride + x]
                        let tenBit = raw > 1023 ? raw >> 6 : raw
                        let yValue = normalizedVideoLuma(Double(tenBit), maxValue: 1023, fullRange: pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
                        let uv = sampleUV(pixelBuffer: pixelBuffer, sourceX: x, sourceY: y, is10Bit: true, fullRange: pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
                        let rgb = yuvToRGB(y: yValue, cb: uv.cb, cr: uv.cr)
                        append(r: rgb.r, g: rgb.g, b: rgb.b)
                    }
                }
            } else {
                let pointer = base.assumingMemoryBound(to: UInt8.self)
                for y in yRange {
                    for x in xRange {
                        let yValue = normalizedVideoLuma(Double(pointer[y * bytesPerRow + x]), maxValue: 255, fullRange: pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                        let uv = sampleUV(pixelBuffer: pixelBuffer, sourceX: x, sourceY: y, is10Bit: false, fullRange: pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                        let rgb = yuvToRGB(y: yValue, cb: uv.cb, cr: uv.cr)
                        append(r: rgb.r, g: rgb.g, b: rgb.b)
                    }
                }
            }
        } else if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            for y in yRange {
                for x in xRange {
                    let offset = y * bytesPerRow + x * 4
                    append(
                        r: Double(pointer[offset + 2]) / 255.0,
                        g: Double(pointer[offset + 1]) / 255.0,
                        b: Double(pointer[offset]) / 255.0
                    )
                }
            }
        }

        guard red.count >= 9 else { return nil }
        return WhiteBalanceSolver.RGBSample(
            r: trimmedMean(red),
            g: trimmedMean(green),
            b: trimmedMean(blue)
        )
    }

    nonisolated private static func trimmedMean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let trim = min(sorted.count / 5, max(0, (sorted.count - 1) / 2))
        let kept = sorted[trim..<(sorted.count - trim)]
        return kept.reduce(0, +) / Double(kept.count)
    }

    nonisolated private static func sampleColorHistogram(pixelBuffer: CVPixelBuffer, adjustment: ColorAdjustmentState) -> ColorHistogram {
        let binCount = ColorAdjustmentState.histogramBinCount
        var red = Array(repeating: 0.0, count: binCount)
        var green = Array(repeating: 0.0, count: binCount)
        var blue = Array(repeating: 0.0, count: binCount)
        let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockResult == kCVReturnSuccess else { return .empty }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return .empty }
        let stepX = max(1, width / 181)
        let stepY = max(1, height / 102)
        var samples = 0.0

        func addRGB(r: Double, g: Double, b: Double) {
            let adjusted = adjustedRGB(r: r, g: g, b: b, adjustment: adjustment)
            let ri = min(binCount - 1, max(0, Int(adjusted.r * Double(binCount - 1))))
            let gi = min(binCount - 1, max(0, Int(adjusted.g * Double(binCount - 1))))
            let bi = min(binCount - 1, max(0, Int(adjusted.b * Double(binCount - 1))))
            red[ri] += 1
            green[gi] += 1
            blue[bi] += 1
            samples += 1
        }

        if CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
           let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let planeWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let planeHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            if pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange {
                let pointer = base.assumingMemoryBound(to: UInt16.self)
                let rowStride = max(1, bytesPerRow / MemoryLayout<UInt16>.stride)
                for y in stride(from: 0, to: planeHeight, by: max(1, stepY)) {
                    for x in stride(from: 0, to: planeWidth, by: max(1, stepX)) {
                        let raw = pointer[y * rowStride + x]
                        let tenBit = raw > 1023 ? raw >> 6 : raw
                        let yValue = Self.normalizedVideoLuma(Double(tenBit), maxValue: 1023, fullRange: pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
                        let uv = sampleUV(pixelBuffer: pixelBuffer, sourceX: x, sourceY: y, is10Bit: true, fullRange: pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
                        let rgb = yuvToRGB(y: yValue, cb: uv.cb, cr: uv.cr)
                        addRGB(r: rgb.r, g: rgb.g, b: rgb.b)
                    }
                }
            } else {
                let pointer = base.assumingMemoryBound(to: UInt8.self)
                for y in stride(from: 0, to: planeHeight, by: max(1, stepY)) {
                    for x in stride(from: 0, to: planeWidth, by: max(1, stepX)) {
                        let yValue = Self.normalizedVideoLuma(Double(pointer[y * bytesPerRow + x]), maxValue: 255, fullRange: pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                        let uv = sampleUV(pixelBuffer: pixelBuffer, sourceX: x, sourceY: y, is10Bit: false, fullRange: pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                        let rgb = yuvToRGB(y: yValue, cb: uv.cb, cr: uv.cr)
                        addRGB(r: rgb.r, g: rgb.g, b: rgb.b)
                    }
                }
            }
        } else if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            for y in stride(from: 0, to: height, by: stepY) {
                for x in stride(from: 0, to: width, by: stepX) {
                    let offset = y * bytesPerRow + x * 4
                    let b = Double(pointer[offset]) / 255.0
                    let g = Double(pointer[offset + 1]) / 255.0
                    let r = Double(pointer[offset + 2]) / 255.0
                    addRGB(r: r, g: g, b: b)
                }
            }
        }

        guard samples > 0 else { return .empty }
        return ColorHistogram(
            red: red.map { $0 / samples },
            green: green.map { $0 / samples },
            blue: blue.map { $0 / samples }
        )
    }

    nonisolated private static func normalizedVideoLuma(_ value: Double, maxValue: Double, fullRange: Bool) -> Double {
        if fullRange {
            return min(1, max(0, value / maxValue))
        }
        if maxValue > 255 {
            return min(1, max(0, (value - 64) / 876))
        }
        return min(1, max(0, (value - 16) / 219))
    }

    nonisolated private static func sampleUV(pixelBuffer: CVPixelBuffer, sourceX: Int, sourceY: Int, is10Bit: Bool, fullRange: Bool) -> (cb: Double, cr: Double) {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return (0, 0)
        }
        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        guard uvWidth > 0, uvHeight > 0 else { return (0, 0) }
        let uvX = min(max(0, sourceX / 2), max(0, uvWidth - 1)) * 2
        let uvY = min(max(0, sourceY / 2), max(0, uvHeight - 1))
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        if is10Bit {
            let pointer = base.assumingMemoryBound(to: UInt16.self)
            let rowStride = max(1, bytesPerRow / MemoryLayout<UInt16>.stride)
            let rawCb = pointer[uvY * rowStride + uvX]
            let rawCr = pointer[uvY * rowStride + uvX + 1]
            let cb10 = Double(rawCb > 1023 ? rawCb >> 6 : rawCb)
            let cr10 = Double(rawCr > 1023 ? rawCr >> 6 : rawCr)
            if fullRange {
                return (cb10 / 1023 - 0.5, cr10 / 1023 - 0.5)
            }
            return ((cb10 - 512) / 896, (cr10 - 512) / 896)
        }

        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let rawCb = Double(pointer[uvY * bytesPerRow + uvX])
        let rawCr = Double(pointer[uvY * bytesPerRow + uvX + 1])
        if fullRange {
            return (rawCb / 255 - 0.5, rawCr / 255 - 0.5)
        }
        return ((rawCb - 128) / 224, (rawCr - 128) / 224)
    }

    nonisolated private static func yuvToRGB(y: Double, cb: Double, cr: Double) -> (r: Double, g: Double, b: Double) {
        (
            clamp01(y + 1.5748 * cr),
            clamp01(y - 0.1873 * cb - 0.4681 * cr),
            clamp01(y + 1.8556 * cb)
        )
    }

    nonisolated private static func adjustedRGB(r: Double, g: Double, b: Double, adjustment: ColorAdjustmentState) -> (r: Double, g: Double, b: Double) {
        guard adjustment.isEnabled else {
            return (clamp01(r), clamp01(g), clamp01(b))
        }

        var r = r * pow(2, adjustment.exposure) + adjustment.brightness * 0.35
        var g = g * pow(2, adjustment.exposure) + adjustment.brightness * 0.35
        var b = b * pow(2, adjustment.exposure) + adjustment.brightness * 0.35

        let contrast = 1 + adjustment.contrast * 1.5
        r = (r - 0.5) * contrast + 0.5
        g = (g - 0.5) * contrast + 0.5
        b = (b - 0.5) * contrast + 0.5

        r += adjustment.temperature * 0.08 + adjustment.tint * 0.03
        g -= adjustment.tint * 0.06
        b -= adjustment.temperature * 0.08 - adjustment.tint * 0.03

        let luma = r * 0.2126 + g * 0.7152 + b * 0.0722
        let saturation = 1 + adjustment.saturation
        r = luma + (r - luma) * saturation
        g = luma + (g - luma) * saturation
        b = luma + (b - luma) * saturation

        let adjustedLuma = r * 0.2126 + g * 0.7152 + b * 0.0722
        let mappedLuma = ToneCurveState.sampleLUT(adjustment.toneCurveLUT, input: adjustedLuma)
        if adjustedLuma < 0.0001 {
            r = mappedLuma
            g = mappedLuma
            b = mappedLuma
        } else {
            let scale = mappedLuma / adjustedLuma
            r *= scale
            g *= scale
            b *= scale
        }

        return (clamp01(r), clamp01(g), clamp01(b))
    }

    nonisolated private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private func adjustTransform(dx: Double, dy: Double, dz: Double) {
        guard let selectedSlot else { return }
        adjustTransform(slot: selectedSlot, dx: dx, dy: dy, dz: dz)
    }

    private func adjustTransform(slot: VideoSlot, dx: Double, dy: Double, dz: Double) {
        adjustTransform(slot: slot, dx: dx, dy: dy, dz: dz, anchor: nil)
    }

    private func adjustTransform(slot: VideoSlot, dx: Double, dy: Double, dz: Double, anchor: CGPoint?) {
        guard canvas.allowsAlignmentAdjustment else { return }
        if slot == .a {
            syncState.transformA.panX += dx
            syncState.transformA.panY += dy
            applyZoom(dz, to: &syncState.transformA, slot: slot, anchor: anchor)
            canvas.renderer.transformA = syncState.transformA
            playerA.applyTransform(syncState.transformA)
        } else {
            syncState.transformB.panX += dx
            syncState.transformB.panY += dy
            applyZoom(dz, to: &syncState.transformB, slot: slot, anchor: anchor)
            canvas.renderer.transformB = syncState.transformB
            playerB.applyTransform(syncState.transformB)
        }
    }

    private func applyZoom(_ dz: Double, to transform: inout TransformState, slot: VideoSlot, anchor: CGPoint?) {
        guard dz != 0 else { return }
        guard let anchor else {
            transform.zoom += dz
            return
        }
        let rect = canvas.videoRect(for: slot)
        guard rect.width > 0, rect.height > 0 else {
            transform.zoom += dz
            return
        }
        let zoomRatio = CGFloat(pow(2.0, dz))
        let oldCenter = CGPoint(
            x: rect.midX + CGFloat(transform.panX) * rect.width / 2,
            y: rect.midY + CGFloat(transform.panY) * rect.height / 2
        )
        let anchorPoint = CGPoint(
            x: rect.minX + anchor.x * rect.width,
            y: rect.minY + anchor.y * rect.height
        )
        let newCenter = CGPoint(
            x: zoomRatio * oldCenter.x + (1 - zoomRatio) * anchorPoint.x,
            y: zoomRatio * oldCenter.y + (1 - zoomRatio) * anchorPoint.y
        )
        transform.panX = Double((newCenter.x - rect.midX) * 2 / rect.width)
        transform.panY = Double((newCenter.y - rect.midY) * 2 / rect.height)
        transform.zoom += dz
    }

    @objc private func resetTransform() {
        guard canvas.allowsAlignmentAdjustment, let slot = selectedSlot else { return }
        beginPreviewUndoGroup()
        if slot == .a {
            syncState.transformA = TransformState()
            canvas.renderer.transformA = syncState.transformA
            playerA.applyTransform(syncState.transformA)
        } else {
            syncState.transformB = TransformState()
            canvas.renderer.transformB = syncState.transformB
            playerB.applyTransform(syncState.transformB)
        }
        commitPreviewUndoGroup()
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
        ensureMainWindowVisible()
        load(url: URL(fileURLWithPath: paths[0]), slot: .a)
        load(url: URL(fileURLWithPath: paths[1]), slot: .b)
    }

    private func ensureMainWindowVisible() {
        guard let window else { return }
        if !window.isVisible {
            showWindow(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        updateFrameNumberOverlays()
        let synchronizedPlaying = isSynchronizedPlaying || (!playerA.isPaused && !playerB.isPaused)
        syncTimeline.setPlaying(synchronizedPlaying)
        videoATimeline.setPlaying(canvas.allowsAlignmentAdjustment ? synchronizedPlaying : !playerA.isPaused)
        videoBTimeline.setPlaying(canvas.allowsAlignmentAdjustment ? synchronizedPlaying : !playerB.isPaused)
        let staticState = (a: playerA.isStaticImage, b: playerB.isStaticImage)
        if staticState != lastTimelineStaticState {
            lastTimelineStaticState = staticState
            layoutContent(animated: false)
        }
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

    private func updateFrameNumberOverlays() {
        canvas.setFrameNumber(
            playerA.fileURL == nil ? nil : "Frame \(frameNumber(playerA.timePosition, fps: playerA.fps))",
            slot: .a,
            visible: showsFrameNumbers
        )
        canvas.setFrameNumber(
            playerB.fileURL == nil ? nil : "Frame \(frameNumber(playerB.timePosition, fps: playerB.fps))",
            slot: .b,
            visible: showsFrameNumbers
        )
    }

    private func toggleFrameNumbers() {
        showsFrameNumbers.toggle()
        updateFrameNumberOverlays()
        canvas.setFrameNumberOverlayVisible(showsFrameNumbers)
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
        cancelLoopSeekState(reason: "start")
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
                seekLoopStartAndResume(token: token, loopRange: loopRange, reason: "clamp")
                return
            }
        }
        scheduleSynchronizedFrame(token: token)
    }

    private func stopSynchronizedBarrierPlayback() {
        cancelLoopSeekState(reason: "stop")
        guard isSynchronizedPlaying else { return }
        isSynchronizedPlaying = false
        synchronizedPlaybackToken += 1
        Diagnostics.log("sync.play.stop token=\(synchronizedPlaybackToken)")
        debugTimelineState("sync.play.stop")
        playerA.setSynchronizedPlaybackActive(false)
        playerB.setSynchronizedPlaybackActive(false)
    }

    private func scheduleSynchronizedFrame(token: Int) {
        guard isSynchronizedPlaying, token == synchronizedPlaybackToken, !loopSeekInProgress else { return }
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
                self.seekLoopStartAndResume(token: token, loopRange: loopRange, reason: "upper")
                return
            }

            if let frameA {
                self.playerA.setVideoVisible(true)
                self.playerA.presentSynchronizedFrame(frameA)
            } else {
                self.playerA.setVideoVisible(self.playerA.fileURL != nil)
            }

            if let frameB {
                self.playerB.setVideoVisible(true)
                self.playerB.presentSynchronizedFrame(frameB)
            } else {
                self.playerB.setVideoVisible(self.playerB.fileURL != nil)
            }

            if frameA == nil && frameB == nil {
                if let loopRange = self.syncLoopRange {
                    Diagnostics.log("sync.loop.wrap token=\(token) reason=eof loop=\(self.debugRange(self.syncLoopRange))")
                    self.seekLoopStartAndResume(token: token, loopRange: loopRange, reason: "eof")
                    return
                }
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

        let base = currentBaseTime()
        if shouldDecodeSynchronizedFrame(slot: .a, base: base) {
            playerA.decodeNextFrameForSynchronization { frame in
                frameA = frame
                finishIfReady()
            }
        } else {
            finishIfReady()
        }
        if shouldDecodeSynchronizedFrame(slot: .b, base: base) {
            playerB.decodeNextFrameForSynchronization { frame in
                frameB = frame
                finishIfReady()
            }
        } else {
            finishIfReady()
        }
    }

    private func seekLoopStartAndResume(token: Int, loopRange: ClosedRange<Double>, reason: String) {
        guard isSynchronizedPlaying, token == synchronizedPlaybackToken, !loopSeekInProgress else { return }
        loopSeekInProgress = true
        loopSeekGeneration += 1
        let seekGeneration = loopSeekGeneration
        let canUsePreviewPlayback = hasCompleteLoopPreview(loopRange: loopRange)
        let previewed = canUsePreviewPlayback && presentLoopStartPreview(loopRange: loopRange)
        if previewed {
            playLoopPreviewFramesWhileSeeking(token: token, loopRange: loopRange)
        }
        Diagnostics.log("sync.loop.seekStart token=\(token) generation=\(seekGeneration) reason=\(reason) target=\(debugTime(loopRange.lowerBound)) previewed=\(previewed) loop=\(debugRange(syncLoopRange))")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loopSeekTimeout) { [weak self] in
            guard let self,
                  self.loopSeekInProgress,
                  self.loopSeekGeneration == seekGeneration,
                  self.isSynchronizedPlaying,
                  token == self.synchronizedPlaybackToken,
                  self.syncLoopRange != nil else {
                return
            }
            Diagnostics.log("sync.loop.seekTimeout token=\(token) generation=\(seekGeneration) target=\(self.debugTime(loopRange.lowerBound))")
            self.cancelLoopPreviewPlayback()
            self.loopSeekGeneration += 1
            self.loopSeekInProgress = false
            self.refreshStatus()
            self.scheduleSynchronizedFrame(token: token)
        }
        seekToBaseTime(loopRange.lowerBound, exact: true, allowCachedFrame: false, publishFrame: !previewed) { [weak self] ok in
            guard let self else { return }
            guard self.loopSeekGeneration == seekGeneration else {
                Diagnostics.log("sync.loop.seekComplete.stale token=\(token) generation=\(seekGeneration) ok=\(ok)")
                return
            }
            self.cancelLoopPreviewPlayback()
            self.loopSeekInProgress = false
            guard self.isSynchronizedPlaying,
                  token == self.synchronizedPlaybackToken,
                  self.syncLoopRange != nil else {
                return
            }
            Diagnostics.log("sync.loop.seekComplete token=\(token) ok=\(ok) base=\(self.debugTime(self.syncBaseTime)) loop=\(self.debugRange(self.syncLoopRange))")
            self.refreshStatus()
            guard ok else {
                self.stopSynchronizedBarrierPlayback()
                return
            }
            self.scheduleSynchronizedFrame(token: token)
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
        playerA.setVideoVisible(visualDisplayTime(for: playerA, at: aTime) != nil)
        playerB.setVideoVisible(visualDisplayTime(for: playerB, at: bTime) != nil)
    }

    private func saveState() {
        guard let pair = currentPair else { return }
        var persistedState = syncState
        persistedState.transformA = TransformState()
        persistedState.transformB = TransformState()
        PersistenceStore.shared.saveState(persistedState, for: pair)
    }

    private func showLoadError(slot: VideoSlot, message: String) {
        switch slot {
        case .a: canvas.containerA.showsPlaceholder = true
        case .b: canvas.containerB.showsPlaceholder = true
        }
        let alert = NSAlert()
        alert.messageText = "加载 \(slot.rawValue.uppercased()) 失败"
        alert.informativeText = message
        alert.runModal()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if mediaFileTrees.isPathEditing {
            if event.keyCode == 53 {
                _ = mediaFileTrees.endPathEditingIfNeeded()
                return true
            }
            return false
        }
        if event.keyCode == 53, isWhiteBalanceSampling {
            cancelWhiteBalanceSampling()
            return true
        }

        if let key = event.charactersIgnoringModifiers?.lowercased() {
            let commandOption = event.modifierFlags.contains(.command)
                && event.modifierFlags.contains(.option)
                && event.modifierFlags.intersection([.control]).isEmpty
            if commandOption, key == "c" {
                openColorAdjustmentPanel(nil)
                return true
            }

            let commandOnly = event.modifierFlags.contains(.command)
                && event.modifierFlags.intersection([.control, .option]).isEmpty
            if commandOnly {
                switch key {
                case "z":
                    if event.modifierFlags.contains(.shift) {
                        redoPreviewEdit()
                    } else {
                        undoPreviewEdit()
                    }
                    return true
                case "1":
                    applyLayout(.sideBySideHorizontal)
                    return true
                case "2":
                    applyLayout(.overlapWipe)
                    return true
                case "b":
                    toggleMediaFileTrees()
                    return true
                default:
                    break
                }
            }
        }

        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "1":
                selectedSlot = .a
                return true
            case "2":
                selectedSlot = .b
                return true
            case "f":
                toggleFrameNumbers()
                return true
            case "o":
                guard let selectedSlot else { return false }
                originalBypassSlot = selectedSlot
                canvas.renderer.originalBypassSlot = selectedSlot
                return true
            default:
                break
            }
        }

        switch event.keyCode {
        case 53:
            _ = mediaFileTrees.endPathEditingIfNeeded()
            selectedSlot = nil
            canvas.clearSelection()
            return true
        case 48:
            guard canvas.layoutMode == .overlapWipe else { return false }
            canvas.toggleWipeEdge()
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

    private func handleKeyUp(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "o" else { return false }
        originalBypassSlot = nil
        canvas.renderer.originalBypassSlot = nil
        return true
    }

    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        guard canvas.allowsAlignmentAdjustment,
              let content = window?.contentView else { return false }
        let point = content.convert(event.locationInWindow, from: nil)
        guard canvas.frame.contains(point) else { return false }
        let anchor = canvas.videoAnchor(at: canvas.convert(point, from: content))
        let relativeAnchor = anchor?.relativePoint ?? CGPoint(x: 0.5, y: 0.5)
        let rawDelta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        let dz = max(-0.25, min(0.25, Double(rawDelta) * 0.01))
        beginPreviewUndoGroup()
        if event.modifierFlags.contains(.command), let slot = anchor?.slot {
            if selectedSlot != slot {
                selectedSlot = slot
            }
            adjustTransform(slot: slot, dx: 0, dy: 0, dz: dz, anchor: relativeAnchor)
        } else {
            adjustTransform(slot: .a, dx: 0, dy: 0, dz: dz, anchor: relativeAnchor)
            adjustTransform(slot: .b, dx: 0, dy: 0, dz: dz, anchor: relativeAnchor)
        }
        schedulePreviewUndoCommit()
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
            videoBTimeline,
            fileTreeToggleButton,
            shortcutHelpPanel,
            mediaFileTrees
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
