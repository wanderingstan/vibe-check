import Foundation
import AppKit

/// vibe_open_stats - Open web-based stats page in browser
struct VibeOpenStats {
    static func execute(args: ToolArguments, dbPath: String) async throws -> String {
        let defaults = UserDefaults.standard

        // Check sync_scopes table to see if global sync is enabled
        var hasSyncAll = false
        if FileManager.default.fileExists(atPath: dbPath) {
            let db = MCPDatabase(dbPath: dbPath)
            if let rows = try? await db.executeQuery(
                "SELECT COUNT(*) as cnt FROM sync_scopes WHERE scope_type = 'all'"
            ), let cnt = rows.first?.getInt("cnt") {
                hasSyncAll = cnt > 0
            }
        }

        if !hasSyncAll {
            return """
                Remote stats are not enabled in your configuration.

                You're currently only saving conversations locally to SQLite.
                Use vibe_stats tool to view local statistics.

                To enable remote stats, turn on "Enable Remote Sync" in VibeCheck Settings.
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
