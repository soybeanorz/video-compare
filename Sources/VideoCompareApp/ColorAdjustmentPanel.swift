import AppKit

private enum AdjustmentPanelStyle {
    static let background = NSColor(calibratedWhite: 0.56, alpha: 1)
    static let separator = NSColor(calibratedWhite: 0.75, alpha: 0.74)
    static let label = NSColor.white
    static let disabledLabel = NSColor(calibratedWhite: 0.86, alpha: 0.62)
}

private enum EndpointIcon {
    case symbol(String, NSColor)
    case colorDot(NSColor)
    case grayscale
    case rgb

    var image: NSImage {
        switch self {
        case .symbol(let name, let color):
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
            image.isTemplate = true
            return image.tinted(color)
        case .colorDot(let color):
            return NSImage.endpointDot(color: color)
        case .grayscale:
            return NSImage.endpointBars(colors: [.black, NSColor(calibratedWhite: 0.55, alpha: 1), .white])
        case .rgb:
            return NSImage.endpointBars(colors: [.systemRed, .systemGreen, .systemBlue])
        }
    }
}

private final class NativeAdjustmentRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let leftIconView = NSImageView()
    private let rightIconView = NSImageView()
    private let slider = NSSlider(value: 0, minValue: 1, maxValue: 1, target: nil, action: nil)
    private var isUpdating = false
    var onValueChanged: ((Double) -> Void)?

    var value: Double {
        get { slider.doubleValue }
        set { slider.doubleValue = min(slider.maxValue, max(slider.minValue, newValue)) }
    }

    init(title: String, value: Double, range: ClosedRange<Double>, leftIcon: EndpointIcon, rightIcon: EndpointIcon) {
        super.init(frame: .zero)

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        titleLabel.textColor = AdjustmentPanelStyle.label
        titleLabel.alignment = .right
        titleLabel.backgroundColor = .clear
        titleLabel.drawsBackground = false

        leftIconView.image = leftIcon.image
        rightIconView.image = rightIcon.image
        leftIconView.imageScaling = .scaleProportionallyDown
        rightIconView.imageScaling = .scaleProportionallyDown

        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.controlSize = .mini
        slider.font = NSFont.systemFont(ofSize: 10)
        slider.numberOfTickMarks = 3
        slider.tickMarkPosition = .below
        slider.target = self
        slider.action = #selector(sliderChanged)

        addSubview(titleLabel)
        addSubview(leftIconView)
        addSubview(slider)
        addSubview(rightIconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var isHidden: Bool {
        didSet { needsLayout = true }
    }

    var rowEnabled = true {
        didSet {
            titleLabel.textColor = rowEnabled ? AdjustmentPanelStyle.label : AdjustmentPanelStyle.disabledLabel
            leftIconView.alphaValue = rowEnabled ? 1 : 0.42
            rightIconView.alphaValue = rowEnabled ? 1 : 0.42
            slider.isEnabled = rowEnabled
        }
    }

    override func layout() {
        super.layout()
        let labelW: CGFloat = 76
        let iconW: CGFloat = 14
        let gap: CGFloat = 7
        titleLabel.frame = NSRect(x: 0, y: 2, width: labelW, height: 18)
        leftIconView.frame = NSRect(x: labelW + gap, y: 4, width: iconW, height: 14)
        rightIconView.frame = NSRect(x: bounds.width - iconW, y: 4, width: iconW, height: 14)
        slider.frame = NSRect(
            x: leftIconView.frame.maxX + 7,
            y: 0,
            width: max(72, rightIconView.frame.minX - leftIconView.frame.maxX - 14),
            height: 20
        )
    }

    func setValue(_ newValue: Double) {
        isUpdating = true
        value = newValue
        isUpdating = false
    }

    @objc private func sliderChanged() {
        guard !isUpdating else { return }
        onValueChanged?(slider.doubleValue)
    }
}

final class CurveHistogramView: NSView {
    var histogram = ColorHistogram.empty {
        didSet { needsDisplay = true }
    }
    var adjustment = ColorAdjustmentState() {
        didSet { needsDisplay = true }
    }
    var showsHistogramBars = false {
        didSet { needsDisplay = true }
    }
    var isInteractive = false {
        didSet { needsDisplay = true }
    }
    var onToneCurveChanged: ((ToneCurveState) -> Void)?
    private var hoverRegion: Int? {
        didSet { needsDisplay = true }
    }
    private var activeRegion: Int? {
        didSet { needsDisplay = true }
    }
    private var dragStartPoint: NSPoint = .zero
    private var dragStartCurve = ToneCurveState()
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 32, bounds.height > 42 else { return }
        let plot = plotRect

        NSColor.white.setFill()
        NSBezierPath(rect: plot).fill()

        if showsHistogramBars, !histogram.isEmpty {
            drawHistogram(histogram, in: plot)
        }

        drawToneRegions(in: plot)

        NSColor(calibratedWhite: 0.42, alpha: 0.48).setStroke()
        let curve = curvePath(in: plot)
        curve.lineWidth = 2
        curve.stroke()
    }

    private func curvePath(in plot: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let samples = 96
        for index in 0...samples {
            let input = Double(index) / Double(samples)
            let output = adjustment.toneCurve.sample(input)
            let x = plot.minX + plot.width * CGFloat(output)
            let y = plot.maxY - plot.height * CGFloat(input)
            if index == 0 {
                path.move(to: NSPoint(x: x, y: y))
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }
        return path
    }

    private var plotRect: NSRect {
        NSRect(x: 10, y: 0, width: bounds.width - 20, height: bounds.height - 26)
    }

    private func drawToneRegions(in plot: NSRect) {
        let regions = ToneCurveState.regions
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(isInteractive ? 0.96 : 0.54)
        ]
        for (index, region) in regions.enumerated() {
            let rect = regionRect(index: index, in: plot)
            let isHot = activeRegion == index || hoverRegion == index
            let white = 0.10 + CGFloat(index) * 0.12
            NSColor(calibratedWhite: white, alpha: isHot ? 0.82 : (isInteractive ? 0.58 : 0.30)).setFill()
            NSBezierPath(rect: rect).fill()
            NSColor(calibratedWhite: 1, alpha: isHot ? 0.82 : 0.36).setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 0.8
            outline.stroke()

            let label = region.shortTitle as NSString
            let size = label.size(withAttributes: labelAttributes)
            let x = rect.midX - size.width / 2
            label.draw(at: NSPoint(x: x, y: rect.midY - size.height / 2), withAttributes: labelAttributes)
        }
    }

    private func drawHistogram(_ histogram: ColorHistogram, in plot: NSRect) {
        let maxBin = max(0.001, histogram.red.max() ?? 0, histogram.green.max() ?? 0, histogram.blue.max() ?? 0)
        let binCount = max(histogram.red.count, histogram.green.count, histogram.blue.count)
        let binWidth = plot.width / CGFloat(max(1, binCount))
        let channels: [(values: [Double], color: NSColor, dx: CGFloat)] = [
            (histogram.blue, NSColor(calibratedRed: 0.08, green: 0.26, blue: 0.78, alpha: 0.58), 0),
            (histogram.green, NSColor(calibratedRed: 0.05, green: 0.62, blue: 0.20, alpha: 0.46), binWidth * 0.20),
            (histogram.red, NSColor(calibratedRed: 0.92, green: 0.08, blue: 0.08, alpha: 0.44), binWidth * 0.40)
        ]
        for channel in channels {
            channel.color.setFill()
            for (index, value) in channel.values.enumerated() {
                let h = plot.height * CGFloat(value / maxBin)
                let x = plot.minX + CGFloat(index) * binWidth + channel.dx
                NSBezierPath(rect: NSRect(x: x, y: plot.maxY - h, width: max(1, binWidth * 0.9), height: h)).fill()
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard isInteractive else {
            hoverRegion = nil
            return
        }
        hoverRegion = hitRegion(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoverRegion = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let region = hitRegion(at: point) else { return }
        window?.makeFirstResponder(self)
        activeRegion = region
        dragStartPoint = point
        dragStartCurve = adjustment.toneCurve
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractive, let activeRegion else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = Double((point.x - dragStartPoint.x) / max(1, plotRect.width))
        let toneCurve = dragStartCurve.movingRegion(activeRegion, by: delta)
        onToneCurveChanged?(toneCurve)
    }

    override func mouseUp(with event: NSEvent) {
        activeRegion = nil
        hoverRegion = isInteractive ? hitRegion(at: convert(event.locationInWindow, from: nil)) : nil
    }

    private func hitRegion(at point: NSPoint) -> Int? {
        let plot = plotRect
        for index in ToneCurveState.regions.indices.reversed() {
            if regionRect(index: index, in: plot).insetBy(dx: -4, dy: -3).contains(point) {
                return index
            }
        }
        return nil
    }

    private func regionRect(index: Int, in plot: NSRect) -> NSRect {
        let region = ToneCurveState.regions[index]
        let start = adjustment.toneCurve.sample(region.inputStart)
        let end = adjustment.toneCurve.sample(region.inputEnd)
        let x0 = plot.minX + plot.width * CGFloat(start)
        let x1 = plot.minX + plot.width * CGFloat(end)
        return NSRect(x: min(x0, x1), y: plot.maxY + 5, width: max(7, abs(x1 - x0)), height: 13)
    }
}

final class ColorAdjustmentPanelController: NSWindowController {
    private let rootView = ColorAdjustmentRootView()
    private let enabledButton = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private let autoLevelsButton = NSButton(title: "Auto Levels", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset All", target: nil, action: nil)
    private let curveView = CurveHistogramView()
    private let separatorTone = NSBox()
    private let separatorColor = NSBox()
    private let separatorDetail = NSBox()
    private let separatorReset = NSBox()
    private var rows: [String: NativeAdjustmentRowView] = [:]
    private var state = ColorAdjustmentState()
    private var currentSlot: VideoSlot?
    private var isSyncing = false

    var onStateChanged: ((ColorAdjustmentState) -> Void)?
    var onReset: (() -> Void)?

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 318, height: 540),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Adjust Color"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.level = .normal
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 318, height: 540)
        panel.maxSize = NSSize(width: 380, height: 640)
        self.init(window: panel)
        setup()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
    }

    func update(slot: VideoSlot?, state: ColorAdjustmentState, histogram: ColorHistogram) {
        currentSlot = slot
        self.state = state
        curveView.histogram = histogram
        syncControls()
    }

    func updateHistogram(_ histogram: ColorHistogram) {
        curveView.histogram = histogram
    }

    private func setup() {
        guard let window else { return }
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = AdjustmentPanelStyle.background.cgColor
        rootView.onLayout = { [weak self] in
            self?.layoutControls()
        }
        window.contentView = rootView

        enabledButton.target = self
        enabledButton.action = #selector(enabledChanged)
        enabledButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        enabledButton.contentTintColor = .white

        for button in [autoLevelsButton, resetButton] {
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            button.contentTintColor = .white
        }
        autoLevelsButton.target = self
        autoLevelsButton.action = #selector(autoLevelsClicked)
        resetButton.target = self
        resetButton.action = #selector(resetClicked)
        curveView.onToneCurveChanged = { [weak self] toneCurve in
            guard let self, !self.isSyncing, self.currentSlot != nil else { return }
            self.state.toneCurve = toneCurve
            self.curveView.adjustment = self.state
            self.onStateChanged?(self.state)
        }

        for separator in [separatorTone, separatorColor, separatorDetail, separatorReset] {
            separator.boxType = .separator
            separator.contentViewMargins = .zero
        }

        [curveView, autoLevelsButton, separatorTone, separatorColor, separatorDetail, separatorReset, enabledButton, resetButton].forEach(rootView.addSubview)

        addRow("exposure", title: "Exposure:", value: 0, range: -2...2, left: .symbol("camera.aperture", .white), right: .symbol("camera.aperture", .white))
        addRow("contrast", title: "Contrast:", value: 0, range: -1...1, left: .colorDot(.black), right: .symbol("circle.lefthalf.filled", .white))
        addRow("brightness", title: "Brightness:", value: 0, range: -1...1, left: .symbol("sun.min", .systemYellow), right: .symbol("sun.max.fill", .systemYellow))
        addRow("saturation", title: "Saturation:", value: 0, range: -1...1, left: .grayscale, right: .rgb)
        addRow("temperature", title: "Temp:", value: 0, range: -1...1, left: .symbol("thermometer.low", NSColor(calibratedRed: 0.68, green: 0.86, blue: 1, alpha: 1)), right: .symbol("thermometer.high", NSColor(calibratedRed: 1, green: 0.45, blue: 0.28, alpha: 1)))
        addRow("tint", title: "Tint:", value: 0, range: -1...1, left: .colorDot(.systemGreen), right: .colorDot(.systemPink))
        addRow("sharpness", title: "Sharpness:", value: 0, range: 0...1, left: .symbol("square", .white), right: .symbol("square.fill", .white))
    }

    private func addRow(_ key: String, title: String, value: Double, range: ClosedRange<Double>, left: EndpointIcon, right: EndpointIcon) {
        let row = NativeAdjustmentRowView(title: title, value: value, range: range, leftIcon: left, rightIcon: right)
        row.onValueChanged = { [weak self] newValue in
            self?.rowChanged(key: key, value: newValue)
        }
        rows[key] = row
        rootView.addSubview(row)
    }

    private func syncControls() {
        isSyncing = true
        let hasSlot = currentSlot != nil
        window?.title = currentSlot.map { "Adjust Color - \($0.rawValue.uppercased())" } ?? "Adjust Color"
        curveView.showsHistogramBars = hasSlot
        curveView.isInteractive = hasSlot && state.isEnabled
        enabledButton.state = state.isEnabled ? .on : .off
        enabledButton.isEnabled = hasSlot
        autoLevelsButton.isEnabled = hasSlot && state.isEnabled
        resetButton.isEnabled = hasSlot
        rows["exposure"]?.setValue(state.exposure)
        rows["contrast"]?.setValue(state.contrast)
        rows["brightness"]?.setValue(state.brightness)
        rows["saturation"]?.setValue(state.saturation)
        rows["temperature"]?.setValue(state.temperature)
        rows["tint"]?.setValue(state.tint)
        rows["sharpness"]?.setValue(state.sharpness)
        curveView.adjustment = state
        rows.values.forEach { $0.rowEnabled = hasSlot && state.isEnabled }
        isSyncing = false
        rootView.needsLayout = true
    }

    private func layoutControls() {
        let bounds = rootView.bounds
        let pad: CGFloat = 24
        curveView.frame = NSRect(x: 14, y: 18, width: max(100, bounds.width - 28), height: 116)
        autoLevelsButton.frame = NSRect(x: floor((bounds.width - 92) / 2), y: 165, width: 92, height: 22)
        enabledButton.frame = NSRect(x: bounds.width - pad - 50, y: 167, width: 50, height: 20)

        separatorTone.frame = NSRect(x: pad - 8, y: 216, width: max(100, bounds.width - (pad - 8) * 2), height: 1)
        layoutRows(["exposure", "contrast", "brightness"], startY: 232)

        separatorColor.frame = NSRect(x: pad - 8, y: 316, width: max(100, bounds.width - (pad - 8) * 2), height: 1)
        layoutRows(["saturation", "temperature", "tint"], startY: 332)

        separatorDetail.frame = NSRect(x: pad - 8, y: 416, width: max(100, bounds.width - (pad - 8) * 2), height: 1)
        layoutRows(["sharpness"], startY: 432)

        let resetY = bounds.height - 32
        separatorReset.frame = NSRect(x: pad - 8, y: resetY - 16, width: max(100, bounds.width - (pad - 8) * 2), height: 1)
        resetButton.frame = NSRect(x: floor((bounds.width - 92) / 2), y: resetY, width: 92, height: 22)
    }

    private func layoutRows(_ keys: [String], startY: CGFloat) {
        let pad: CGFloat = 24
        var y = startY
        for key in keys {
            guard let row = rows[key] else { continue }
            row.frame = NSRect(x: pad, y: y, width: max(100, rootView.bounds.width - pad * 2), height: 22)
            y += 24
        }
    }

    @objc private func enabledChanged() {
        guard !isSyncing, currentSlot != nil else { return }
        state.isEnabled = enabledButton.state == .on
        curveView.adjustment = state
        curveView.isInteractive = state.isEnabled
        autoLevelsButton.isEnabled = state.isEnabled
        rows.values.forEach { $0.rowEnabled = state.isEnabled }
        onStateChanged?(state)
    }

    @objc private func autoLevelsClicked() {
        guard currentSlot != nil else { return }
        state.toneCurve = ToneCurveState()
        syncControls()
        onStateChanged?(state)
    }

    @objc private func resetClicked() {
        guard currentSlot != nil else { return }
        onReset?()
    }

    private func rowChanged(key: String, value: Double) {
        guard !isSyncing, currentSlot != nil else { return }
        switch key {
        case "exposure": state.exposure = value
        case "contrast": state.contrast = value
        case "brightness": state.brightness = value
        case "saturation": state.saturation = value
        case "temperature": state.temperature = value
        case "tint": state.tint = value
        case "sharpness": state.sharpness = value
        default: break
        }
        curveView.adjustment = state
        onStateChanged?(state)
    }
}

private final class ColorAdjustmentRootView: NSView {
    var onLayout: (() -> Void)?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let copy = self.copy() as? NSImage ?? self
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }

    static func endpointDot(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14))
        image.lockFocus()
        color.setFill()
        NSColor.white.setStroke()
        let path = NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 11, height: 11))
        path.fill()
        path.lineWidth = 2
        path.stroke()
        image.unlockFocus()
        return image
    }

    static func endpointBars(colors: [NSColor]) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14))
        image.lockFocus()
        let rect = NSRect(x: 1.5, y: 1.5, width: 11, height: 11)
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSBezierPath(rect: NSRect(x: rect.minX + CGFloat(index) * rect.width / CGFloat(colors.count), y: rect.minY, width: rect.width / CGFloat(colors.count), height: rect.height)).fill()
        }
        NSColor.white.setStroke()
        NSBezierPath(rect: rect).stroke()
        image.unlockFocus()
        return image
    }
}
