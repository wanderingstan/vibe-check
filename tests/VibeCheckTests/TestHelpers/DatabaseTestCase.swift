import XCTest
import GRDB
@testable import VibeCheck

/// Base test case for database tests
///
/// Provides an in-memory GRDB database for fast, isolated testing.
/// Each test gets a fresh database instance with full schema.
class DatabaseTestCase: XCTestCase {
    var dbManager: DatabaseManager!

    override func setUp() async throws {
        try await super.setUp()

        // Create in-memory database for testing
        // This is fast and isolated - perfect for unit tests
        dbManager = try DatabaseManager(userName: "test_user")
        try await dbManager.setupDatabase()
    }

    override func tearDown() async throws {
        dbManager = nil
        try await super.tearDown()
    }

    // MARK: - Test Helpers

    /// Insert a test event into the database
    ///
    /// - Parameters:
    ///   - fileName: Name of the conversation file
    ///   - lineNumber: Line number in the file
    ///   - sessionId: Session identifier
    ///   - eventType: Type of event (message, tool_use, etc.)
    ///   - content: Optional message content
    ///   - model: Optional model name
    /// - Returns: Database ID of inserted event
    @discardableResult
    func insertTestEvent(
        fileName: String = "test.jsonl",
        lineNumber: Int = 1,
        sessionId: String = "test-session",
        eventType: String = "message",
        content: String? = nil,
        model: String? = nil
    ) async throws -> Int64 {
        var eventDict: [String: Any] = [
            "type": eventType,
            "sessionId": sessionId,
            "timestamp": "2024-02-14T00:00:00Z"
        ]

        if let content = content {
            eventDict["content"] = content
        }

        if let model = model {
            eventDict["model"] = model
        }

        let jsonData = try JSONSerialization.data(withJSONObject: eventDict)
        let eventData = String(data: jsonData, encoding: .utf8)!

        let eventId = try await dbManager.insertEvent(
            fileName: fileName,
            lineNumber: lineNumber,
            eventData: eventData
        )
        return eventId ?? 0
    }

    /// Insert multiple test events
    ///
    /// - Parameter count: Number of events to insert
    /// - Returns: Array of database IDs
    func insertTestEvents(count: Int, sessionId: String = "test-session") async throws -> [Int64] {
        var ids: [Int64] = []
        for i in 1...count {
            let id = try await insertTestEvent(
                fileName: "test.jsonl",
                lineNumber: i,
                sessionId: sessionId,
                eventType: "message",
                content: "Test message \(i)"
            )
            ids.append(id)
        }
        return ids
    }

    /// Get event count for a session
    func getEventCount(sessionId: String) async throws -> Int {
        let events = try await dbManager.getSessionEvents(sessionId: sessionId)
        return events.count
    }

    /// Verify database schema exists
    func verifyDatabaseSchema() async throws {
        // This will throw if tables don't exist
        _ = try await dbManager.getStatistics()
    }
}
