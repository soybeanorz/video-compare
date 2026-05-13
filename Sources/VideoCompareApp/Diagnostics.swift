import Foundation

enum Diagnostics {
    static let enabled = ProcessInfo.processInfo.environment["VIDEOCOMPARE_DEBUG"] == "1"
    private static let lock = NSLock()
    static let logURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("VideoCompare", isDirectory: true)
            .appendingPathComponent("debug.log")
    }()

    static func log(_ message: String) {
        guard enabled else { return }
        let line = "[VideoCompare] \(String(format: "%.3f", Date().timeIntervalSince1970)) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            FileHandle.standardError.write(Data("[VideoCompare] log write failed: \(error)\n".utf8))
        }
    }
}
