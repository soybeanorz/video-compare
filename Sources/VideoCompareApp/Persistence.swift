import Foundation

@MainActor
final class PersistenceStore {
    static let shared = PersistenceStore()

    private let defaults = UserDefaults.standard
    private let syncKey = "syncStates.v1"
    private let recentKey = "recentPairs.v1"

    private init() {}

    func loadState(for pair: VideoPairIdentity) -> SyncState {
        allStates()[pair.key] ?? SyncState()
    }

    func saveState(_ state: SyncState, for pair: VideoPairIdentity) {
        var states = allStates()
        states[pair.key] = state
        saveStates(states)
    }

    func clearState(for pair: VideoPairIdentity) {
        var states = allStates()
        states.removeValue(forKey: pair.key)
        saveStates(states)
    }

    func addRecent(a: URL, b: URL) {
        var recents = loadRecents()
        recents.removeAll { $0.aPath == a.path && $0.bPath == b.path }
        recents.insert(RecentPair(aPath: a.path, bPath: b.path, lastOpened: Date()), at: 0)
        recents = Array(recents.prefix(12))
        if let data = try? JSONEncoder().encode(recents) {
            defaults.set(data, forKey: recentKey)
        }
    }

    func loadRecents() -> [RecentPair] {
        guard let data = defaults.data(forKey: recentKey),
              let recents = try? JSONDecoder().decode([RecentPair].self, from: data) else {
            return []
        }
        return recents.filter {
            FileManager.default.fileExists(atPath: $0.aPath) && FileManager.default.fileExists(atPath: $0.bPath)
        }
    }

    func clearRecents() {
        defaults.removeObject(forKey: recentKey)
    }

    private func allStates() -> [String: SyncState] {
        guard let data = defaults.data(forKey: syncKey),
              let states = try? JSONDecoder().decode([String: SyncState].self, from: data) else {
            return [:]
        }
        return states
    }

    private func saveStates(_ states: [String: SyncState]) {
        if let data = try? JSONEncoder().encode(states) {
            defaults.set(data, forKey: syncKey)
        }
    }
}
