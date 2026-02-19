import Foundation

/// App settings using macOS UserDefaults
/// Settings are stored in ~/Library/Preferences/com.wanderingstan.vibe-check.plist
class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private init() {
        // Register default values on first launch
        registerDefaults()
    }

    private func registerDefaults() {
        let defaults: [String: Any] = [
            "conversationDirectory": "~/.claude/projects",
            "apiEnabled": false,
            "apiURL": "https://vibecheck.wanderingstan.com/api",
            "launchAtLogin": false
        ]

        UserDefaults.standard.register(defaults: defaults)
    }

    // MARK: - Monitor Settings

    var conversationDirectory: String {
        get {
            let path = defaults.string(forKey: "conversationDirectory") ?? "~/.claude/projects"
            return NSString(string: path).expandingTildeInPath
        }
        set {
            defaults.set(newValue, forKey: "conversationDirectory")
        }
    }

    // MARK: - API Sync Settings

    /// Deprecated: use DatabaseManager.hasSyncAllScope() instead.
    /// Only kept for AppDelegate migration (reads legacy value on first launch).
    var apiEnabled: Bool {
        get { defaults.bool(forKey: "apiEnabled") }
        set { defaults.set(newValue, forKey: "apiEnabled") }
    }

    var apiURL: String {
        get { defaults.string(forKey: "apiURL") ?? "https://vibecheck.wanderingstan.com/api" }
        set { defaults.set(newValue, forKey: "apiURL") }
    }

    var apiKey: String? {
        get { defaults.string(forKey: "apiKey") }
        set { defaults.set(newValue, forKey: "apiKey") }
    }

    // MARK: - UI Settings

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    // MARK: - Utility

    /// Reset all settings to defaults
    func resetToDefaults() {
        if let bundleID = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleID)
        }
        registerDefaults()
    }

    /// Print current settings (for debugging)
    func printSettings() {
        print("🔧 Current Settings:")
        print("  Conversation Directory: \(conversationDirectory)")
        print("  API Enabled: \(apiEnabled)")
        print("  API URL: \(apiURL)")
        print("  API Key: \(apiKey != nil ? "***SET***" : "NOT SET")")
        print("  Launch at Login: \(launchAtLogin)")
    }
}
