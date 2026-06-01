import Foundation

struct NetworkPathTarget: Equatable {
    let host: String
    let share: String
    let pathComponents: [String]

    var mountURL: URL {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        components.path = "/\(share)/"
        return components.url ?? URL(string: "smb://\(host)/\(share)")!
    }

    func localURL(volumeURL: URL) -> URL {
        pathComponents.reduce(volumeURL.standardizedFileURL) { url, component in
            url.appendingPathComponent(component)
        }
    }
}

enum NetworkPathResolution: Equatable {
    case local(URL)
    case needsMount(mountURL: URL, target: NetworkPathTarget)
    case unsupported
}

enum NetworkPathResolver {
    static func resolve(_ input: String) -> NetworkPathResolution {
        resolve(input, mountedVolumes: mountedVolumeURLs(), volumesRoot: URL(fileURLWithPath: "/Volumes", isDirectory: true))
    }

    static func resolve(
        _ input: String,
        mountedVolumes: [URL],
        volumesRoot: URL
    ) -> NetworkPathResolution {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = parse(trimmed) else { return .unsupported }
        if let mounted = mountedVolumeURL(for: target, mountedVolumes: mountedVolumes, volumesRoot: volumesRoot) {
            return .local(target.localURL(volumeURL: mounted))
        }
        return .needsMount(mountURL: target.mountURL, target: target)
    }

    static func parse(_ input: String) -> NetworkPathTarget? {
        let trimmed = networkPathCandidate(from: input)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("\\\\") {
            return parseUNC(trimmed)
        }
        guard let url = URLComponents(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "smb" || scheme == "cifs",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        let components = pathComponents(fromPercentEncodedPath: url.percentEncodedPath)
        guard let share = components.first, !share.isEmpty else { return nil }
        return NetworkPathTarget(host: host.lowercased(), share: share, pathComponents: Array(components.dropFirst()))
    }

    static func mountedVolumeURL(for target: NetworkPathTarget) -> URL? {
        mountedVolumeURL(for: target, mountedVolumes: mountedVolumeURLs(), volumesRoot: URL(fileURLWithPath: "/Volumes", isDirectory: true))
    }

    private static func mountedVolumeURL(for target: NetworkPathTarget, mountedVolumes: [URL], volumesRoot: URL) -> URL? {
        let matchingRemount = mountedVolumes.first { volume in
            guard let remount = try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
                  let parsed = parse(remount.absoluteString) else {
                return false
            }
            return parsed.host.caseInsensitiveCompare(target.host) == .orderedSame && parsed.share == target.share
        }
        if let matchingRemount {
            return matchingRemount.standardizedFileURL
        }

        let fallback = volumesRoot.appendingPathComponent(target.share, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fallback.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return fallback
        }
        return nil
    }

    private static func mountedVolumeURLs() -> [URL] {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: []) ?? []
    }

    private static func parseUNC(_ input: String) -> NetworkPathTarget? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\\\\") else { return nil }
        let rawComponents = trimmed
            .dropFirst(2)
            .split(separator: "\\", omittingEmptySubsequences: true)
            .map(String.init)
        guard rawComponents.count >= 2 else { return nil }
        return NetworkPathTarget(
            host: rawComponents[0].lowercased(),
            share: rawComponents[1],
            pathComponents: Array(rawComponents.dropFirst(2))
        )
    }

    private static func networkPathCandidate(from input: String) -> String {
        let trimmed = trimExtractedCandidate(input)
        guard !trimmed.isEmpty else { return "" }
        if parseableNetworkPrefix(trimmed) {
            return trimmed
        }

        for line in input.components(separatedBy: .newlines) {
            if let range = line.range(of: "smb://", options: [.caseInsensitive]) ??
                line.range(of: "cifs://", options: [.caseInsensitive]) {
                return trimExtractedCandidate(String(line[range.lowerBound...]))
            }
            if let range = line.range(of: "\\\\") {
                return trimExtractedCandidate(String(line[range.lowerBound...]))
            }
        }
        return trimmed
    }

    private static func parseableNetworkPrefix(_ input: String) -> Bool {
        let lowercased = input.lowercased()
        return lowercased.hasPrefix("smb://") || lowercased.hasPrefix("cifs://") || input.hasPrefix("\\\\")
    }

    private static func trimExtractedCandidate(_ input: String) -> String {
        var result = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，。；;、"))
        result = result.trimmingCharacters(in: trailingCharacters)
        while let range = result.range(of: #"\[[^/\[\]\\]{1,12}\]$"#, options: .regularExpression) {
            result.removeSubrange(range)
            result = result.trimmingCharacters(in: trailingCharacters)
        }
        return result
    }

    private static func pathComponents(fromPercentEncodedPath path: String) -> [String] {
        path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { component in
                String(component).removingPercentEncoding ?? String(component)
            }
    }
}
