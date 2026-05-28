import Foundation

enum VideoSlot: String, Codable {
    case a
    case b
}

enum CompareLayout: Int, CaseIterable {
    case sideBySideHorizontal = 0
    case overlapWipe = 1

    var title: String {
        switch self {
        case .sideBySideHorizontal: "左右"
        case .overlapWipe: "拖动遮罩"
        }
    }
}

struct TransformState: Codable, Equatable {
    var panX: Double = 0
    var panY: Double = 0
    var zoom: Double = 0
}

struct ToneCurveRegion: Equatable {
    let title: String
    let shortTitle: String
    let inputStart: Double
    let inputEnd: Double

    var inputCenter: Double {
        (inputStart + inputEnd) / 2
    }
}

struct ToneCurveState: Equatable {
    static let lutSize = 256
    static let minCenterSpacing = 0.035
    static let regions: [ToneCurveRegion] = [
        ToneCurveRegion(title: "Blacks", shortTitle: "B", inputStart: 0.00, inputEnd: 0.10),
        ToneCurveRegion(title: "Shadows", shortTitle: "S", inputStart: 0.10, inputEnd: 0.35),
        ToneCurveRegion(title: "Midtones", shortTitle: "M", inputStart: 0.35, inputEnd: 0.65),
        ToneCurveRegion(title: "Lights", shortTitle: "L", inputStart: 0.65, inputEnd: 0.90),
        ToneCurveRegion(title: "Highlights", shortTitle: "H", inputStart: 0.90, inputEnd: 1.00)
    ]
    static let neutralCenters = regions.map(\.inputCenter)

    var centers: [Double]

    init(centers: [Double] = ToneCurveState.neutralCenters) {
        self.centers = Self.constrainedCenters(centers)
    }

    func movingRegion(_ index: Int, by delta: Double) -> ToneCurveState {
        guard centers.indices.contains(index) else { return self }
        let pivot = centers[index]
        let movedPivot = min(1 - Self.minCenterSpacing, max(Self.minCenterSpacing, pivot + delta))
        guard abs(movedPivot - pivot) > 0.000001 else { return self }

        let lowerScale = movedPivot / max(Self.minCenterSpacing, pivot)
        let upperScale = (1 - movedPivot) / max(Self.minCenterSpacing, 1 - pivot)
        let nextCenters = centers.enumerated().map { centerIndex, center in
            if centerIndex < index {
                return center * lowerScale
            }
            if centerIndex > index {
                return movedPivot + (center - pivot) * upperScale
            }
            return movedPivot
        }
        return ToneCurveState(centers: nextCenters)
    }

    func makeLUT(size: Int = ToneCurveState.lutSize) -> [Float] {
        let count = max(2, size)
        return (0..<count).map { index in
            let input = Double(index) / Double(count - 1)
            return Float(sample(input))
        }
    }

    func sample(_ input: Double) -> Double {
        let x = controlInputs
        let y = controlOutputs
        let tangents = monotoneTangents(inputs: x, outputs: y)
        let value = min(1, max(0, input))
        for index in 0..<(x.count - 1) where value <= x[index + 1] {
            let h = x[index + 1] - x[index]
            let t = (value - x[index]) / max(0.0001, h)
            let t2 = t * t
            let t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            return min(1, max(0, h00 * y[index] + h10 * h * tangents[index] + h01 * y[index + 1] + h11 * h * tangents[index + 1]))
        }
        return value
    }

    static func sampleLUT(_ lut: [Float], input: Double) -> Double {
        guard lut.count >= 2 else { return min(1, max(0, input)) }
        let value = min(1, max(0, input))
        let position = value * Double(lut.count - 1)
        let left = min(lut.count - 1, max(0, Int(position.rounded(.down))))
        let right = min(lut.count - 1, left + 1)
        let t = position - Double(left)
        return Double(lut[left]) + (Double(lut[right]) - Double(lut[left])) * t
    }

    private var controlInputs: [Double] {
        [0] + Self.regions.map(\.inputCenter) + [1]
    }

    private var controlOutputs: [Double] {
        [0] + centers + [1]
    }

    private static func constrainedCenters(_ rawCenters: [Double]) -> [Double] {
        var result = neutralCenters
        for index in result.indices where rawCenters.indices.contains(index) {
            result[index] = min(1, max(0, rawCenters[index]))
        }
        for index in result.indices {
            let lower = index == 0 ? minCenterSpacing : result[index - 1] + minCenterSpacing
            result[index] = max(lower, result[index])
        }
        for index in result.indices.reversed() {
            let upper = index == result.count - 1 ? 1 - minCenterSpacing : result[index + 1] - minCenterSpacing
            result[index] = min(upper, result[index])
        }
        return result.map { min(1 - minCenterSpacing, max(minCenterSpacing, $0)) }
    }

    private func monotoneTangents(inputs x: [Double], outputs y: [Double]) -> [Double] {
        guard x.count == y.count, x.count >= 2 else { return Array(repeating: 1, count: x.count) }
        let count = x.count
        var slopes = Array(repeating: 0.0, count: count - 1)
        for index in 0..<(count - 1) {
            slopes[index] = (y[index + 1] - y[index]) / max(0.0001, x[index + 1] - x[index])
        }

        var tangents = Array(repeating: 0.0, count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]
        if count > 2 {
            for index in 1..<(count - 1) {
                tangents[index] = (slopes[index - 1] + slopes[index]) / 2
            }
        }

        for index in 0..<(count - 1) {
            if abs(slopes[index]) < 0.0001 {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }
            let alpha = tangents[index] / slopes[index]
            let beta = tangents[index + 1] / slopes[index]
            let sum = alpha * alpha + beta * beta
            if sum > 9 {
                let tau = 3 / sqrt(sum)
                tangents[index] = tau * alpha * slopes[index]
                tangents[index + 1] = tau * beta * slopes[index]
            }
        }
        return tangents
    }
}

struct ColorAdjustmentState: Equatable {
    var isEnabled = true
    var exposure: Double = 0
    var contrast: Double = 0
    var brightness: Double = 0
    var saturation: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var sharpness: Double = 0
    var toneCurve: ToneCurveState {
        didSet {
            toneCurveLUT = toneCurve.makeLUT()
        }
    }
    private(set) var toneCurveLUT: [Float]

    init(
        isEnabled: Bool = true,
        exposure: Double = 0,
        contrast: Double = 0,
        brightness: Double = 0,
        saturation: Double = 0,
        temperature: Double = 0,
        tint: Double = 0,
        sharpness: Double = 0,
        toneCurve: ToneCurveState = ToneCurveState()
    ) {
        self.isEnabled = isEnabled
        self.exposure = exposure
        self.contrast = contrast
        self.brightness = brightness
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
        self.sharpness = sharpness
        self.toneCurve = toneCurve
        self.toneCurveLUT = toneCurve.makeLUT()
    }

    static let histogramBinCount = 64

    static func defaultHistogram() -> [Double] {
        Array(repeating: 0, count: histogramBinCount)
    }
}

enum ColorAdjustmentControlRanges {
    static let standardTemperatureTint: ClosedRange<Double> = -1...1
    static let rawTemperatureTint: ClosedRange<Double> = -1...1
}

struct RawNeutralDefaults: Equatable {
    var temperature: Double
    var tint: Double
}

enum RawTemperatureTintMapper {
    static let temperatureDelta: Double = 8000
    static let tintDelta: Double = 300
    static let temperatureBounds: ClosedRange<Double> = 1500...50000
    static let tintBounds: ClosedRange<Double> = -1000...1000

    static func mappedNeutral(defaults: RawNeutralDefaults, adjustment: ColorAdjustmentState) -> RawNeutralDefaults {
        RawNeutralDefaults(
            temperature: clamp(defaults.temperature + adjustment.temperature * temperatureDelta, to: temperatureBounds),
            tint: clamp(defaults.tint + adjustment.tint * tintDelta, to: tintBounds)
        )
    }

    static func uiAdjustment(defaults: RawNeutralDefaults, neutral: RawNeutralDefaults) -> (temperature: Double, tint: Double) {
        (
            clamp((neutral.temperature - defaults.temperature) / temperatureDelta, to: ColorAdjustmentControlRanges.rawTemperatureTint),
            clamp((neutral.tint - defaults.tint) / tintDelta, to: ColorAdjustmentControlRanges.rawTemperatureTint)
        )
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

enum WhiteBalanceSolver {
    struct RGBSample: Equatable {
        var r: Double
        var g: Double
        var b: Double
    }

    static func temperatureTintCorrection(
        sample: RGBSample,
        baseAdjustment: ColorAdjustmentState,
        range: ClosedRange<Double>
    ) -> (temperature: Double, tint: Double)? {
        guard sample.r.isFinite, sample.g.isFinite, sample.b.isFinite else { return nil }
        let preprocessed = preprocess(sample: sample, adjustment: baseAdjustment)
        let luma = preprocessed.r * 0.2126 + preprocessed.g * 0.7152 + preprocessed.b * 0.0722
        guard luma >= 0.04, luma <= 0.96 else { return nil }
        guard !isUnreliablePureColor(preprocessed) else { return nil }

        let temperature = (preprocessed.b - preprocessed.r) / 0.16
        let tint = (2 * preprocessed.g - preprocessed.r - preprocessed.b) / 0.18
        return (
            min(range.upperBound, max(range.lowerBound, temperature)),
            min(range.upperBound, max(range.lowerBound, tint))
        )
    }

    private static func preprocess(sample: RGBSample, adjustment: ColorAdjustmentState) -> RGBSample {
        var r = sample.r * pow(2, adjustment.exposure) + adjustment.brightness * 0.35
        var g = sample.g * pow(2, adjustment.exposure) + adjustment.brightness * 0.35
        var b = sample.b * pow(2, adjustment.exposure) + adjustment.brightness * 0.35

        let contrast = 1 + adjustment.contrast * 1.5
        r = (r - 0.5) * contrast + 0.5
        g = (g - 0.5) * contrast + 0.5
        b = (b - 0.5) * contrast + 0.5
        return RGBSample(r: r, g: g, b: b)
    }

    private static func isUnreliablePureColor(_ sample: RGBSample) -> Bool {
        let channels = [sample.r, sample.g, sample.b]
        guard let minChannel = channels.min(), let maxChannel = channels.max() else { return true }
        return minChannel < 0.025 && maxChannel > 0.85
    }
}

struct ColorHistogram: Equatable {
    var red: [Double] = ColorAdjustmentState.defaultHistogram()
    var green: [Double] = ColorAdjustmentState.defaultHistogram()
    var blue: [Double] = ColorAdjustmentState.defaultHistogram()

    static let empty = ColorHistogram()

    var isEmpty: Bool {
        !red.contains { $0 > 0 } && !green.contains { $0 > 0 } && !blue.contains { $0 > 0 }
    }
}

struct SyncState: Codable, Equatable {
    var offsetFramesA: Int = 0
    var offsetFramesB: Int = 0
    var transformA = TransformState()
    var transformB = TransformState()
}

struct FileIdentity: Codable, Hashable {
    let path: String
    let size: UInt64
    let modifiedTime: TimeInterval

    init(url: URL) {
        path = url.path
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        modifiedTime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }
}

struct VideoPairIdentity: Codable, Hashable {
    let a: FileIdentity
    let b: FileIdentity

    var key: String {
        "\(a.path)|\(a.size)|\(Int(a.modifiedTime))::\(b.path)|\(b.size)|\(Int(b.modifiedTime))"
    }
}

struct RecentPair: Codable, Equatable {
    let aPath: String
    let bPath: String
    let lastOpened: Date

    var title: String {
        "\(URL(fileURLWithPath: aPath).lastPathComponent)  /  \(URL(fileURLWithPath: bPath).lastPathComponent)"
    }
}
