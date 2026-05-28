import AppKit

private enum AdjustmentPanelStyle {
    static let background = NSColor(calibratedWhite: 0.56, alpha: 1)
    static let label = NSColor(calibratedWhite: 1, alpha: 0.90)
    static let disabledLabel = NSColor(calibratedWhite: 0.86, alpha: 0.62)
    static let adjustmentRowHeight: CGFloat = 24
    static let adjustmentLabelWidth: CGFloat = 94
    static let adjustmentLabelHeight: CGFloat = 24
    static func adjustmentLabelFont() -> NSFont {
        NSFont.systemFont(ofSize: 12, weight: .medium)
    }
    static let adjustmentEndpointIconSize: CGFloat = 16
    static let adjustmentSliderHeight: CGFloat = 20
    static let whiteBalanceButtonSize: CGFloat = 16
    static let whiteBalanceIconSize: CGFloat = 10.5
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

private final class TrackingSlider: NSSlider {
    var onTrackingChanged: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onTrackingChanged?(true)
        super.mouseDown(with: event)
        onTrackingChanged?(false)
    }
}

private final class CenteredTextLabel: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBordered = false
        focusRingType = .none
        backgroundColor = .clear
        drawsBackground = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let attributes = drawingAttributes()
        return (stringValue as NSString).size(withAttributes: attributes)
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes = drawingAttributes()
        let text = stringValue as NSString
        let textSize = text.size(withAttributes: attributes)
        let textHeight = ceil(textSize.height)
        let rect = NSRect(
            x: 0,
            y: bounds.midY - textHeight / 2,
            width: bounds.width,
            height: textHeight + 1
        )
        text.draw(in: rect, withAttributes: attributes)
    }

    private func drawingAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byClipping
        return [
            .font: font ?? AdjustmentPanelStyle.adjustmentLabelFont(),
            .foregroundColor: textColor ?? AdjustmentPanelStyle.label,
            .paragraphStyle: style
        ]
    }
}

private final class NativeAdjustmentRowView: NSView {
    private let titleLabel = CenteredTextLabel()
    private let leftIconView = NSImageView()
    private let rightIconView = NSImageView()
    private let slider = TrackingSlider(value: 0, minValue: 1, maxValue: 1, target: nil, action: nil)
    private var isUpdating = false
    var onValueChanged: ((Double) -> Void)?
    var onTrackingChanged: ((Bool) -> Void)?

    var value: Double {
        get { slider.doubleValue }
        set { slider.doubleValue = min(slider.maxValue, max(slider.minValue, newValue)) }
    }

    var titleFrame: NSRect {
        titleLabel.frame
    }

    var titleTextMinX: CGFloat {
        titleLabel.frame.maxX - min(titleLabel.frame.width, ceil(titleLabel.intrinsicContentSize.width))
    }

    init(title: String, value: Double, range: ClosedRange<Double>, leftIcon: EndpointIcon, rightIcon: EndpointIcon) {
        super.init(frame: .zero)

        titleLabel.stringValue = title
        titleLabel.font = AdjustmentPanelStyle.adjustmentLabelFont()
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
        slider.onTrackingChanged = { [weak self] tracking in
            guard self?.rowEnabled == true else { return }
            self?.onTrackingChanged?(tracking)
        }

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
        let labelW = AdjustmentPanelStyle.adjustmentLabelWidth
        let iconW = AdjustmentPanelStyle.adjustmentEndpointIconSize
        let gap: CGFloat = 7
        let midY = bounds.midY
        titleLabel.frame = NSRect(
            x: 0,
            y: midY - AdjustmentPanelStyle.adjustmentLabelHeight / 2,
            width: labelW,
            height: AdjustmentPanelStyle.adjustmentLabelHeight
        )
        leftIconView.frame = NSRect(
            x: labelW + gap,
            y: midY - iconW / 2,
            width: iconW,
            height: iconW
        )
        rightIconView.frame = NSRect(
            x: bounds.width - iconW,
            y: midY - iconW / 2,
            width: iconW,
            height: iconW
        )
        slider.frame = NSRect(
            x: leftIconView.frame.maxX + 7,
            y: midY - AdjustmentPanelStyle.adjustmentSliderHeight / 2,
            width: max(72, rightIconView.frame.minX - leftIconView.frame.maxX - 14),
            height: AdjustmentPanelStyle.adjustmentSliderHeight
        )
    }

    func setValue(_ newValue: Double) {
        isUpdating = true
        value = newValue
        isUpdating = false
    }

    func setRange(_ range: ClosedRange<Double>) {
        guard slider.minValue != range.lowerBound || slider.maxValue != range.upperBound else { return }
        isUpdating = true
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        value = slider.doubleValue
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
        guard bounds.width > 32, bounds.height > 36 else { return }
        let plot = plotRect

        NSColor.white.setFill()
        NSBezierPath(rect: plot).fill()

        if showsHistogramBars, !histogram.isEmpty {
            drawHistogram(histogram, in: plot)
        }

        drawActiveRegionOverlay(in: plot)
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
        NSRect(x: 10, y: 0, width: bounds.width - 20, height: bounds.height - 10)
    }

    private func drawActiveRegionOverlay(in plot: NSRect) {
        guard isInteractive, let index = activeRegion ?? hoverRegion else { return }
        let rect = regionOverlayRect(index: index, in: plot)
        NSColor(calibratedWhite: 0.18, alpha: activeRegion == index ? 0.30 : 0.20).setFill()
        NSBezierPath(rect: rect).fill()
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
        guard plot.contains(point) else { return nil }
        for index in ToneCurveState.regions.indices.reversed() {
            if regionHitRect(index: index, in: plot).contains(point) {
                return index
            }
        }
        return nil
    }

    private func regionOverlayRect(index: Int, in plot: NSRect) -> NSRect {
        let region = ToneCurveState.regions[index]
        let start = adjustment.toneCurve.sample(region.inputStart)
        let end = adjustment.toneCurve.sample(region.inputEnd)
        let x0 = plot.minX + plot.width * CGFloat(start)
        let x1 = plot.minX + plot.width * CGFloat(end)
        return NSRect(x: min(x0, x1), y: plot.minY, width: max(1, abs(x1 - x0)), height: plot.height)
    }

    private func regionHitRect(index: Int, in plot: NSRect) -> NSRect {
        let rect = regionOverlayRect(index: index, in: plot)
        let minWidth: CGFloat = 10
        let extra = max(0, minWidth - rect.width) / 2
        return rect.insetBy(dx: -extra, dy: 0).intersection(plot)
    }
}

final class ColorAdjustmentPanelController: NSWindowController {
    private let rootView = ColorAdjustmentRootView()
    private let enabledButton = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
    private let whiteBalanceButton = WhiteBalanceIconButton()
    private let resetButton = NSButton(title: "Reset All", target: nil, action: nil)
    private let curveView = CurveHistogramView()
    private var rows: [String: NativeAdjustmentRowView] = [:]
    private var state = ColorAdjustmentState()
    private var currentSlot: VideoSlot?
    private var isSyncing = false
    private var canWhiteBalance = false

    var onStateChanged: ((ColorAdjustmentState) -> Void)?
    var onStateChangeTracking: ((ColorAdjustmentState, Bool) -> Void)?
    var onReset: (() -> Void)?
    var onWhiteBalanceRequested: (() -> Void)?

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 318, height: 448),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Adjust Color"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 318, height: 448)
        panel.maxSize = NSSize(width: 380, height: 500)
        self.init(window: panel)
        setup()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
    }

    func update(slot: VideoSlot?, state: ColorAdjustmentState, histogram: ColorHistogram, isRawImage: Bool = false, canWhiteBalance: Bool = false) {
        currentSlot = slot
        self.state = state
        self.canWhiteBalance = canWhiteBalance
        updateTemperatureTintRanges(isRawImage: isRawImage)
        curveView.histogram = histogram
        syncControls()
    }

    func updateHistogram(_ histogram: ColorHistogram) {
        curveView.histogram = histogram
    }

    func setWhiteBalanceSampling(_ sampling: Bool) {
        whiteBalanceButton.state = sampling ? .on : .off
        whiteBalanceButton.toolTip = sampling ? "取消取色白平衡" : "取色白平衡"
        whiteBalanceButton.setAccessibilityLabel(sampling ? "取消取色白平衡" : "取色白平衡")
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

        for button in [resetButton] {
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            button.contentTintColor = .white
        }
        whiteBalanceButton.title = ""
        let whiteBalanceImage = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "取色白平衡")
            ?? NSImage(systemSymbolName: "eyedropper.full", accessibilityDescription: "取色白平衡")
        let whiteBalanceSymbol = whiteBalanceImage?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        ) ?? whiteBalanceImage
        whiteBalanceButton.iconImage = whiteBalanceSymbol?.tinted(NSColor(calibratedWhite: 0.16, alpha: 1))
        whiteBalanceButton.setButtonType(.toggle)
        whiteBalanceButton.toolTip = "取色白平衡"
        whiteBalanceButton.setAccessibilityLabel("取色白平衡")
        whiteBalanceButton.target = self
        whiteBalanceButton.action = #selector(whiteBalanceClicked)
        resetButton.target = self
        resetButton.action = #selector(resetClicked)
        curveView.onToneCurveChanged = { [weak self] toneCurve in
            guard let self, !self.isSyncing, self.currentSlot != nil else { return }
            self.state.toneCurve = toneCurve
            self.curveView.adjustment = self.state
            self.onStateChanged?(self.state)
        }

        [curveView, whiteBalanceButton, enabledButton, resetButton].forEach(rootView.addSubview)

        addRow("exposure", title: "Exposure:", value: 0, range: -2...2, left: .symbol("camera.aperture", .white), right: .symbol("camera.aperture", .white))
        addRow("contrast", title: "Contrast:", value: 0, range: -1...1, left: .colorDot(.black), right: .symbol("circle.lefthalf.filled", .white))
        addRow("brightness", title: "Brightness:", value: 0, range: -1...1, left: .symbol("sun.min", .systemYellow), right: .symbol("sun.max.fill", .systemYellow))
        addRow("saturation", title: "Saturation:", value: 0, range: -1...1, left: .grayscale, right: .rgb)
        addRow("temperature", title: "Temperature:", value: 0, range: ColorAdjustmentControlRanges.standardTemperatureTint, left: .symbol("sun.min", NSColor(calibratedRed: 0.68, green: 0.86, blue: 1, alpha: 1)), right: .symbol("sun.max.fill", NSColor(calibratedRed: 1, green: 0.45, blue: 0.28, alpha: 1)))
        addRow("tint", title: "Tint:", value: 0, range: ColorAdjustmentControlRanges.standardTemperatureTint, left: .colorDot(.systemGreen), right: .colorDot(.systemPink))
        addRow("sharpness", title: "Sharpness:", value: 0, range: 0...1, left: .symbol("square", .white), right: .symbol("square.fill", .white))
    }

    private func addRow(_ key: String, title: String, value: Double, range: ClosedRange<Double>, left: EndpointIcon, right: EndpointIcon) {
        let row = NativeAdjustmentRowView(title: title, value: value, range: range, leftIcon: left, rightIcon: right)
        row.onValueChanged = { [weak self] newValue in
            self?.rowChanged(key: key, value: newValue)
        }
        row.onTrackingChanged = { [weak self] tracking in
            self?.rowTrackingChanged(key: key, tracking: tracking)
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
        whiteBalanceButton.isEnabled = hasSlot && canWhiteBalance
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

    private func updateTemperatureTintRanges(isRawImage: Bool) {
        let range = isRawImage ? ColorAdjustmentControlRanges.rawTemperatureTint : ColorAdjustmentControlRanges.standardTemperatureTint
        rows["temperature"]?.setRange(range)
        rows["tint"]?.setRange(range)
    }

    private func layoutControls() {
        let bounds = rootView.bounds
        let pad: CGFloat = 24
        curveView.frame = NSRect(x: 14, y: 18, width: max(100, bounds.width - 28), height: 116)
        resetButton.frame = NSRect(x: floor((bounds.width - 92) / 2), y: 154, width: 92, height: 22)
        enabledButton.frame = NSRect(x: bounds.width - pad - 50, y: 156, width: 50, height: 20)

        layoutRows(["exposure", "contrast", "brightness"], startY: 202)
        layoutColorRows(startY: 296)
        layoutRows(["sharpness"], startY: 390)
    }

    private func layoutRows(_ keys: [String], startY: CGFloat) {
        let pad: CGFloat = 24
        var y = startY
        for key in keys {
            guard let row = rows[key] else { continue }
            row.frame = NSRect(
                x: pad,
                y: y,
                width: max(100, rootView.bounds.width - pad * 2),
                height: AdjustmentPanelStyle.adjustmentRowHeight
            )
            y += 24
        }
    }

    private func layoutColorRows(startY: CGFloat) {
        let pad: CGFloat = 24
        let buttonSize = AdjustmentPanelStyle.whiteBalanceButtonSize
        let buttonTitleGap: CGFloat = 8
        let rowHeight = AdjustmentPanelStyle.adjustmentRowHeight
        let rowWidth = max(100, rootView.bounds.width - pad * 2)
        rows["saturation"]?.frame = NSRect(x: pad, y: startY, width: rowWidth, height: rowHeight)
        rows["temperature"]?.frame = NSRect(x: pad, y: startY + 24, width: rowWidth, height: rowHeight)
        rows["tint"]?.frame = NSRect(x: pad, y: startY + 48, width: rowWidth, height: rowHeight)
        if let tintRow = rows["tint"] {
            tintRow.layoutSubtreeIfNeeded()
            let titleMinX = tintRow.frame.minX + tintRow.titleTextMinX
            let preferredButtonX = titleMinX - buttonTitleGap - buttonSize
            let buttonX = max(8, preferredButtonX)
            whiteBalanceButton.frame = NSRect(
                x: buttonX,
                y: tintRow.frame.midY - buttonSize / 2,
                width: buttonSize,
                height: buttonSize
            )
        }
    }

    @objc private func enabledChanged() {
        guard !isSyncing, currentSlot != nil else { return }
        state.isEnabled = enabledButton.state == .on
        curveView.adjustment = state
        curveView.isInteractive = state.isEnabled
        rows.values.forEach { $0.rowEnabled = state.isEnabled }
        onStateChanged?(state)
    }

    @objc private func whiteBalanceClicked() {
        guard currentSlot != nil, canWhiteBalance else { return }
        onWhiteBalanceRequested?()
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

    private func rowTrackingChanged(key: String, tracking: Bool) {
        guard !isSyncing, currentSlot != nil, key == "temperature" || key == "tint" else { return }
        onStateChangeTracking?(state, tracking)
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

private final class WhiteBalanceIconButton: NSButton {
    var iconImage: NSImage? {
        didSet { needsDisplay = true }
    }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        setButtonType(.toggle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: AdjustmentPanelStyle.whiteBalanceButtonSize, height: AdjustmentPanelStyle.whiteBalanceButtonSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let enabledAlpha: CGFloat = state == .on ? 0.96 : 0.86
        let alpha: CGFloat = isEnabled ? enabledAlpha : 0.36
        let background = NSColor.white.withAlphaComponent(isHighlighted ? max(0.55, alpha - 0.18) : alpha)
        background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        guard let iconImage else { return }
        let iconSize = AdjustmentPanelStyle.whiteBalanceIconSize
        let iconRect = NSRect(
            x: bounds.midX - iconSize / 2,
            y: bounds.midY - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
        iconImage.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.42)
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
