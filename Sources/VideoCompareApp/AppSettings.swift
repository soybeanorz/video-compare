import Foundation

@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private let disableSubtitlesKey = "disableSubtitles.v1"

    var disableSubtitles: Bool {
        get {
            if defaults.object(forKey: disableSubtitlesKey) == nil {
                return true
            }
            return defaults.bool(forKey: disableSubtitlesKey)
        }
        set {
            defaults.set(newValue, forKey: disableSubtitlesKey)
        }
    }
}
