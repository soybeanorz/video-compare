import Foundation

enum Diagnostics {
    static let enabled = ProcessInfo.processInfo.environment["VIDEOCOMPARE_DEBUG"] == "1"

    static func log(_ message: String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[VideoCompare] \(message)\n".utf8))
    }
}
