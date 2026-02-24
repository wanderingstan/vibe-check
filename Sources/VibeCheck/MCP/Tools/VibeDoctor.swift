import Foundation

/// vibe_doctor - Troubleshoot vibe-check setup
struct VibeDoctor {
    static func execute(args: ToolArguments, dbPath: String) async throws -> String {
        var output = "## Vibe-Check Diagnostic Report\n\n"

        // Check if database exists
        output += "### Database\n"
        if FileManager.default.fileExists(atPath: dbPath) {
            output += "✅ Database found at: `\(dbPath)`\n\n"

            // Get database stats
            let db = MCPDatabase(dbPath: dbPath)
            do {
                let statsSql = """
                    SELECT
                        COUNT(*) as total_events,
                        COUNT(DISTINCT event_session_id) as total_sessions,
                        MAX(event_timestamp) as last_event
                    FROM conversation_events
                """
                let stats = try await db.executeQuery(statsSql)
                if let s = stats.first {
                    output += "**Database Statistics**:\n"
                    output += "- Total events: \(s.getInt("total_events") ?? 0)\n"
                    output += "- Total sessions: \(s.getInt("total_sessions") ?? 0)\n"
                    output += "- Last event: \(s.getString("last_event") ?? "N/A")\n\n"
                }
            } catch {
                output += "⚠️  Could not query database: \(error)\n\n"
            }
        } else {
            output += "❌ Database not found at: `\(dbPath)`\n\n"
            output += "The database will be created when VibeCheck starts monitoring.\n\n"
        }

        // Check configuration
        output += "### Configuration\n"
        let defaults = UserDefaults.standard
        let conversationDir = defaults.string(forKey: "conversationDirectory") ?? "~/.claude/projects"
        let apiURL = defaults.string(forKey: "apiURL") ?? "(not set)"
        let apiKeySet = !(defaults.string(forKey: "apiKey") ?? "").isEmpty

        // Sync status comes from the sync_scopes table (source of truth)
        var hasSyncAll = false
        var sessionScopeCount = 0
        if FileManager.default.fileExists(atPath: dbPath) {
            let db = MCPDatabase(dbPath: dbPath)
            if let scopeStats = try? await db.executeQuery(
                "SELECT scope_type, COUNT(*) as cnt FROM sync_scopes GROUP BY scope_type"
            ) {
                for row in scopeStats {
                    let t = row.getString("scope_type") ?? ""
                    let c = row.getInt("cnt") ?? 0
                    if t == "all" { hasSyncAll = c > 0 }
                    if t == "session" { sessionScopeCount = c }
                }
            }
        }

        output += "**Key Settings**:\n"
        output += "- Conversation directory: `\(conversationDir)`\n"
        if hasSyncAll {
            output += "- Remote sync: ✅ Enabled (all events)\n"
        } else if sessionScopeCount > 0 {
            output += "- Remote sync: ✅ Selective (\(sessionScopeCount) shared session(s))\n"
        } else {
            output += "- Remote sync: ⬜ Disabled (local only)\n"
        }
        output += "- API URL: `\(apiURL)`\n"
        output += "- API key: \(apiKeySet ? "✅ Set" : "❌ Not set")\n"
        output += "\n"

        // Check if conversation directory exists
        let expandedConvDir = NSString(string: conversationDir).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expandedConvDir) {
            output += "✅ Conversation directory exists\n\n"

            // Count .jsonl files
            do {
                let enumerator = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: expandedConvDir),
                    includingPropertiesForKeys: [.isRegularFileKey]
                )
                var jsonlCount = 0
                while let fileURL = enumerator?.nextObject() as? URL {
                    if fileURL.pathExtension == "jsonl" {
                        jsonlCount += 1
                    }
                }
                output += "Found \(jsonlCount) conversation file(s)\n\n"
            } catch {
                output += "⚠️  Could not scan directory: \(error)\n\n"
            }
        } else {
            output += "⚠️  Conversation directory not found: `\(expandedConvDir)`\n\n"
        }

        // Recommendations
        output += "### Status\n\n"
        if FileManager.default.fileExists(atPath: dbPath) {
            output += "✅ VibeCheck appears to be configured and running correctly.\n\n"
        } else {
            output += "**Next Steps**:\n"
            output += "1. Launch VibeCheck from Applications folder\n"
            output += "2. Use Claude Code to generate some conversations\n"
            output += "3. Check the menubar icon for monitoring status\n\n"
        }

        // Additional help
        output += "### Application Info\n\n"
        output += "- Database location: `\(dbPath)`\n"
        output += "- Preferences: `~/Library/Preferences/com.wanderingstan.vibe-check.plist`\n"
        output += "- View settings: Click the menubar icon → Settings\n"

        return output
    }
}
