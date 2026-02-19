import Foundation
import SwiftUI

/// Observable state for the menubar app
/// Provides real-time stats and status updates
@MainActor
class AppState: ObservableObject {
    // Monitoring state
    @Published var isMonitoring = false
    @Published var lastEventTime: Date?
    @Published var totalEvents: Int = 0
    @Published var totalSessions: Int = 0
    @Published var unsyncedCount: Int = 0
    @Published var syncAllEnabled: Bool = false

    // Settings (backed by UserDefaults via @AppStorage)
    @Published var conversationDirectory: String
    @Published var databasePath: String

    // References to core components
    private var dbManager: DatabaseManager?
    private var monitor: FileMonitor?

    init() {
        self.conversationDirectory = Settings.shared.conversationDirectory
        self.databasePath = ""
    }

    /// Initialize the monitoring system
    func startMonitoring(dbManager: DatabaseManager, monitor: FileMonitor) async throws {
        self.dbManager = dbManager
        self.monitor = monitor
        self.databasePath = dbManager.getDatabasePath()

        // Start file monitoring
        try await monitor.startMonitoring()
        self.isMonitoring = true

        // Start periodic stats refresh
        startStatsRefreshTimer()
    }

    /// Stop monitoring
    func stopMonitoring() async {
        await monitor?.stopMonitoring()
        self.isMonitoring = false
    }

    /// Refresh statistics from database
    func refreshStats() async {
        guard let dbManager = dbManager else { return }

        do {
            let stats = try await dbManager.getStatistics()
            self.totalEvents = stats.totalEvents
            self.totalSessions = stats.totalSessions
            self.unsyncedCount = stats.unsyncedCount
            self.syncAllEnabled = try await dbManager.hasSyncAllScope()
        } catch {
            print("Error refreshing stats: \(error)")
        }
    }

    /// Toggle global sync-all by adding or removing the 'all' scope
    func setSyncAll(_ enabled: Bool) async {
        guard let dbManager = dbManager else { return }
        do {
            if enabled {
                try await dbManager.addAllSyncScope()
            } else {
                try await dbManager.removeAllSyncScope()
            }
            self.syncAllEnabled = enabled
        } catch {
            print("Error updating sync-all scope: \(error)")
        }
    }

    /// Start timer to refresh stats every 5 seconds
    private func startStatsRefreshTimer() {
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshStats()
            }
        }
    }

    /// Update last event time (called when new event is processed)
    func recordEvent() {
        self.lastEventTime = Date()
    }

    /// Open database directory in Finder
    func openDatabaseLocation() {
        let dbURL = URL(fileURLWithPath: databasePath)
        let dirURL = dbURL.deletingLastPathComponent()
        NSWorkspace.shared.open(dirURL)
    }
}
