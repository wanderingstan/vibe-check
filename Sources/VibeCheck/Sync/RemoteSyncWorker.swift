import Foundation
import GRDB

/// Background worker that syncs events to the remote API.
/// Sync decisions are driven entirely by the local sync_scopes table:
///   - scope_type = 'all': sync all unsynced events (global sync)
///   - scope_type = 'session': sync events for a specific session only
/// The remote server has no mechanism to add or modify scopes.
actor RemoteSyncWorker {
    private let dbManager: DatabaseManager
    private var isRunning = false
    private var syncTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?

    // Retry configuration
    private var consecutiveFailures = 0
    private let maxBackoffSeconds: UInt64 = 300 // 5 minutes
    private let initialBackoffSeconds: UInt64 = 2

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    /// Start the background sync worker
    func start() async {
        guard !isRunning else { return }

        isRunning = true
        print("🔄 Remote sync worker started")

        syncTask = Task.detached(priority: .background) { [weak self] in
            await self?.runSyncLoop()
        }
    }

    /// Stop the background sync worker
    func stop() async {
        isRunning = false
        sleepTask?.cancel()
        sleepTask = nil
        syncTask?.cancel()
        syncTask = nil
        print("⏸️  Remote sync worker stopped")
    }

    /// Wake up the sync loop early (e.g., after a new scope is registered)
    func wakeUp() {
        sleepTask?.cancel()
        sleepTask = nil
    }

    /// Sleep that can be cancelled by wakeUp()
    private func cancellableSleep(nanoseconds: UInt64) async {
        let task: Task<Void, Never> = Task {
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { }
        }
        sleepTask = task
        await task.value
        sleepTask = nil
    }

    /// Main sync loop — runs continuously while isRunning is true
    private func runSyncLoop() async {
        while await isRunning {
            // Read API credentials (shared UserDefaults)
            let defaults = UserDefaults.standard
            let apiURL = defaults.string(forKey: "apiURL") ?? ""
            let apiKey = defaults.string(forKey: "apiKey") ?? ""

            guard !apiURL.isEmpty, !apiKey.isEmpty else {
                // No credentials configured — wait and retry
                await cancellableSleep(nanoseconds: 60_000_000_000)
                continue
            }

            // Determine sync mode from database (sole source of truth)
            let scopes: [SyncScope]
            do {
                scopes = try await dbManager.getActiveSyncScopes()
            } catch {
                print("❌ Failed to read sync scopes: \(error)")
                await cancellableSleep(nanoseconds: 60_000_000_000)
                continue
            }

            guard !scopes.isEmpty else {
                // No scopes registered — nothing to sync
                await cancellableSleep(nanoseconds: 60_000_000_000)
                continue
            }

            let hasAllScope = scopes.contains { $0.scopeType == "all" }

            do {
                let synced: Int
                if hasAllScope {
                    synced = try await performGlobalSync(apiURL: apiURL, apiKey: apiKey)
                } else {
                    synced = try await performSelectiveSync(
                        apiURL: apiURL, apiKey: apiKey, scopes: scopes
                    )
                }

                consecutiveFailures = 0

                if synced > 0 {
                    print("✅ Synced \(synced) events to remote API")
                    await cancellableSleep(nanoseconds: 2_000_000_000) // 2s between batches
                } else if hasAllScope {
                    await cancellableSleep(nanoseconds: 60_000_000_000) // 60s when global sync idle
                } else {
                    // Scopes exist but nothing pending — poll frequently so new events are caught quickly
                    await cancellableSleep(nanoseconds: 5_000_000_000) // 5s
                }

            } catch {
                consecutiveFailures += 1
                let backoff = calculateBackoff()
                print("❌ Sync failed (attempt \(consecutiveFailures)): \(error)")
                print("⏳ Backing off for \(backoff) seconds")
                await cancellableSleep(nanoseconds: backoff * 1_000_000_000)
            }
        }
    }

    /// Global sync — uploads all unsynced events (scope_type = 'all')
    private func performGlobalSync(apiURL: String, apiKey: String) async throws -> Int {
        let unsyncedEvents = try await dbManager.getUnsyncedEvents(limit: 50)
        guard !unsyncedEvents.isEmpty else { return 0 }

        let client = APIClient(apiURL: apiURL, apiKey: apiKey)
        let eventsForAPI = buildAPIPayload(from: unsyncedEvents)

        let uploaded = try await client.uploadEvents(eventsForAPI)
        let eventIds = unsyncedEvents.compactMap { $0.id }
        try await dbManager.markEventsSynced(eventIds: eventIds)

        return uploaded
    }

    /// Selective sync — uploads events matching registered session (or other) scopes
    private func performSelectiveSync(
        apiURL: String,
        apiKey: String,
        scopes: [SyncScope]
    ) async throws -> Int {
        let client = APIClient(apiURL: apiURL, apiKey: apiKey)
        var totalSynced = 0

        for scope in scopes {
            switch scope.scopeType {
            case "session":
                guard let sessionId = scope.scopeSessionId, let scopeId = scope.id else { continue }
                let events = try await dbManager.getUnsyncedEventsForSession(
                    sessionId: sessionId, limit: 200
                )
                guard !events.isEmpty else { continue }

                let eventsForAPI = buildAPIPayload(from: events)
                let uploaded = try await client.uploadEvents(eventsForAPI)
                let eventIds = events.compactMap { $0.id }
                try await dbManager.markEventsSynced(eventIds: eventIds)
                try await dbManager.markScopeSynced(scopeId: scopeId)

                totalSynced += uploaded

            default:
                // Other scope types (repository, conversation) not yet implemented
                break
            }
        }

        return totalSynced
    }

    /// Build API payload from events (shared between global and selective paths)
    private func buildAPIPayload(from events: [ConversationEvent]) -> [[String: Any]] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return events.compactMap { event -> [String: Any]? in
            guard let eventData = event.eventData.data(using: .utf8),
                  let eventJSON = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any]
            else { return nil }

            var apiEvent: [String: Any] = [
                "id": event.id ?? 0,
                "file_name": event.fileName,
                "line_number": event.lineNumber,
                "event_data": eventJSON,
                "user_name": event.userName,
                "inserted_at": isoFormatter.string(from: event.insertedAt),
            ]

            if let gitRemoteURL = event.gitRemoteURL {
                apiEvent["git_remote_url"] = gitRemoteURL
            }
            if let gitCommitHash = event.gitCommitHash {
                apiEvent["git_commit_hash"] = gitCommitHash
            }

            return apiEvent
        }
    }

    /// Calculate exponential backoff with cap
    private func calculateBackoff() -> UInt64 {
        let backoff = initialBackoffSeconds * UInt64(pow(2.0, Double(min(consecutiveFailures - 1, 8))))
        return min(backoff, maxBackoffSeconds)
    }
}
