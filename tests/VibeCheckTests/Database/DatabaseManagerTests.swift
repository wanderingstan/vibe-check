import XCTest
@testable import VibeCheck

/// Tests for DatabaseManager
///
/// Tests core database functionality using in-memory GRDB databases.
/// Each test runs in isolation with a fresh database.
final class DatabaseManagerTests: DatabaseTestCase {

    // MARK: - Schema Tests

    func testDatabaseInitialization() async throws {
        // Database should be initialized in setUp
        try await verifyDatabaseSchema()

        // Should be able to get stats without error
        let stats = try await dbManager.getStatistics()
        XCTAssertEqual(stats.totalEvents, 0, "New database should have 0 events")
    }

    func testDatabaseTables() async throws {
        // Verify required tables exist by attempting operations
        // If tables don't exist, these will throw

        // Test conversation_events table
        _ = try await dbManager.getStatistics()

        // Test conversation_file_state table
        // (tested via StateManager in separate tests)

        // Test FTS table by attempting a search
        let results = try await dbManager.searchEvents(query: "test")
        XCTAssertEqual(results.count, 0, "New database should have no search results")
    }

    // MARK: - Insert Tests

    func testInsertEvent() async throws {
        let eventId = try await insertTestEvent(sessionId: "session-1")

        XCTAssertNotNil(eventId, "Event ID should not be nil")
        XCTAssertGreaterThan(eventId, 0, "Event ID should be positive")
    }

    func testInsertMultipleEvents() async throws {
        // Insert 5 events
        let ids = try await insertTestEvents(count: 5, sessionId: "session-1")

        XCTAssertEqual(ids.count, 5, "Should insert 5 events")

        // Verify all IDs are unique
        let uniqueIds = Set(ids)
        XCTAssertEqual(uniqueIds.count, 5, "All event IDs should be unique")

        // Verify stats
        let stats = try await dbManager.getStatistics()
        XCTAssertEqual(stats.totalEvents, 5, "Total events should be 5")
    }

    // MARK: - Query Tests

    func testQueryEventsBySession() async throws {
        // Insert events for multiple sessions
        try await insertTestEvent(sessionId: "session-1", content: "Message 1")
        try await insertTestEvent(sessionId: "session-1", content: "Message 2")
        try await insertTestEvent(sessionId: "session-2", content: "Message 3")

        // Query session-1 events
        let session1Events = try await dbManager.getSessionEvents(sessionId: "session-1")
        XCTAssertEqual(session1Events.count, 2, "Session 1 should have 2 events")

        // Query session-2 events
        let session2Events = try await dbManager.getSessionEvents(sessionId: "session-2")
        XCTAssertEqual(session2Events.count, 1, "Session 2 should have 1 event")
    }

    func testGetStatistics() async throws {
        // Insert test events
        try await insertTestEvent(sessionId: "session-1", model: "claude-3-opus")
        try await insertTestEvent(sessionId: "session-2", model: "claude-3-sonnet")

        let stats = try await dbManager.getStatistics()

        XCTAssertEqual(stats.totalEvents, 2, "Total events should be 2")
        XCTAssertEqual(stats.totalSessions, 2, "Unique sessions should be 2")
    }

    // MARK: - Full-Text Search Tests

    func testFTSSearchBasic() async throws {
        // Insert events with searchable content
        try await insertTestEvent(
            sessionId: "fts-test",
            content: "This is about database testing"
        )
        try await insertTestEvent(
            sessionId: "fts-test",
            content: "This is about Swift programming"
        )
        try await insertTestEvent(
            sessionId: "fts-test",
            content: "Random unrelated content"
        )

        // Search for "database"
        let databaseResults = try await dbManager.searchEvents(query: "database")
        XCTAssertGreaterThanOrEqual(databaseResults.count, 1, "Should find at least 1 result for 'database'")

        // Search for "Swift"
        let swiftResults = try await dbManager.searchEvents(query: "Swift")
        XCTAssertGreaterThanOrEqual(swiftResults.count, 1, "Should find at least 1 result for 'Swift'")

        // Search for non-existent term
        let noResults = try await dbManager.searchEvents(query: "nonexistent")
        XCTAssertEqual(noResults.count, 0, "Should find 0 results for non-existent term")
    }

    func testFTSSearchWithLimit() async throws {
        // Insert 10 events with searchable content
        for i in 1...10 {
            try await insertTestEvent(
                sessionId: "search-test",
                content: "Testing message number \(i)"
            )
        }

        // Search with limit
        let results = try await dbManager.searchEvents(query: "Testing", limit: 5)
        XCTAssertLessThanOrEqual(results.count, 5, "Should respect limit parameter")
    }

    // MARK: - Git Info Tests

    func testInsertEventWithGitInfo() async throws {
        // Insert event with git metadata
        let eventId = try await dbManager.insertEvent(
            fileName: "test.jsonl",
            lineNumber: 1,
            eventData: """
            {
                "type": "message",
                "sessionId": "git-test",
                "timestamp": "2024-02-14T00:00:00Z"
            }
            """,
            gitRemoteURL: "https://github.com/test/repo.git",
            gitCommitHash: "abc123def456"
        )

        XCTAssertNotNil(eventId, "Event ID should not be nil")
        XCTAssertGreaterThan(eventId ?? 0, 0, "Event should be inserted with git info")

        // Query and verify git info is stored
        let events = try await dbManager.getSessionEvents(sessionId: "git-test")
        XCTAssertEqual(events.count, 1)

        let event = events[0]
        XCTAssertEqual(event.gitRemoteURL, "https://github.com/test/repo.git")
        XCTAssertEqual(event.gitCommitHash, "abc123def456")
    }

    // MARK: - Sync Status Tests

    func testMarkEventsSynced() async throws {
        // Insert test events
        let id1 = try await insertTestEvent(sessionId: "sync-test")
        let id2 = try await insertTestEvent(sessionId: "sync-test")

        // Mark first event as synced
        try await dbManager.markEventsSynced(eventIds: [id1])

        // Verify unsynced events only returns second event
        let unsyncedEvents = try await dbManager.getUnsyncedEvents(limit: 10)

        // Should only contain the second event
        let unsyncedIds = unsyncedEvents.map { $0.id ?? 0 }
        XCTAssertTrue(unsyncedIds.contains(id2), "Should contain unsynced event")
        XCTAssertFalse(unsyncedIds.contains(id1), "Should not contain synced event")
    }

    func testGetUnsyncedEvents() async throws {
        // Insert 5 events
        let ids = try await insertTestEvents(count: 5, sessionId: "unsynced-test")

        // All should be unsynced initially
        let unsyncedEvents = try await dbManager.getUnsyncedEvents(limit: 10)
        XCTAssertEqual(unsyncedEvents.count, 5, "All 5 events should be unsynced")

        // Mark 2 as synced
        try await dbManager.markEventsSynced(eventIds: Array(ids.prefix(2)))

        // Should now have 3 unsynced
        let remainingUnsynced = try await dbManager.getUnsyncedEvents(limit: 10)
        XCTAssertEqual(remainingUnsynced.count, 3, "Should have 3 unsynced events")
    }

    // MARK: - Performance Tests

    func testInsertPerformance() async throws {
        // Measure time to insert 100 events
        measure {
            let expectation = XCTestExpectation(description: "Insert 100 events")

            Task {
                for i in 1...100 {
                    try await insertTestEvent(
                        lineNumber: i,
                        sessionId: "perf-test",
                        content: "Performance test message \(i)"
                    )
                }
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 10.0)
        }
    }

    func testSearchPerformance() async throws {
        // Insert 100 events
        for i in 1...100 {
            try await insertTestEvent(
                lineNumber: i,
                sessionId: "search-perf-test",
                content: "Message \(i) with searchable content about testing performance"
            )
        }

        // Measure search performance
        measure {
            let expectation = XCTestExpectation(description: "Search 100 events")

            Task {
                _ = try await dbManager.searchEvents(query: "performance")
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }
}
