import Foundation
import GRDB

/// vibe_sql - Execute raw SQL queries (read-only)
struct VibeSQL {
    static func execute(args: ToolArguments, dbPath: String) async throws -> String {
        guard let query = args.getString("query") else {
            return "Error: 'query' parameter is required"
        }

        let limit = args.getInt("limit") ?? 100

        // Safety checks
        let queryUpper = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // Warn about non-SELECT queries
        if !queryUpper.hasPrefix("SELECT") && !queryUpper.hasPrefix("WITH") {
            return """
                ⚠️  Only SELECT and WITH queries are supported.

                The database is opened in read-only mode, so INSERT/UPDATE/DELETE
                will fail anyway, but it's best to use SELECT queries only.
                """
        }

        // Cap limit
        let cappedLimit = min(limit, 1000)

        // Add LIMIT if not present
        let finalQuery: String
        if queryUpper.contains("LIMIT") {
            finalQuery = query
        } else {
            finalQuery = query.trimmingCharacters(in: CharacterSet(charactersIn: ";")) + " LIMIT \(cappedLimit)"
        }

        do {
            let db = MCPDatabase(dbPath: dbPath)
            let results = try await db.executeQuery(finalQuery)

            if results.isEmpty {
                return "Query executed successfully but returned no rows."
            }

            // Format results as markdown table
            var output = "## Query Results (\(results.count) rows)\n\n"

            // Get column names from first row
            guard let firstRow = results.first else {
                return "Query executed successfully but returned no rows."
            }

            let columns = Array(firstRow.keys)

            // Build table header
            output += "| " + columns.joined(separator: " | ") + " |\n"
            output += "| " + columns.map { _ in "---" }.joined(separator: " | ") + " |\n"

            // Build table rows
            for row in results {
                let values = columns.map { column -> String in
                    guard let dbValue = row[column] else {
                        return "NULL"
                    }

                    if dbValue.isNull {
                        return "NULL"
                    }

                    var valStr = dbValue.asString()

                    // Truncate long strings
                    if valStr.count > 50 {
                        valStr = String(valStr.prefix(47)) + "..."
                    }

                    return valStr
                }

                output += "| " + values.joined(separator: " | ") + " |\n"
            }

            // Show if results were limited
            if results.count == cappedLimit {
                output += "\n_Results limited to \(cappedLimit) rows. Use smaller LIMIT in query for different amount._\n"
            }

            return output

        } catch {
            // Include helpful error message
            return """
                ## SQL Error

                ```
                \(error)
                ```

                Check your query syntax and try again.

                **Tip:** The database schema includes these main tables:
                - conversation_events (main table with all events)
                - conversation_file_state (file processing state)
                - messages_fts (full-text search virtual table)
                """
        }
    }
}
