import AppKit
import SwiftUI
import LaunchAtLogin

/// Manages the menubar icon and dropdown menu
class StatusBarController {
    private var statusItem: NSStatusItem?
    private var appState: AppState
    private var settingsWindow: NSWindow?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Create and configure the menubar item
    func setupMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Set icon (using SF Symbol)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "VibeCheck")
            image?.isTemplate = true // Allows menubar to adjust color for dark/light mode
            button.image = image
            button.toolTip = "VibeCheck - Monitoring Claude Code conversations"
        }

        // Create menu
        let menu = NSMenu()

        // Status section (non-clickable)
        let statusMenuItem = NSMenuItem(title: "Status: Monitoring", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        let eventsItem = NSMenuItem(title: "Events: 0", action: nil, keyEquivalent: "")
        eventsItem.isEnabled = false
        eventsItem.tag = 1 // Tag for updating later
        menu.addItem(eventsItem)

        let sessionsItem = NSMenuItem(title: "Sessions: 0", action: nil, keyEquivalent: "")
        sessionsItem.isEnabled = false
        sessionsItem.tag = 2
        menu.addItem(sessionsItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit VibeCheck", action: #selector(quit), keyEquivalent: "q"))

        // Set targets for menu items
        for item in menu.items {
            item.target = self
        }

        statusItem.menu = menu
        self.statusItem = statusItem

        // Start updating stats
        startStatsUpdateTimer(menu: menu)
    }

    /// Update menu stats periodically
    private func startStatsUpdateTimer(menu: NSMenu) {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self, weak menu] _ in
            guard let self = self, let menu = menu else { return }

            Task { @MainActor in
                // Update events count
                if let eventsItem = menu.item(withTag: 1) {
                    eventsItem.title = "Events: \(self.appState.totalEvents)"
                }

                // Update sessions count
                if let sessionsItem = menu.item(withTag: 2) {
                    sessionsItem.title = "Sessions: \(self.appState.totalSessions)"
                }
            }
        }
    }

    @objc private func openSettings() {
        // If settings window already exists, bring it to front
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create settings window
        let settingsView = SettingsView(appState: appState)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "VibeCheck Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 500, height: 400))
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        self.settingsWindow = window
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
