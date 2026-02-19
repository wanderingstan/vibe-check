import Foundation
import GRDB

/// Manages file processing state (tracks last processed line per file)
/// Thread-safe actor that works with conversation_file_state table
actor StateManager {
    private let dbManager: DatabaseManager

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    /// Get the last processed line number for a file
    func getLastLine(for fileName: String) async throws -> Int {
        // Use DatabaseManager's read pool directly
        let dbPath = dbManager.getDatabasePath()
        let pool = try DatabasePool(path: dbPath)

        return try await pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT last_line FROM conversation_file_state WHERE file_name = ?",
                arguments: [fileName]
            ) ?? 0
        }
    }

    /// Set the last processed line number for a file
    func setLastLine(for fileName: String, line: Int) async throws {
        let dbPath = dbManager.getDatabasePath()
        let pool = try DatabasePool(path: dbPath)

        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation_file_state (file_name, last_line, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(file_name) DO UPDATE SET
                        last_line = excluded.last_line,
                        updated_at = excluded.updated_at
                """,
                arguments: [fileName, line, Date()]
            )
        }
    }

    /// Skip to end of file without processing (marks all lines as processed)
    func skipToEnd(of fileName: String, totalLines: Int) async throws {
        try await setLastLine(for: fileName, line: totalLines)
    }

    /// Get all tracked files with their last line numbers
    func getAllFileStates() async throws -> [FileState] {
        let dbPath = dbManager.getDatabasePath()
        let pool = try DatabasePool(path: dbPath)

        return try await pool.read { db in
            try FileState.fetchAll(db)
        }
    }

    /// Reset state for a specific file (start processing from beginning)
    func resetFile(_ fileName: String) async throws {
        try await setLastLine(for: fileName, line: 0)
    }

    /// Delete state for a file (stop tracking)
    func deleteFileState(_ fileName: String) async throws {
        let dbPath = dbManager.getDatabasePath()
        let pool = try DatabasePool(path: dbPath)

        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM conversation_file_state WHERE file_name = ?",
                arguments: [fileName]
            )
        }
    }
}
