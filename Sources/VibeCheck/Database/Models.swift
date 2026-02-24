import Foundation
import GRDB

// MARK: - ConversationEvent

/// Represents a single event in a Claude Code conversation
/// Stored in the conversation_events table
struct ConversationEvent: Codable {
    var id: Int64?
    var fileName: String
    var lineNumber: Int
    var eventData: String  // Raw JSON
    var userName: String
    var insertedAt: Date
    var gitRemoteURL: String?
    var gitCommitHash: String?
    var syncedAt: Date?

    // Generated columns (computed by SQLite from eventData JSON)
    // These are read-only - SQLite computes them automatically
    var eventType: String?
    var eventMessage: String?
    var eventSessionId: String?
    var eventGitBranch: String?
    var eventUuid: String?
    var eventTimestamp: String?
    var eventModel: String?
    var eventInputTokens: Int?
    var eventCacheCreationInputTokens: Int?
    var eventCacheReadInputTokens: Int?
    var eventOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case lineNumber = "line_number"
        case eventData = "event_data"
        case userName = "user_name"
        case insertedAt = "inserted_at"
        case gitRemoteURL = "git_remote_url"
        case gitCommitHash = "git_commit_hash"
        case syncedAt = "synced_at"
        case eventType = "event_type"
        case eventMessage = "event_message"
        case eventSessionId = "event_session_id"
        case eventGitBranch = "event_git_branch"
        case eventUuid = "event_uuid"
        case eventTimestamp = "event_timestamp"
        case eventModel = "event_model"
        case eventInputTokens = "event_input_tokens"
        case eventCacheCreationInputTokens = "event_cache_creation_input_tokens"
        case eventCacheReadInputTokens = "event_cache_read_input_tokens"
        case eventOutputTokens = "event_output_tokens"
    }
}

// MARK: - GRDB Conformance

extension ConversationEvent: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "conversation_events"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Encode only non-generated columns for INSERT/UPDATE
    /// Generated columns are computed by SQLite and cannot be inserted
    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["file_name"] = fileName
        container["line_number"] = lineNumber
        container["event_data"] = eventData
        container["user_name"] = userName
        container["inserted_at"] = insertedAt
        container["git_remote_url"] = gitRemoteURL
        container["git_commit_hash"] = gitCommitHash
        container["synced_at"] = syncedAt
        // Do NOT encode generated columns:
        // event_type, event_message, event_session_id, event_git_branch,
        // event_uuid, event_timestamp, event_model, event_input_tokens,
        // event_cache_creation_input_tokens, event_cache_read_input_tokens,
        // event_output_tokens
    }
}

// MARK: - FileState

/// Tracks the last processed line for each conversation file
/// Stored in the conversation_file_state table
struct FileState: Codable {
    var fileName: String
    var lastLine: Int
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case lastLine = "last_line"
        case updatedAt = "updated_at"
    }
}

extension FileState: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "conversation_file_state"
    static let databaseSelection: [any SQLSelectable] = [
        Column("file_name"),
        Column("last_line"),
        Column("updated_at")
    ]
}

// MARK: - SyncScope

/// Tracks what should be selectively synced to the remote API.
/// scope_type = 'all' means sync everything (replaces the old apiEnabled flag).
/// scope_type = 'session' means sync events for a specific session.
/// The local sync_scopes table is the sole source of truth for what gets synced.
/// The remote server has no mechanism to add or modify scopes on the client.
struct SyncScope: Codable {
    var id: Int64?
    var scopeType: String           // 'all', 'session', 'repository', 'conversation'
    var scopeSessionId: String?
    var scopeGitRemoteUrl: String?
    var scopeFileName: String?
    var createdAt: Date
    var lastSyncedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case scopeType = "scope_type"
        case scopeSessionId = "scope_session_id"
        case scopeGitRemoteUrl = "scope_git_remote_url"
        case scopeFileName = "scope_file_name"
        case createdAt = "created_at"
        case lastSyncedAt = "last_synced_at"
    }
}

extension SyncScope: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "sync_scopes"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["scope_type"] = scopeType
        container["scope_session_id"] = scopeSessionId
        container["scope_git_remote_url"] = scopeGitRemoteUrl
        container["scope_file_name"] = scopeFileName
        container["created_at"] = createdAt
        container["last_synced_at"] = lastSyncedAt
    }
}
