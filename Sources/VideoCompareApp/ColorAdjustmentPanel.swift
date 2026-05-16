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
        guard bounds.width > 32, bounds.height > 36 else { return }
        let plot = NSRect(x: 10, y: 0, width: bounds.width - 20, height: bounds.height - 18)

        NSColor.white.setFill()
        NSBezierPath(rect: plot).fill()

        if showsHistogramBars, !histogram.isEmpty {
            drawHistogram(histogram, in: plot)
        }

        NSColor(calibratedWhite: 0.42, alpha: 0.48).setStroke()
        let curve = curvePath(in: plot)
        curve.lineWidth = 2
        curve.stroke()

        drawLevelHandle(x: plot.minX, y: plot.maxY + 2, fill: .black)
        drawLevelHandle(x: plot.midX, y: plot.maxY + 2, fill: NSColor(calibratedWhite: 0.50, alpha: 1))
        drawLevelHandle(x: plot.maxX, y: plot.maxY + 2, fill: .white)
    }

    private func curvePath(in plot: NSRect) -> NSBezierPath {
        let points: [(Double, Double)] = [
            (0, 0),
            (0.25, adjustment.curveShadows),
            (0.5, adjustment.curveMidtones),
            (0.75, adjustment.curveHighlights),
            (1, 1)
        ]
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let x = plot.minX + plot.width * CGFloat(point.0)
            let y = plot.maxY - plot.height * CGFloat(max(0, min(1, point.1)))
            if index == 0 {
                path.move(to: NSPoint(x: x, y: y))
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }
        return path
    }

    private func drawLevelHandle(x: CGFloat, y: CGFloat, fill: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y))
        path.line(to: NSPoint(x: x - 4, y: y + 5))
        path.line(to: NSPoint(x: x - 4, y: y + 10))
        path.line(to: NSPoint(x: x + 4, y: y + 10))
        path.line(to: NSPoint(x: x + 4, y: y + 5))
        path.close()
        fill.setFill()
        NSColor.white.setStroke()
        path.lineWidth = 1.25
        path.fill()
        path.stroke()
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

        for separator in [separatorTone, separatorColor, separatorDetail, separatorReset] {
            separator.boxType = .separator
            separator.contentViewMargins = .zero
        }

        [curveView, autoLevelsButton, separatorTone, separatorColor, separatorDetail, separatorReset, enabledButton, resetButton].forEach(rootView.addSubview)

        addRow("exposure", title: "Exposure:", value: 0, range: -2...2, left: .symbol("camera.aperture", .white), right: .symbol("camera.aperture", .white))
        addRow("contrast", title: "Contrast:", value: 0, range: -1...1, left: .colorDot(.black), right: .symbol("circle.lefthalf.filled", .white))
        addRow("brightness", title: "Brightness:", value: 0, range: -1...1, left: .symbol("sun.min", .systemYellow), right: .symbol("sun.max.fill", .systemYellow))
        addRow("blackPoint", title: "Black:", value: 0, range: 0...0.45, left: .colorDot(.black), right: .symbol("square.fill", .black))
        addRow("whitePoint", title: "White:", value: 1, range: 0.55...1, left: .symbol("square.fill", NSColor(calibratedWhite: 0.82, alpha: 1)), right: .symbol("square.fill", .white))
        addRow("saturation", title: "Saturation:", value: 0, range: -1...1, left: .grayscale, right: .rgb)
        addRow("temperature", title: "Temp:", value: 0, range: -1...1, left: .symbol("thermometer.low", NSColor(calibratedRed: 0.68, green: 0.86, blue: 1, alpha: 1)), right: .symbol("thermometer.high", NSColor(calibratedRed: 1, green: 0.45, blue: 0.28, alpha: 1)))
        addRow("tint", title: "Tint:", value: 0, range: -1...1, left: .colorDot(.systemGreen), right: .colorDot(.systemPink))
        addRow("sharpness", title: "Sharpness:", value: 0, range: 0...1, left: .symbol("square", .white), right: .symbol("square.fill", .white))
        addRow("curveShadows", title: "Curve Low:", value: 0.25, range: 0...1, left: .symbol("square.fill", .black), right: .symbol("square.fill", NSColor(calibratedWhite: 0.5, alpha: 1)))
        addRow("curveMidtones", title: "Curve Mid:", value: 0.5, range: 0...1, left: .symbol("square.fill", NSColor(calibratedWhite: 0.38, alpha: 1)), right: .symbol("square.fill", NSColor(calibratedWhite: 0.62, alpha: 1)))
        addRow("curveHighlights", title: "Curve High:", value: 0.75, range: 0...1, left: .symbol("square.fill", NSColor(calibratedWhite: 0.5, alpha: 1)), right: .symbol("square.fill", .white))
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
        rows["blackPoint"]?.setValue(state.blackPoint)
        rows["whitePoint"]?.setValue(state.whitePoint)
        rows["sharpness"]?.setValue(state.sharpness)
        rows["curveShadows"]?.setValue(state.curveShadows)
        rows["curveMidtones"]?.setValue(state.curveMidtones)
        rows["curveHighlights"]?.setValue(state.curveHighlights)
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
        layoutRows(["exposure", "contrast", "brightness", "blackPoint", "whitePoint"], startY: 232)

        separatorColor.frame = NSRect(x: pad - 8, y: 356, width: max(100, bounds.width - (pad - 8) * 2), height: 1)
        layoutRows(["saturation", "temperature", "tint"], startY: 372)

        separatorDetail.frame = NSRect(x: pad - 8, y: 456, width: max(100, bounds.width - (pad - 8) * 2), height: 1)
        layoutRows(["sharpness"], startY: 472)

        let shouldHideCurveRows = true
        for key in ["curveShadows", "curveMidtones", "curveHighlights"] {
            rows[key]?.isHidden = shouldHideCurveRows
        }

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
        autoLevelsButton.isEnabled = state.isEnabled
        rows.values.forEach { $0.rowEnabled = state.isEnabled }
        onStateChanged?(state)
    }

    @objc private func autoLevelsClicked() {
        guard currentSlot != nil else { return }
        state.blackPoint = 0
        state.whitePoint = 1
        state.curveShadows = 0.25
        state.curveMidtones = 0.5
        state.curveHighlights = 0.75
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
        case "blackPoint": state.blackPoint = value
        case "whitePoint": state.whitePoint = value
        case "sharpness": state.sharpness = value
        case "curveShadows": state.curveShadows = value
        case "curveMidtones": state.curveMidtones = value
        case "curveHighlights": state.curveHighlights = value
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
