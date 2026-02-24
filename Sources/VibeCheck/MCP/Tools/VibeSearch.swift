import Foundation
import GRDB

/// vibe_search - Search conversation history with FTS5
struct VibeSearch {
    static func execute(args: ToolArguments, dbPath: String) async throws -> String {
        let db = MCPDatabase(dbPath: dbPath)

        guard let query = args.getString("query") else {
            return "Error: 'query' parameter is required"
        }

        let repo = args.getString("repo")
        let days = args.getInt("days")
        let sessionId = args.getString("session_id")
        let limit = args.getInt("limit") ?? 20

        // Check if FTS5 table exists
        let ftsCheckSql = "SELECT name FROM sqlite_master WHERE type='table' AND name='messages_fts'"
        let ftsCheck = try await db.executeQuery(ftsCheckSql)
        let useFts = !ftsCheck.isEmpty

        let results: [[String: DatabaseValue]]

        if useFts {
            // Use FTS5 with relevance ranking
            var params: [DatabaseValueConvertible] = [query]

            var filterClauses: [String] = []
            if let repo = repo {
                filterClauses.append("ce.git_remote_url LIKE ?")
                params.append("%\(repo)%")
            }
            if let days = days {
                filterClauses.append("DATE(ce.event_timestamp) >= DATE('now', ?)")
                params.append("-\(days) days")
            }
            if let sessionId = sessionId {
                filterClauses.append("ce.event_session_id = ?")
                params.append(sessionId)
            }

            let filterSql = filterClauses.isEmpty ? "" : " AND " + filterClauses.joined(separator: " AND ")
            params.append(limit)

            let sql = """
                SELECT
                    ce.event_session_id,
                    ce.event_type,
                    SUBSTR(ce.event_message, 1, 150) as message_preview,
                    ce.event_timestamp,
                    ce.git_remote_url,
                    ce.file_name,
                    fts.rank as relevance
                FROM messages_fts fts
                JOIN conversation_events ce ON ce.id = fts.rowid
                WHERE messages_fts MATCH ?
                    \(filterSql)
                ORDER BY fts.rank, ce.event_timestamp DESC
                LIMIT ?
            """

            do {
                results = try await db.executeQuery(sql, arguments: params)
            } catch {
                // If FTS5 query fails (invalid syntax), provide helpful error
                if error.localizedDescription.lowercased().contains("fts5") ||
                    error.localizedDescription.lowercased().contains("syntax")
                {
                    return """
                        Search syntax error: \(error)

                        FTS5 query syntax:
                        - Simple: authentication
                        - Phrase: "user login"
                        - Boolean: auth AND oauth
                        - Exclude: login NOT password
                        - Prefix: auth*
                        """
                }
                throw error
            }
        } else {
            // Fall back to LIKE queries
            var whereClauses = ["event_message LIKE ?"]
            var params: [DatabaseValueConvertible] = ["%\(query)%"]

            if let repo = repo {
                whereClauses.append("git_remote_url LIKE ?")
                params.append("%\(repo)%")
            }
            if let days = days {
                whereClauses.append("DATE(event_timestamp) >= DATE('now', ?)")
                params.append("-\(days) days")
            }
            if let sessionId = sessionId {
                whereClauses.append("event_session_id = ?")
                params.append(sessionId)
            }

            let whereSql = whereClauses.joined(separator: " AND ")
            params.append(limit)

            let sql = """
                SELECT
                    event_session_id,
                    event_type,
                    SUBSTR(event_message, 1, 150) as message_preview,
                    event_timestamp,
                    git_remote_url,
                    file_name
                FROM conversation_events
                WHERE \(whereSql)
                    AND event_message IS NOT NULL
                ORDER BY event_timestamp DESC
                LIMIT ?
            """

            results = try await db.executeQuery(sql, arguments: params)
        }

        if results.isEmpty {
            var tips = "Try:\n- Broader search terms\n- Different date range\n- Checking if the monitor was running"
            if useFts {
                tips += "\n- Prefix matching: \"auth*\"\n- Phrase search: \"user login\""
            }
            return "No results found for '\(query)'.\n\n\(tips)"
        }

        var output = "## Search Results for '\(query)'\n\n"
        output += "Found \(results.count) matching messages"
        if useFts {
            output += " (ranked by relevance)"
        }
        output += ":\n\n"

        var currentSession: String? = nil
        for r in results {
            let sessionId = r.getString("event_session_id")
            if sessionId != currentSession {
                currentSession = sessionId
                let repoName: String
                if let remoteUrl = r.getString("git_remote_url") {
                    repoName = remoteUrl.split(separator: "/").last?.replacingOccurrences(of: ".git", with: "") ?? "(no repo)"
                } else {
                    repoName = "(no repo)"
                }
                let sessionShort = sessionId.map { String($0.prefix(8)) + "..." } ?? "unknown"
                output += "\n### Session \(sessionShort) (\(repoName))\n"
            }

            let msgType = r.getString("event_type") ?? "unknown"
            var preview = r.getString("message_preview") ?? ""
            if preview.count >= 150 {
                preview += "..."
            }

            // Show relevance score for FTS5 results
            var relevanceIndicator = ""
            if useFts, let relevance = r.getDouble("relevance") {
                let rankValue = abs(relevance)
                if rankValue < 1.0 {
                    relevanceIndicator = " ⭐⭐⭐"
                } else if rankValue < 5.0 {
                    relevanceIndicator = " ⭐⭐"
                } else if rankValue < 10.0 {
                    relevanceIndicator = " ⭐"
                }
            }

            output += "- [\(msgType)]\(relevanceIndicator) \(preview)\n"
            output += "  _\(r.getString("event_timestamp") ?? "unknown")_\n"
        }

        return output
    }
}
