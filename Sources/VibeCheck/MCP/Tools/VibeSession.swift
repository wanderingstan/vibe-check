import Foundation
import GRDB

/// vibe_session - Get session information
struct VibeSession {
    static func execute(args: ToolArguments, dbPath: String) async throws -> String {
        let db = MCPDatabase(dbPath: dbPath)
        let sessionId = args.getString("session_id")

        let sql: String
        let arguments: [DatabaseValueConvertible]

        if let sessionId = sessionId {
            // Look up specific session
            sql = """
                SELECT
                    event_session_id,
                    MIN(event_timestamp) as session_start,
                    MAX(event_timestamp) as session_end,
                    COUNT(*) as total_events,
                    COUNT(CASE WHEN event_type = 'user' THEN 1 END) as user_messages,
                    COUNT(CASE WHEN event_type = 'assistant' THEN 1 END) as assistant_messages,
                    git_remote_url,
                    event_git_branch,
                    file_name
                FROM conversation_events
                WHERE event_session_id = ?
                GROUP BY event_session_id
            """
            arguments = [sessionId]
        } else {
            // Get most recent session
            sql = """
                SELECT
                    event_session_id,
                    MIN(event_timestamp) as session_start,
                    MAX(event_timestamp) as session_end,
                    COUNT(*) as total_events,
                    COUNT(CASE WHEN event_type = 'user' THEN 1 END) as user_messages,
                    COUNT(CASE WHEN event_type = 'assistant' THEN 1 END) as assistant_messages,
                    git_remote_url,
                    event_git_branch,
                    file_name
                FROM conversation_events
                WHERE event_session_id IS NOT NULL
                GROUP BY event_session_id
                ORDER BY MAX(event_timestamp) DESC
                LIMIT 1
            """
            arguments = []
        }

        let results = try await db.executeQuery(sql, arguments: arguments)

        if results.isEmpty {
            return sessionId != nil ? "No session found." : "No sessions in database."
        }

        let s = results[0]

        var output = "## Session Information\n\n"
        output += "- **Session ID**: \(s.getString("event_session_id") ?? "unknown")\n"
        output += "- **Log File**: \(s.getString("file_name") ?? "unknown")\n"
        output += "- **Started**: \(s.getString("session_start") ?? "unknown")\n"
        output += "- **Last Activity**: \(s.getString("session_end") ?? "unknown")\n"
        output += "- **Total Events**: \(s.getInt("total_events") ?? 0)\n"
        output += "- **Messages**: \(s.getInt("user_messages") ?? 0) user, \(s.getInt("assistant_messages") ?? 0) assistant\n"

        if let remoteUrl = s.getString("git_remote_url") {
            let repo = remoteUrl.split(separator: "/").last?.replacingOccurrences(of: ".git", with: "") ?? "unknown"
            output += "- **Repository**: \(repo)\n"
        }
        if let branch = s.getString("event_git_branch") {
            output += "- **Branch**: \(branch)\n"
        }

        return output
    }
}
