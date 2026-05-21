import AppKit

final class DropVideoView: NSView {
    var slot: VideoSlot
    var onFileDropped: ((VideoSlot, URL) -> Void)?
    var onFilesDropped: ((VideoSlot, [URL]) -> Void)?
    var showsPlaceholder = true {
        didSet {
            placeholderLabel.isHidden = !showsPlaceholder
        }
    }
    private let placeholderLabel = NSTextField(labelWithString: "拖入视频/照片/文件夹")

    init(slot: VideoSlot) {
        self.slot = slot
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL, .URL, .init("NSFilenamesPboardType")])

        placeholderLabel.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        placeholderLabel.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        placeholderLabel.alignment = .center
        placeholderLabel.backgroundColor = .clear
        placeholderLabel.drawsBackground = false
        addSubview(placeholderLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = urls(from: sender)
        Diagnostics.log("drop slot=\(slot.rawValue) validItems=\(urls.count) paths=\(urls.map(\.path).joined(separator: " | "))")
        guard !urls.isEmpty else { return false }
        if urls.count == 1, let url = urls.first {
            onFileDropped?(slot, url)
        } else {
            onFilesDropped?(slot, Array(urls.prefix(2)))
        }
        return true
    }

    override func layout() {
        super.layout()
        let width = min(bounds.width - 24, 220)
        placeholderLabel.frame = NSRect(
            x: floor((bounds.width - width) / 2),
            y: floor((bounds.height - 28) / 2),
            width: max(0, width),
            height: 28
        )
    }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let pasteboard = sender.draggingPasteboard
        var urls: [URL] = []

        if let readURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            urls.append(contentsOf: readURLs)
        }

        if let filenames = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            urls.append(contentsOf: filenames.map { URL(fileURLWithPath: $0) })
        }

        if let items = pasteboard.pasteboardItems {
            urls.append(contentsOf: items.compactMap { item in
                guard let value = item.string(forType: .fileURL),
                      let url = URL(string: value) else { return nil }
                return url
            })
        }

        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory)
            let isValid = exists && (isDirectory.boolValue || MediaFileSupport.isSupported(standardized))
            guard isValid, seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }
}

private extension NSPasteboard.PasteboardType {
    static let URL = NSPasteboard.PasteboardType("public.url")
}

final class WipeDividerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        (superview as? VideoCanvasView)?.updateWipeFromWindowEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
        (superview as? VideoCanvasView)?.updateWipeFromWindowEvent(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 1, alpha: 0.95).setFill()
        NSBezierPath(rect: NSRect(x: floor(bounds.midX) - 1, y: 0, width: 2, height: bounds.height)).fill()

        let knob = NSRect(x: bounds.midX - 8, y: bounds.midY - 28, width: 16, height: 56)
        NSColor(calibratedWhite: 0.05, alpha: 0.65).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 8, yRadius: 8).fill()
        NSColor.white.setStroke()
        NSBezierPath(roundedRect: knob.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
    }
}

final class ROISelectionOverlayView: NSView {
    var selectionRect: NSRect? {
        didSet {
            isHidden = selectionRect == nil
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let selectionRect else { return }
        NSColor.systemYellow.withAlphaComponent(0.18).setFill()
        NSBezierPath(rect: selectionRect).fill()
        NSColor.systemYellow.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1.5
        path.stroke()
    }
}

final class VideoCanvasView: NSView {
    let containerA = DropVideoView(slot: .a)
    let containerB = DropVideoView(slot: .b)
    let renderer = MetalCompositeView()
    let labelA = NSTextField(labelWithString: "A: 未加载")
    let labelB = NSTextField(labelWithString: "B: 未加载")
    private let frameNumberA = NSTextField(labelWithString: "")
    private let frameNumberB = NSTextField(labelWithString: "")
    private let divider = WipeDividerView()
    private let roiOverlay = ROISelectionOverlayView()
    private let labelHeight: CGFloat = 0

    var layoutMode: CompareLayout = .sideBySideHorizontal {
        didSet { needsLayout = true }
    }
    var wipeFraction: CGFloat = 0.5 {
        didSet { needsLayout = true }
    }
    var onToggleChanged: (() -> Void)?
    var onWipeChanged: ((CGFloat) -> Void)?
    var onPanDragged: ((VideoSlot, CGFloat, CGFloat) -> Void)?
    var onZoomDragged: ((VideoSlot, CGFloat) -> Void)?
    var onAlignmentGestureEnded: (() -> Void)?
    var onROIAlignmentRequested: ((VideoSlot, NSRect) -> Void)?
    var onSelectionChanged: ((VideoSlot?) -> Void)?
    var selectedSlot: VideoSlot? {
        didSet {
            guard oldValue != selectedSlot else { return }
            updateSelectionAppearance()
            onSelectionChanged?(selectedSlot)
        }
    }
    private var isDraggingWipe = false
    private var isPanning = false
    private var isSelectingROI = false
    private var didPan = false
    private var lastDragPoint: NSPoint?
    private var panSlot: VideoSlot?
    private var roiStartPoint: NSPoint?
    private var roiSlot: VideoSlot?

    var allowsAlignmentAdjustment: Bool {
        layoutMode == .overlapWipe
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(renderer)
        addSubview(containerA)
        addSubview(containerB)
        addSubview(labelA)
        addSubview(labelB)
        addSubview(divider)
        addSubview(frameNumberA)
        addSubview(frameNumberB)
        addSubview(roiOverlay)
        for label in [labelA, labelB] {
            label.isHidden = true
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            label.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
            label.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
            label.drawsBackground = true
            label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        for label in [frameNumberA, frameNumberB] {
            label.isHidden = true
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
            label.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.70)
            label.drawsBackground = true
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.cornerRadius = 5
            label.layer?.masksToBounds = true
        }
        updateSelectionAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let b = bounds
        let oneLabel = labelHeight
        renderer.frame = b
        roiOverlay.frame = b
        var rectA = NSRect.zero
        var rectB = NSRect.zero
        switch layoutMode {
        case .sideBySideHorizontal:
            let leftWidth = floor(b.width / 2)
            containerA.isHidden = false
            containerB.isHidden = false
            divider.isHidden = true
            labelA.isHidden = true
            labelB.isHidden = true
            labelA.frame = NSRect(x: 0, y: 0, width: leftWidth, height: oneLabel)
            labelB.frame = NSRect(x: leftWidth + 1, y: 0, width: max(0, b.width - leftWidth - 1), height: oneLabel)
            containerA.frame = NSRect(x: 0, y: oneLabel, width: leftWidth, height: max(0, b.height - oneLabel))
            containerB.frame = NSRect(x: leftWidth + 1, y: oneLabel, width: max(0, b.width - leftWidth - 1), height: max(0, b.height - oneLabel))
            rectA = containerA.frame
            rectB = containerB.frame
        case .overlapWipe:
            labelA.isHidden = true
            labelB.isHidden = true
            labelA.alignment = .left
            labelB.alignment = .right
            labelA.frame = NSRect(x: 0, y: 0, width: floor(b.width / 2), height: oneLabel)
            labelB.frame = NSRect(x: floor(b.width / 2), y: 0, width: ceil(b.width / 2), height: oneLabel)
            let content = NSRect(x: 0, y: oneLabel, width: b.width, height: max(0, b.height - oneLabel))
            let width = max(0, min(content.width, content.width * wipeFraction))
            let leftRect = NSRect(x: content.minX, y: content.minY, width: width, height: content.height)
            let rightRect = NSRect(x: content.minX + width, y: content.minY, width: max(0, content.width - width), height: content.height)
            containerA.isHidden = false
            containerB.isHidden = false
            containerA.frame = leftRect
            containerB.frame = rightRect
            divider.isHidden = false
            divider.frame = NSRect(x: content.minX + width - 12, y: content.minY, width: 24, height: content.height)
            rectA = content
            rectB = content
        }
        renderer.layoutMode = layoutMode
        renderer.wipeFraction = wipeFraction
        renderer.rectA = rectA
        renderer.rectB = rectB
        if layoutMode != .overlapWipe {
            labelA.alignment = .left
            labelB.alignment = .left
        }
        layoutFrameNumberLabels(rectA: rectA, rectB: rectB)
        updateSelectionAppearance()
    }

    func setFrameNumberOverlayVisible(_ visible: Bool) {
        frameNumberA.isHidden = !visible || frameNumberA.stringValue.isEmpty
        frameNumberB.isHidden = !visible || frameNumberB.stringValue.isEmpty
    }

    func setFrameNumber(_ text: String?, slot: VideoSlot, visible: Bool) {
        let label = slot == .a ? frameNumberA : frameNumberB
        let value = text ?? ""
        label.stringValue = value
        label.isHidden = !visible || value.isEmpty
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let wantsROISelection = event.modifierFlags.contains(.command)
        if wantsROISelection,
           layoutMode == .overlapWipe,
           activeContentBounds().contains(point),
           let clickedSlot = slot(at: point) {
            selectedSlot = clickedSlot
            isSelectingROI = true
            roiStartPoint = point
            roiSlot = clickedSlot
            roiOverlay.selectionRect = NSRect(origin: point, size: .zero)
            return
        }
        isDraggingWipe = layoutMode == .overlapWipe && isNearDivider(point)
        let clickedSlot = slot(at: point)
        if let clickedSlot {
            selectedSlot = clickedSlot
        }
        panSlot = selectedSlot
        isPanning = allowsAlignmentAdjustment && !isDraggingWipe && panSlot != nil
        didPan = false
        lastDragPoint = point
        if isDraggingWipe {
            updateWipeFromPoint(point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isSelectingROI, let roiStartPoint {
            let rect = normalizedRect(from: roiStartPoint, to: point)
            if let roiSlot {
                roiOverlay.selectionRect = rect.intersection(visibleRect(for: roiSlot))
            } else {
                roiOverlay.selectionRect = rect
            }
            return
        }
        if isDraggingWipe {
            updateWipeFromPoint(point)
            return
        }
        guard isPanning, let lastDragPoint else { return }
        let dx = point.x - lastDragPoint.x
        let dy = point.y - lastDragPoint.y
        if abs(dx) > 0.5 || abs(dy) > 0.5 {
            didPan = true
            let content = activeContentBounds()
            if content.width > 0 && content.height > 0, let panSlot {
                if event.modifierFlags.contains(.option) {
                    onZoomDragged?(panSlot, -dy / content.height * 2)
                } else {
                    onPanDragged?(panSlot, dx / content.width * 2, dy / content.height * 2)
                }
            }
            self.lastDragPoint = point
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isSelectingROI {
            let point = convert(event.locationInWindow, from: nil)
            let rawRect = normalizedRect(from: roiStartPoint ?? point, to: point)
            let slot = roiSlot
            let rect = slot.map { rawRect.intersection(visibleRect(for: $0)) } ?? rawRect.intersection(activeContentBounds())
            isSelectingROI = false
            roiStartPoint = nil
            roiSlot = nil
            roiOverlay.selectionRect = nil
            if let slot, rect.width >= 80, rect.height >= 80 {
                onROIAlignmentRequested?(slot, rect)
            } else {
                NSSound.beep()
            }
            return
        }
        isDraggingWipe = false
        isPanning = false
        panSlot = nil
        lastDragPoint = nil
        if didPan {
            onAlignmentGestureEnded?()
        }
    }

    func toggleWipeEdge() {
        guard layoutMode == .overlapWipe else { return }
        wipeFraction = wipeFraction < 0.5 ? 1 : 0
        renderer.wipeFraction = wipeFraction
        selectedSlot = wipeFraction >= 0.5 ? .a : .b
        onToggleChanged?()
    }

    func clearSelection() {
        selectedSlot = nil
    }

    func videoRect(for slot: VideoSlot) -> NSRect {
        layoutSubtreeIfNeeded()
        switch layoutMode {
        case .sideBySideHorizontal:
            return slot == .a ? containerA.frame : containerB.frame
        case .overlapWipe:
            return activeContentBounds()
        }
    }

    func videoAnchor(at point: NSPoint) -> (slot: VideoSlot, relativePoint: CGPoint)? {
        guard let slot = slot(at: point) else { return nil }
        let rect = videoRect(for: slot)
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return (
            slot,
            CGPoint(
                x: max(0, min(1, (point.x - rect.minX) / rect.width)),
                y: max(0, min(1, (point.y - rect.minY) / rect.height))
            )
        )
    }

    @discardableResult
    func selectSlot(at point: NSPoint) -> VideoSlot? {
        let slot = slot(at: point)
        selectedSlot = slot
        return slot
    }

    func updateWipeFromWindowEvent(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateWipeFromPoint(point)
    }

    private func activeContentBounds() -> NSRect {
        switch layoutMode {
        case .overlapWipe:
            return NSRect(x: 0, y: labelHeight, width: bounds.width, height: max(0, bounds.height - labelHeight))
        default:
            return bounds
        }
    }

    private func visibleRect(for slot: VideoSlot) -> NSRect {
        switch layoutMode {
        case .sideBySideHorizontal:
            return slot == .a ? containerA.frame : containerB.frame
        case .overlapWipe:
            let content = activeContentBounds()
            let splitX = content.minX + content.width * wipeFraction
            if slot == .a {
                return NSRect(x: content.minX, y: content.minY, width: max(0, splitX - content.minX), height: content.height)
            }
            return NSRect(x: splitX, y: content.minY, width: max(0, content.maxX - splitX), height: content.height)
        }
    }

    private func layoutFrameNumberLabels(rectA: NSRect, rectB: NSRect) {
        let labels: [(VideoSlot, NSTextField, NSRect)] = [(.a, frameNumberA, rectA), (.b, frameNumberB, rectB)]
        for (slot, label, rect) in labels {
            guard !label.stringValue.isEmpty else { continue }
            let size = label.intrinsicContentSize
            let width = min(max(56, ceil(size.width) + 14), max(56, rect.width - 16))
            let height: CGFloat = 22
            let stackedOffset: CGFloat = layoutMode == .overlapWipe && slot == .b ? height + 6 : 0
            label.frame = NSRect(
                x: rect.minX + 8,
                y: rect.minY + 8 + stackedOffset,
                width: width,
                height: height
            )
        }
    }

    private func slot(at point: NSPoint) -> VideoSlot? {
        switch layoutMode {
        case .sideBySideHorizontal:
            if containerA.frame.contains(point) || labelA.frame.contains(point) { return .a }
            if containerB.frame.contains(point) || labelB.frame.contains(point) { return .b }
        case .overlapWipe:
            let content = activeContentBounds()
            if content.contains(point) {
                return point.x <= content.minX + content.width * wipeFraction ? .a : .b
            }
            if labelA.frame.contains(point) { return .a }
            if labelB.frame.contains(point) { return .b }
        }
        return nil
    }

    private func isNearDivider(_ point: NSPoint) -> Bool {
        let content = activeContentBounds()
        guard content.contains(point) else { return false }
        let dividerX = content.minX + content.width * wipeFraction
        return abs(point.x - dividerX) <= 16
    }

    private func updateWipeFromPoint(_ point: NSPoint) {
        let content = activeContentBounds()
        wipeFraction = content.width <= 0 ? 0.5 : max(0, min(1, (point.x - content.minX) / content.width))
        renderer.wipeFraction = wipeFraction
        needsDisplay = true
        onWipeChanged?(wipeFraction)
    }

    private func normalizedRect(from start: NSPoint, to end: NSPoint) -> NSRect {
        NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func updateSelectionAppearance() {
        for (slot, container) in [(VideoSlot.a, containerA), (VideoSlot.b, containerB)] {
            let selected = selectedSlot == slot
            container.layer?.borderWidth = selected ? 3 : 0
            container.layer?.borderColor = selected ? NSColor.systemYellow.cgColor : nil
        }
        labelA.textColor = selectedSlot == .a ? .systemYellow : NSColor(calibratedWhite: 0.88, alpha: 1)
        labelB.textColor = selectedSlot == .b ? .systemYellow : NSColor(calibratedWhite: 0.88, alpha: 1)
    }
}
