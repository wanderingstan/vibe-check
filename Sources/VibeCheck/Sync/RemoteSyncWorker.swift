import Foundation
import GRDB

/// Background worker that syncs unsynced events to remote API
/// Runs continuously, respecting the apiEnabled setting
actor RemoteSyncWorker {
    private let dbManager: DatabaseManager
    private var isRunning = false
    private var syncTask: Task<Void, Never>?

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
        syncTask?.cancel()
        syncTask = nil
        print("⏸️  Remote sync worker stopped")
    }

    /// Main sync loop - runs continuously while isRunning is true
    private func runSyncLoop() async {
        while await isRunning {
            // Check if sync is enabled
            let defaults = UserDefaults.standard
            let apiEnabled = defaults.bool(forKey: "apiEnabled")

            if !apiEnabled {
                // Wait longer when disabled
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
                continue
            }

            // Get API configuration
            let apiURL = defaults.string(forKey: "apiURL") ?? ""
            let apiKey = defaults.string(forKey: "apiKey") ?? ""

            guard !apiURL.isEmpty, !apiKey.isEmpty else {
                // Wait and retry if config is incomplete
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                continue
            }

            // Perform sync
            do {
                let synced = try await performSync(apiURL: apiURL, apiKey: apiKey)

                if synced > 0 {
                    print("✅ Synced \(synced) events to remote API")
                    consecutiveFailures = 0

                    // Short delay between batches when actively syncing
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                } else {
                    // No events to sync, wait longer
                    try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
                }

            } catch {
                consecutiveFailures += 1
                let backoff = calculateBackoff()
                print("❌ Sync failed (attempt \(consecutiveFailures)): \(error)")
                print("⏳ Backing off for \(backoff) seconds")

                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            }
        }
    }

    /// Perform a single sync operation
    private func performSync(apiURL: String, apiKey: String) async throws -> Int {
        // Query unsynced events (batched to avoid memory issues)
        let unsyncedEvents = try await dbManager.getUnsyncedEvents(limit: 50)

        guard !unsyncedEvents.isEmpty else {
            return 0
        }

        // Create API client
        let client = APIClient(apiURL: apiURL, apiKey: apiKey)

        // Convert events to API format
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let eventsForAPI = unsyncedEvents.compactMap { event -> [String: Any]? in
            guard let eventData = event.eventData.data(using: .utf8),
                  let eventJSON = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any]
            else {
                return nil
            }

            var apiEvent: [String: Any] = [
                "id": event.id ?? 0,
                "file_name": event.fileName,
                "line_number": event.lineNumber,
                "event_data": eventJSON,
                "user_name": event.userName,
                "inserted_at": isoFormatter.string(from: event.insertedAt),
            ]

            // Add git info if available
            if let gitRemoteURL = event.gitRemoteURL {
                apiEvent["git_remote_url"] = gitRemoteURL
            }
            if let gitCommitHash = event.gitCommitHash {
                apiEvent["git_commit_hash"] = gitCommitHash
            }

            return apiEvent
        }

        // Upload to API
        let uploaded = try await client.uploadEvents(eventsForAPI)

        // Mark events as synced
        let eventIds = unsyncedEvents.compactMap { $0.id }
        try await dbManager.markEventsSynced(eventIds: eventIds)

        return uploaded
    }

    /// Calculate exponential backoff with cap
    private func calculateBackoff() -> UInt64 {
        let backoff = initialBackoffSeconds * UInt64(pow(2.0, Double(min(consecutiveFailures - 1, 8))))
        return min(backoff, maxBackoffSeconds)
    }
}
