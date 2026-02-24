import Foundation
import GRDB

/// vibe_tools - Analyze Claude's tool usage patterns
struct VibeTools {
    static func execute(args: ToolArguments, dbPath: String) async throws -> String {
        let db = MCPDatabase(dbPath: dbPath)
        let days = args.getInt("days") ?? 30
        let repo = args.getString("repo")
        let showCombinations = args.getBool("show_combinations") ?? false

        // Build WHERE clause
        var whereClauses = [
            "event_type = 'assistant'",
            "DATE(event_timestamp) >= DATE('now', '-\(days) days')",
        ]
        var params: [DatabaseValueConvertible] = []

        if let repo = repo {
            whereClauses.append("git_remote_url LIKE ?")
            params.append("%\(repo)%")
        }

        let whereSql = whereClauses.joined(separator: " AND ")

        // Top tools
        let toolsSql = """
            SELECT
                json_extract(value, '$.name') as tool_name,
                COUNT(*) as usage_count
            FROM conversation_events,
                 json_each(json_extract(event_data, '$.message.content'))
            WHERE \(whereSql)
                AND json_extract(value, '$.type') = 'tool_use'
                AND json_extract(value, '$.name') IS NOT NULL
            GROUP BY tool_name
            ORDER BY usage_count DESC
        """

        let tools = try await db.executeQuery(toolsSql, arguments: params)

        var output = "## Tool Usage Analysis (Last \(days) Days)\n\n"

        if tools.isEmpty {
            return output + "No tool usage data found for this period."
        }

        let totalUses = tools.reduce(0) { $0 + ($1.getInt("usage_count") ?? 0) }

        output += "### Most Used Tools\n"
        for t in tools.prefix(10) {
            let toolName = t.getString("tool_name") ?? "unknown"
            let usageCount = t.getInt("usage_count") ?? 0
            let pct = Double(usageCount) / Double(totalUses) * 100
            let barLen = Int(pct / 5)
            let bar = String(repeating: "#", count: barLen) + String(repeating: ".", count: 20 - barLen)
            output += "- **\(toolName)**: \(formatNumber(usageCount)) (\(String(format: "%.1f", pct))%) [\(bar)]\n"
        }
        output += "\n_Total tool uses: \(formatNumber(totalUses))_\n\n"

        if showCombinations {
            // Tool combinations
            let combosSql = """
                WITH tool_sessions AS (
                    SELECT
                        event_session_id,
                        json_extract(value, '$.name') as tool_name
                    FROM conversation_events,
                         json_each(json_extract(event_data, '$.message.content'))
                    WHERE \(whereSql)
                        AND json_extract(value, '$.type') = 'tool_use'
                        AND json_extract(value, '$.name') IS NOT NULL
                )
                SELECT
                    a.tool_name as tool_1,
                    b.tool_name as tool_2,
                    COUNT(DISTINCT a.event_session_id) as sessions_together
                FROM tool_sessions a
                JOIN tool_sessions b ON a.event_session_id = b.event_session_id
                WHERE a.tool_name < b.tool_name
                GROUP BY a.tool_name, b.tool_name
                ORDER BY sessions_together DESC
                LIMIT 10
            """

            let combos = try await db.executeQuery(combosSql, arguments: params)

            output += "### Common Tool Combinations\n"
            for c in combos {
                let tool1 = c.getString("tool_1") ?? "unknown"
                let tool2 = c.getString("tool_2") ?? "unknown"
                let sessionsTogether = c.getInt("sessions_together") ?? 0
                output += "- \(tool1) + \(tool2): \(sessionsTogether) sessions\n"
            }
        }

        return output
    }

    private static func formatNumber(_ num: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: num)) ?? "\(num)"
    }
}
