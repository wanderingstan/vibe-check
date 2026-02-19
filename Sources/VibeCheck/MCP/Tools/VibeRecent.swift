import Foundation
import GRDB

/// vibe_recent - Get recent Claude Code sessions
struct VibeRecent {
    static func execute(args: ToolArguments, dbPath: String) async throws -> String {
        let db = MCPDatabase(dbPath: dbPath)
        let period = args.getString("period") ?? "today"
        let limit = args.getInt("limit") ?? 10

        let dateFilter: String
        switch period {
        case "today":
            dateFilter = "DATE(event_timestamp) = DATE('now')"
        case "yesterday":
            dateFilter = "DATE(event_timestamp) = DATE('now', '-1 day')"
        case "week":
            dateFilter = "DATE(event_timestamp) >= DATE('now', '-7 days')"
        case "month":
            dateFilter = "DATE(event_timestamp) >= DATE('now', '-30 days')"
        default:
            dateFilter = "DATE(event_timestamp) = DATE('now')"
        }

        // Get sessions with summary
        let sessionsSql = """
            WITH session_summary AS (
                SELECT
                    event_session_id,
                    MIN(event_timestamp) as session_start,
                    MAX(event_timestamp) as session_end,
                    COUNT(*) as event_count,
                    COUNT(CASE WHEN event_type = 'user' THEN 1 END) as user_messages,
                    COUNT(CASE WHEN event_type = 'assistant' THEN 1 END) as assistant_messages,
                    git_remote_url,
                    event_git_branch
                FROM conversation_events
                WHERE \(dateFilter)
                    AND event_session_id IS NOT NULL
                GROUP BY event_session_id
            )
            SELECT
                event_session_id,
                session_start,
                session_end,
                ROUND((JULIANDAY(session_end) - JULIANDAY(session_start)) * 24 * 60, 1) as duration_minutes,
                user_messages,
                assistant_messages,
                event_count,
                git_remote_url,
                event_git_branch
            FROM session_summary
            ORDER BY session_start DESC
            LIMIT ?
        """

        let sessions = try await db.executeQuery(sessionsSql, arguments: [limit])

        if sessions.isEmpty {
            return "No sessions found for \(period).\n\nThe monitor may not have been running during this period."
        }

        // Get first user message for each session
        var firstMessages: [String: String] = [:]
        for s in sessions {
            if let sessionId = s.getString("event_session_id") {
                let sql = """
                    SELECT SUBSTR(event_message, 1, 100) as first_msg
                    FROM conversation_events
                    WHERE event_session_id = ?
                        AND event_type = 'user'
                        AND event_message IS NOT NULL
                    ORDER BY line_number ASC
                    LIMIT 1
                """
                let msg = try await db.executeQuery(sql, arguments: [sessionId])
                if let firstMsg = msg.first?.getString("first_msg") {
                    firstMessages[sessionId] = firstMsg
                }
            }
        }

        var output = "## Recent Work (\(period.capitalized))\n\n"
        output += "Found \(sessions.count) session(s):\n\n"

        for s in sessions {
            let sessionShort = s.getString("event_session_id").map { String($0.prefix(8)) + "..." } ?? "unknown"
            let repo: String
            if let remoteUrl = s.getString("git_remote_url") {
                repo = remoteUrl.split(separator: "/").last?.replacingOccurrences(of: ".git", with: "") ?? "(no repo)"
            } else {
                repo = "(no repo)"
            }
            let branch = s.getString("event_git_branch") ?? "unknown"
            let duration = s.getDouble("duration_minutes") ?? 0

            output += "### Session \(sessionShort)\n"
            output += "- **Repository**: \(repo)\n"
            output += "- **Branch**: \(branch)\n"
            output += "- **Duration**: \(String(format: "%.0f", duration)) minutes\n"
            output += "- **Activity**: \(s.getInt("user_messages") ?? 0) user, \(s.getInt("assistant_messages") ?? 0) assistant messages\n"
            output += "- **Started**: \(s.getString("session_start") ?? "unknown")\n"

            if let sessionId = s.getString("event_session_id"),
               var msg = firstMessages[sessionId]
            {
                if msg.count >= 100 {
                    msg += "..."
                }
                output += "- **First message**: _\(msg)_\n"
            }

            output += "\n"
        }

        return output
    }
}
