import AppKit
import SwiftUI

/// Application delegate for the menubar app
/// Note: NSApplicationDelegate methods are automatically called on the main thread
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var appState: AppState?

    // Core components (kept alive)
    private var dbManager: DatabaseManager?
    private var stateManager: StateManager?
    private var gitInfoProvider: GitInfoProvider?
    private var parser: JSONLParser?
    private var monitor: FileMonitor?
    private var syncWorker: RemoteSyncWorker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock (menubar-only app)
        NSApp.setActivationPolicy(.accessory)

        // Initialize app state
        let appState = AppState()
        self.appState = appState

        // Setup menubar
        let statusBarController = StatusBarController(appState: appState)
        statusBarController.setupMenuBar()
        self.statusBarController = statusBarController

        // Initialize monitoring system
        Task {
            await initializeMonitoring(appState: appState)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup
        Task {
            await appState?.stopMonitoring()
            await syncWorker?.stop()
        }
    }

    private func initializeMonitoring(appState: AppState) async {
        do {
            print("🎵 VibeCheck - Initializing...")

            // Perform first-run setup (skills, MCP config)
            let firstRunSetup = FirstRunSetup()
            try await firstRunSetup.performIfNeeded()

            // Initialize database manager
            let dbManager = try DatabaseManager()
            try await dbManager.setupDatabase()
            self.dbManager = dbManager
            print("✅ Database initialized")

            // Initialize state manager
            let stateManager = StateManager(dbManager: dbManager)
            self.stateManager = stateManager

            // Initialize git info provider
            let gitInfoProvider = GitInfoProvider()
            self.gitInfoProvider = gitInfoProvider

            // Get conversation directory from settings
            let conversationDir = Settings.shared.conversationDirectory
            let conversationURL = URL(fileURLWithPath: conversationDir)

            // Initialize JSONL parser
            let parser = JSONLParser(
                dbManager: dbManager,
                stateManager: stateManager,
                gitInfoProvider: gitInfoProvider,
                baseDirectory: conversationURL
            )
            self.parser = parser

            // Initialize file monitor
            let monitor = FileMonitor(watchDirectory: conversationURL, parser: parser)
            self.monitor = monitor

            // Process existing files (in background, don't block UI)
            Task.detached(priority: .background) {
                do {
                    try await monitor.processExistingFiles()
                    print("✅ Processed existing files")

                    // Refresh stats after processing
                    await appState.refreshStats()
                } catch {
                    print("❌ Error processing existing files: \(error)")
                }
            }

            // Start monitoring
            try await appState.startMonitoring(dbManager: dbManager, monitor: monitor)
            print("✅ Monitoring started")

            // Initialize and start remote sync worker
            let syncWorker = RemoteSyncWorker(dbManager: dbManager)
            self.syncWorker = syncWorker
            await syncWorker.start()

            // Initial stats refresh
            await appState.refreshStats()

        } catch {
            print("❌ Error initializing monitoring: \(error)")

            // Show error alert on main thread
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "Failed to Initialize VibeCheck"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.addButton(withTitle: "Quit")
                alert.runModal()

                NSApp.terminate(nil)
            }
        }
    }
}
