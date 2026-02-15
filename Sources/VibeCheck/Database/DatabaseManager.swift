import Foundation
import GRDB

/// Main database manager using GRDB
/// Thread-safe actor that manages SQLite connection
actor DatabaseManager {
    // Use DatabaseWriter protocol to support both Pool (file) and Queue (in-memory)
    private var dbWriter: any DatabaseWriter
    private let dbPath: URL
    private let userName: String
    private let isInMemory: Bool

    /// Initialize DatabaseManager
    /// - Parameters:
    ///   - userName: Username for event tracking (defaults to current user)
    ///   - databasePath: Custom database path, or nil for default location.
    ///                   Use ":memory:" for in-memory database (testing).
    init(userName: String? = nil, databasePath: String? = nil) throws {
        self.userName = userName ?? NSUserName()

        // Determine database path
        let finalPath: String
        let inMemory: Bool

        if let customPath = databasePath {
            if customPath == ":memory:" {
                // In-memory database for testing
                finalPath = ":memory:"
                self.dbPath = URL(fileURLWithPath: "/tmp/memory.db") // Placeholder URL
                inMemory = true
            } else {
                // Custom path provided
                finalPath = customPath
                self.dbPath = URL(fileURLWithPath: customPath)
                inMemory = false
            }
        } else {
            // Default location: ~/Library/Application Support/VibeCheck/vibe_check.db
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let vibeCheckDir = appSupport.appendingPathComponent("VibeCheck", isDirectory: true)

            // Create directory if needed
            try FileManager.default.createDirectory(at: vibeCheckDir, withIntermediateDirectories: true)

            self.dbPath = vibeCheckDir.appendingPathComponent("vibe_check.db")
            finalPath = dbPath.path
            inMemory = false
        }

        self.isInMemory = inMemory
        print("📊 Database location: \(finalPath)")

        // Initialize appropriate database type
        var config = Configuration()
        config.defaultTransactionKind = .immediate
        config.busyMode = .timeout(30.0)

        if inMemory {
            // In-memory databases must use DatabaseQueue (WAL not supported)
            self.dbWriter = try DatabaseQueue(path: finalPath, configuration: config)
        } else {
            // File-based databases use DatabasePool (supports WAL for concurrency)
            self.dbWriter = try DatabasePool(path: finalPath, configuration: config)
        }
    }

    /// Must be called after init to set up the database schema
    func setupDatabase() async throws {
        try await setupDatabaseInternal()
    }

    private func setupDatabaseInternal() async throws {
        try await dbWriter.write { db in
            // Note: WAL mode and busy_timeout are automatically configured by GRDB's DatabasePool
            // No need to set PRAGMA journal_mode or synchronous here

            // Create main events table with generated columns
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS conversation_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    file_name TEXT NOT NULL,
                    line_number INTEGER NOT NULL,
                    event_data TEXT NOT NULL,
                    user_name TEXT NOT NULL,
                    inserted_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    event_type TEXT GENERATED ALWAYS AS
                        (json_extract(event_data, '$.type')) STORED,
                    event_message TEXT GENERATED ALWAYS AS (
                        COALESCE(
                            -- Array of content blocks: {"message": {"content": [{"text": "..."}, ...]}}
                            json_extract(event_data, '$.message.content[0].text') ||
                            IIF(json_extract(event_data, '$.message.content[1].text') IS NOT NULL,
                                char(10) || char(10) || json_extract(event_data, '$.message.content[1].text'), '') ||
                            IIF(json_extract(event_data, '$.message.content[2].text') IS NOT NULL,
                                char(10) || char(10) || json_extract(event_data, '$.message.content[2].text'), '') ||
                            IIF(json_extract(event_data, '$.message.content[3].text') IS NOT NULL,
                                char(10) || char(10) || json_extract(event_data, '$.message.content[3].text'), '') ||
                            IIF(json_extract(event_data, '$.message.content[4].text') IS NOT NULL,
                                char(10) || char(10) || json_extract(event_data, '$.message.content[4].text'), ''),
                            -- Plain string content: {"message": {"content": "some text"}}
                            IIF(json_type(event_data, '$.message.content') = 'text',
                                json_extract(event_data, '$.message.content'), NULL),
                            -- Fallback to top-level content field
                            json_extract(event_data, '$.content')
                        )
                    ) STORED,
                    event_git_branch TEXT GENERATED ALWAYS AS
                        (json_extract(event_data, '$.gitBranch')) STORED,
                    event_session_id TEXT GENERATED ALWAYS AS
                        (json_extract(event_data, '$.sessionId')) STORED,
                    event_uuid TEXT GENERATED ALWAYS AS
                        (json_extract(event_data, '$.uuid')) STORED,
                    event_timestamp TEXT GENERATED ALWAYS AS
                        (json_extract(event_data, '$.timestamp')) STORED,
                    event_model TEXT GENERATED ALWAYS AS
                        (json_extract(event_data, '$.message.model')) STORED,
                    event_input_tokens INTEGER GENERATED ALWAYS AS
                        (json_extract(event_data, '$.message.usage.input_tokens')) STORED,
                    event_cache_creation_input_tokens INTEGER GENERATED ALWAYS AS
                        (json_extract(event_data, '$.message.usage.cache_creation_input_tokens')) STORED,
                    event_cache_read_input_tokens INTEGER GENERATED ALWAYS AS
                        (json_extract(event_data, '$.message.usage.cache_read_input_tokens')) STORED,
                    event_output_tokens INTEGER GENERATED ALWAYS AS
                        (json_extract(event_data, '$.message.usage.output_tokens')) STORED,
                    git_remote_url TEXT,
                    git_commit_hash TEXT,
                    synced_at DATETIME DEFAULT NULL,
                    UNIQUE(file_name, line_number)
                )
            """)

            // Create indexes for query performance
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_file_name ON conversation_events(file_name)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_user_name ON conversation_events(user_name)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_inserted_at ON conversation_events(inserted_at)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_event_type ON conversation_events(event_type)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_event_message ON conversation_events(event_message)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_event_git_branch ON conversation_events(event_git_branch)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_event_session_id ON conversation_events(event_session_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_event_uuid ON conversation_events(event_uuid)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_git_remote_url ON conversation_events(git_remote_url)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_git_commit_hash ON conversation_events(git_commit_hash)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_synced_at ON conversation_events(synced_at)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_event_timestamp ON conversation_events(event_timestamp)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_event_model ON conversation_events(event_model)")

            // Create FTS5 virtual table for full-text search
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                    event_message,
                    event_type,
                    event_session_id,
                    content=conversation_events,
                    content_rowid=id
                )
            """)

            // Create triggers to keep FTS5 in sync with conversation_events
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_fts_insert
                AFTER INSERT ON conversation_events
                WHEN new.event_message IS NOT NULL
                BEGIN
                    INSERT INTO messages_fts(rowid, event_message, event_type, event_session_id)
                    VALUES (new.id, new.event_message, new.event_type, new.event_session_id);
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_fts_delete
                AFTER DELETE ON conversation_events
                BEGIN
                    DELETE FROM messages_fts WHERE rowid = old.id;
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_fts_update
                AFTER UPDATE ON conversation_events
                WHEN new.event_message IS NOT NULL
                BEGIN
                    UPDATE messages_fts
                    SET event_message = new.event_message,
                        event_type = new.event_type,
                        event_session_id = new.event_session_id
                    WHERE rowid = new.id;
                END
            """)

            // Create conversation_file_state table for tracking processed lines
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS conversation_file_state (
                    file_name TEXT PRIMARY KEY,
                    last_line INTEGER NOT NULL DEFAULT 0,
                    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
            """)
        }

        print("✅ Database schema initialized successfully")
    }

    // MARK: - Event Operations

    /// Insert a single conversation event
    func insertEvent(
        fileName: String,
        lineNumber: Int,
        eventData: String,
        gitRemoteURL: String? = nil,
        gitCommitHash: String? = nil
    ) async throws -> Int64? {
        return try await dbWriter.write { [userName] db in
            var event = ConversationEvent(
                fileName: fileName,
                lineNumber: lineNumber,
                eventData: eventData,
                userName: userName,
                insertedAt: Date(),
                gitRemoteURL: gitRemoteURL,
                gitCommitHash: gitCommitHash,
                syncedAt: nil
            )

            do {
                try event.insert(db)
                return event.id
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                // Duplicate (file_name, line_number) - ignore
                return nil
            }
        }
    }

    /// Insert multiple events in a batch transaction
    func insertEventsBatch(_ events: [(fileName: String, lineNumber: Int, eventData: String, gitRemoteURL: String?, gitCommitHash: String?)]) async throws -> Int {
        return try await dbWriter.write { [userName] db in
            var insertedCount = 0

            for event in events {
                var convEvent = ConversationEvent(
                    fileName: event.fileName,
                    lineNumber: event.lineNumber,
                    eventData: event.eventData,
                    userName: userName,
                    insertedAt: Date(),
                    gitRemoteURL: event.gitRemoteURL,
                    gitCommitHash: event.gitCommitHash,
                    syncedAt: nil
                )

                do {
                    try convEvent.insert(db)
                    insertedCount += 1
                } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                    // Duplicate - skip
                    continue
                }
            }

            return insertedCount
        }
    }

    /// Mark an event as synced to remote API
    func markEventSynced(eventId: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE conversation_events SET synced_at = ? WHERE id = ?",
                arguments: [Date(), eventId]
            )
        }
    }

    /// Mark multiple events as synced in a batch
    func markEventsSynced(eventIds: [Int64]) async throws {
        guard !eventIds.isEmpty else { return }

        try await dbWriter.write { db in
            let placeholders = eventIds.map { _ in "?" }.joined(separator: ",")
            let sql = "UPDATE conversation_events SET synced_at = ? WHERE id IN (\(placeholders))"

            var arguments: [DatabaseValueConvertible] = [Date()]
            arguments.append(contentsOf: eventIds)

            try db.execute(sql: sql, arguments: StatementArguments(arguments))
        }
    }

    /// Get unsynced events for remote API sync
    func getUnsyncedEvents(limit: Int = 50) async throws -> [ConversationEvent] {
        return try await dbWriter.read { db in
            try ConversationEvent
                .filter(Column("synced_at") == nil)
                .order(Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Query Operations

    /// Get events for a specific session
    func getSessionEvents(sessionId: String) async throws -> [ConversationEvent] {
        return try await dbWriter.read { db in
            try ConversationEvent
                .filter(Column("event_session_id") == sessionId)
                .order(Column("event_timestamp"))
                .fetchAll(db)
        }
    }

    /// Search events using FTS5
    func searchEvents(query: String, limit: Int = 20) async throws -> [ConversationEvent] {
        return try await dbWriter.read { db in
            let sql = """
                SELECT ce.*
                FROM messages_fts fts
                JOIN conversation_events ce ON ce.id = fts.rowid
                WHERE messages_fts MATCH ?
                ORDER BY fts.rank
                LIMIT ?
            """

            return try ConversationEvent.fetchAll(db, sql: sql, arguments: [query, limit])
        }
    }

    // MARK: - Database Info

    /// Get database file path (nonisolated for easy access)
    nonisolated func getDatabasePath() -> String {
        return dbPath.path
    }

    /// Get database statistics
    func getStatistics() async throws -> (totalEvents: Int, totalSessions: Int, unsyncedCount: Int) {
        return try await dbWriter.read { db in
            let totalEvents = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation_events") ?? 0
            let totalSessions = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT event_session_id) FROM conversation_events") ?? 0
            let unsyncedCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation_events WHERE synced_at IS NULL") ?? 0

            return (totalEvents, totalSessions, unsyncedCount)
        }
    }
}
