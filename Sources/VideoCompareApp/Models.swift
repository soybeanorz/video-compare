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

struct ColorAdjustmentState: Equatable {
    var isEnabled = true
    var exposure: Double = 0
    var contrast: Double = 0
    var brightness: Double = 0
    var saturation: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var blackPoint: Double = 0
    var whitePoint: Double = 1
    var sharpness: Double = 0
    var curveShadows: Double = 0.25
    var curveMidtones: Double = 0.5
    var curveHighlights: Double = 0.75

    static let histogramBinCount = 64

    static func defaultHistogram() -> [Double] {
        Array(repeating: 0, count: histogramBinCount)
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
