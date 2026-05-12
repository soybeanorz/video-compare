import AppKit

final class DropVideoView: NSView {
    var slot: VideoSlot
    var onFileDropped: ((VideoSlot, URL) -> Void)?

    init(slot: VideoSlot) {
        self.slot = slot
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        url(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = url(from: sender) else { return false }
        onFileDropped?(slot, url)
        return true
    }

    private func url(from sender: NSDraggingInfo) -> URL? {
        guard let item = sender.draggingPasteboard.pasteboardItems?.first,
              let value = item.string(forType: .fileURL),
              let url = URL(string: value) else { return nil }
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "mkv"].contains(ext) ? url : nil
    }
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

final class VideoCanvasView: NSView {
    let containerA = DropVideoView(slot: .a)
    let containerB = DropVideoView(slot: .b)
    let hostA = MPVRenderView()
    let hostB = MPVRenderView()
    let labelA = NSTextField(labelWithString: "A: 未加载")
    let labelB = NSTextField(labelWithString: "B: 未加载")
    private let divider = WipeDividerView()
    private let labelHeight: CGFloat = 24

    var layoutMode: CompareLayout = .sideBySideHorizontal {
        didSet { needsLayout = true }
    }
    var wipeFraction: CGFloat = 0.5 {
        didSet { needsLayout = true }
    }
    var showingAInToggle = true {
        didSet { needsLayout = true }
    }
    var onToggleChanged: (() -> Void)?
    var onWipeChanged: ((CGFloat) -> Void)?
    var onPanDragged: ((VideoSlot, CGFloat, CGFloat) -> Void)?
    var onZoomDragged: ((VideoSlot, CGFloat) -> Void)?
    var onSelectionChanged: ((VideoSlot?) -> Void)?
    var selectedSlot: VideoSlot? {
        didSet {
            updateSelectionAppearance()
            onSelectionChanged?(selectedSlot)
        }
    }
    private var isDraggingWipe = false
    private var isPanning = false
    private var didPan = false
    private var lastDragPoint: NSPoint?
    private var panSlot: VideoSlot?

    var allowsAlignmentAdjustment: Bool {
        layoutMode == .overlapToggle || layoutMode == .overlapWipe
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        containerA.addSubview(hostA)
        containerB.addSubview(hostB)
        addSubview(containerA)
        addSubview(containerB)
        addSubview(labelA)
        addSubview(labelB)
        addSubview(divider)
        for view in [hostA, hostB] {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.cgColor
        }
        for label in [labelA, labelB] {
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            label.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
            label.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
            label.drawsBackground = true
            label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
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
        switch layoutMode {
        case .sideBySideHorizontal:
            let leftWidth = floor(b.width / 2)
            containerA.isHidden = false
            containerB.isHidden = false
            divider.isHidden = true
            labelA.isHidden = false
            labelB.isHidden = false
            labelA.frame = NSRect(x: 0, y: 0, width: leftWidth, height: oneLabel)
            labelB.frame = NSRect(x: leftWidth + 1, y: 0, width: max(0, b.width - leftWidth - 1), height: oneLabel)
            containerA.frame = NSRect(x: 0, y: oneLabel, width: leftWidth, height: max(0, b.height - oneLabel))
            containerB.frame = NSRect(x: leftWidth + 1, y: oneLabel, width: max(0, b.width - leftWidth - 1), height: max(0, b.height - oneLabel))
            hostA.frame = containerA.bounds
            hostB.frame = containerB.bounds
        case .sideBySideVertical:
            let topHeight = floor(b.height / 2)
            containerA.isHidden = false
            containerB.isHidden = false
            divider.isHidden = true
            labelA.isHidden = false
            labelB.isHidden = false
            labelA.frame = NSRect(x: 0, y: 0, width: b.width, height: oneLabel)
            containerA.frame = NSRect(x: 0, y: oneLabel, width: b.width, height: max(0, topHeight - oneLabel))
            labelB.frame = NSRect(x: 0, y: topHeight + 1, width: b.width, height: oneLabel)
            containerB.frame = NSRect(x: 0, y: topHeight + 1 + oneLabel, width: b.width, height: max(0, b.height - topHeight - 1 - oneLabel))
            hostA.frame = containerA.bounds
            hostB.frame = containerB.bounds
        case .overlapToggle:
            labelA.isHidden = !showingAInToggle
            labelB.isHidden = showingAInToggle
            divider.isHidden = true
            labelA.frame = NSRect(x: 0, y: 0, width: b.width, height: oneLabel)
            labelB.frame = NSRect(x: 0, y: 0, width: b.width, height: oneLabel)
            let content = NSRect(x: 0, y: oneLabel, width: b.width, height: max(0, b.height - oneLabel))
            containerA.frame = content
            containerB.frame = content
            hostA.frame = containerA.bounds
            hostB.frame = containerB.bounds
            containerA.isHidden = !showingAInToggle
            containerB.isHidden = showingAInToggle
        case .overlapWipe:
            labelA.isHidden = false
            labelB.isHidden = false
            labelA.alignment = .left
            labelB.alignment = .right
            labelA.frame = NSRect(x: 0, y: 0, width: floor(b.width / 2), height: oneLabel)
            labelB.frame = NSRect(x: floor(b.width / 2), y: 0, width: ceil(b.width / 2), height: oneLabel)
            let content = NSRect(x: 0, y: oneLabel, width: b.width, height: max(0, b.height - oneLabel))
            let width = max(0, min(content.width, content.width * wipeFraction))
            containerA.isHidden = false
            containerB.isHidden = false
            containerA.frame = content
            hostA.frame = containerA.bounds
            containerB.frame = NSRect(x: content.minX, y: content.minY, width: width, height: content.height)
            hostB.frame = NSRect(x: 0, y: 0, width: content.width, height: content.height)
            divider.isHidden = false
            divider.frame = NSRect(x: content.minX + width - 12, y: content.minY, width: 24, height: content.height)
        }
        if layoutMode != .overlapWipe {
            labelA.alignment = .left
            labelB.alignment = .left
        }
        updateSelectionAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
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
        isDraggingWipe = false
        isPanning = false
        panSlot = nil
        lastDragPoint = nil
    }

    func toggleOverlapDisplay() {
        guard layoutMode == .overlapToggle else { return }
        showingAInToggle.toggle()
        selectedSlot = showingAInToggle ? .a : .b
        onToggleChanged?()
    }

    func clearSelection() {
        selectedSlot = nil
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
        case .overlapToggle, .overlapWipe:
            return NSRect(x: 0, y: labelHeight, width: bounds.width, height: max(0, bounds.height - labelHeight))
        default:
            return bounds
        }
    }

    private func slot(at point: NSPoint) -> VideoSlot? {
        switch layoutMode {
        case .sideBySideHorizontal:
            if containerA.frame.contains(point) || labelA.frame.contains(point) { return .a }
            if containerB.frame.contains(point) || labelB.frame.contains(point) { return .b }
        case .sideBySideVertical:
            if containerA.frame.contains(point) || labelA.frame.contains(point) { return .a }
            if containerB.frame.contains(point) || labelB.frame.contains(point) { return .b }
        case .overlapToggle:
            let content = activeContentBounds()
            if content.contains(point) || labelA.frame.contains(point) || labelB.frame.contains(point) {
                return showingAInToggle ? .a : .b
            }
        case .overlapWipe:
            let content = activeContentBounds()
            if content.contains(point) {
                return point.x <= content.minX + content.width * wipeFraction ? .b : .a
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
        needsDisplay = true
        onWipeChanged?(wipeFraction)
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
