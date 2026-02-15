import Foundation
import AppKit

/// vibe_open_stats - Open web-based stats page in browser
struct VibeOpenStats {
    static func execute(args: ToolArguments, dbPath: String) async throws -> String {
        // Read UserDefaults for API configuration
        let defaults = UserDefaults.standard
        let apiEnabled = defaults.bool(forKey: "apiEnabled")

        if !apiEnabled {
            return """
                Remote stats are disabled in your configuration.

                You're currently only saving conversations locally to SQLite.
                Use vibe_stats tool to view local statistics.
                """
        }

        let apiURL = defaults.string(forKey: "apiURL") ?? ""
        let userName = defaults.string(forKey: "userName") ?? ""

        if apiURL.isEmpty || userName.isEmpty {
            return "Remote stats enabled but URL or username is missing in config."
        }

        let statsUrl = "\(apiURL)/stats.php?user=\(userName)"

        if let url = URL(string: statsUrl) {
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
            return "Opened stats page in your browser:\n\(statsUrl)"
        } else {
            return "Could not open browser. Visit manually:\n\(statsUrl)"
        }
    }
}
