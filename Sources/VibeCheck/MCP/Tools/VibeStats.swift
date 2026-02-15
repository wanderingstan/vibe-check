import Foundation
import GRDB

/// vibe_stats - Query Claude Code usage statistics
struct VibeStats {
    static func execute(args: ToolArguments, dbPath: String) async throws -> String {
        let db = MCPDatabase(dbPath: dbPath)
        let days = args.getInt("days")
        let repo = args.getString("repo")

        // Build WHERE clause
        var whereClauses: [String] = []
        var params: [DatabaseValueConvertible] = []

        if let days = days {
            whereClauses.append("DATE(event_timestamp) >= DATE('now', ?)")
            params.append("-\(days) days")
        }

        if let repo = repo {
            whereClauses.append("git_remote_url LIKE ?")
            params.append("%\(repo)%")
        }

        let whereSql = whereClauses.isEmpty ? "1=1" : whereClauses.joined(separator: " AND ")

        // Overview stats
        let overviewSql = """
            SELECT
                COUNT(*) as total_events,
                COUNT(DISTINCT event_session_id) as total_sessions,
                COUNT(DISTINCT DATE(event_timestamp)) as days_active,
                MIN(DATE(event_timestamp)) as first_use,
                MAX(DATE(event_timestamp)) as last_use
            FROM conversation_events
            WHERE \(whereSql)
        """

        let overview = try await db.executeQuery(overviewSql, arguments: params)
        let stats = overview.first ?? [:]

        // Event type breakdown
        let eventTypesSql = """
            SELECT
                event_type,
                COUNT(*) as count
            FROM conversation_events
            WHERE \(whereSql)
            GROUP BY event_type
            ORDER BY count DESC
        """

        let eventTypes = try await db.executeQuery(eventTypesSql, arguments: params)

        let totalEvents = stats.getInt("total_events") ?? 0

        // Top repositories
        let reposSql = """
            SELECT
                CASE
                    WHEN git_remote_url IS NULL THEN '(no repo)'
                    ELSE REPLACE(
                        SUBSTR(git_remote_url, INSTR(git_remote_url, '/')+1),
                        '.git', ''
                    )
                END as repository,
                COUNT(DISTINCT event_session_id) as sessions,
                COUNT(*) as events
            FROM conversation_events
            WHERE \(whereSql)
            GROUP BY git_remote_url
            ORDER BY sessions DESC
            LIMIT 10
        """

        let repos = try await db.executeQuery(reposSql, arguments: params)

        // Daily activity (last 14 days)
        let dailySql = """
            SELECT
                DATE(event_timestamp) as date,
                COUNT(*) as events,
                COUNT(DISTINCT event_session_id) as sessions
            FROM conversation_events
            WHERE \(whereSql)
            GROUP BY DATE(event_timestamp)
            ORDER BY date DESC
            LIMIT 14
        """

        let daily = try await db.executeQuery(dailySql, arguments: params)

        // Format output
        var output = "## Claude Code Usage Statistics\n\n"

        output += "### Overview\n"
        output += "- Total events: \(formatNumber(stats.getInt("total_events") ?? 0))\n"
        output += "- Sessions: \(formatNumber(stats.getInt("total_sessions") ?? 0))\n"
        output += "- Days active: \(stats.getInt("days_active") ?? 0)\n"
        output += "- First use: \(stats.getString("first_use") ?? "N/A")\n"
        output += "- Last use: \(stats.getString("last_use") ?? "N/A")\n\n"

        output += "### Event Types\n"
        for et in eventTypes.prefix(8) {
            let count = et.getInt("count") ?? 0
            let pct = totalEvents > 0 ? Double(count) / Double(totalEvents) * 100 : 0
            let eventType = et.getString("event_type") ?? "unknown"
            output += "- \(eventType): \(formatNumber(count)) (\(String(format: "%.1f", pct))%)\n"
        }
        output += "\n"

        output += "### Top Repositories\n"
        for r in repos.prefix(5) {
            let repository = r.getString("repository") ?? "unknown"
            let sessions = r.getInt("sessions") ?? 0
            let events = r.getInt("events") ?? 0
            output += "- \(repository): \(sessions) sessions, \(events) events\n"
        }
        output += "\n"

        output += "### Recent Daily Activity\n"
        for day in daily.prefix(7) {
            let date = day.getString("date") ?? "unknown"
            let events = day.getInt("events") ?? 0
            let sessions = day.getInt("sessions") ?? 0
            output += "- \(date): \(events) events, \(sessions) sessions\n"
        }

        return output
    }

    private static func formatNumber(_ num: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: num)) ?? "\(num)"
    }
}
