import Foundation

enum VideoSlot: String, Codable {
    case a
    case b
}

enum CompareLayout: Int, CaseIterable {
    case sideBySideHorizontal = 0
    case sideBySideVertical = 1
    case overlapToggle = 2
    case overlapWipe = 3

    var title: String {
        switch self {
        case .sideBySideHorizontal: "左右"
        case .sideBySideVertical: "上下"
        case .overlapToggle: "点击切换"
        case .overlapWipe: "拖动遮罩"
        }
    }
}

struct TransformState: Codable, Equatable {
    var panX: Double = 0
    var panY: Double = 0
    var zoom: Double = 0
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
