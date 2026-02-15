import SwiftUI
import LaunchAtLogin

/// Settings window for VibeCheck
struct SettingsView: View {
    @ObservedObject var appState: AppState

    // Settings backed by UserDefaults
    @AppStorage("conversationDirectory") private var conversationDirectory = "~/.claude/projects"
    @AppStorage("apiEnabled") private var apiEnabled = false
    @AppStorage("apiURL") private var apiURL = "https://vibecheck.wanderingstan.com/api"
    @AppStorage("apiKey") private var apiKey = ""

    // Authentication state
    @State private var isAuthenticating = false
    @State private var authUserCode: String?
    @State private var authError: String?
    @State private var authTask: Task<Void, Never>?

    var body: some View {
        TabView {
            // General Settings
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            // Remote Sync Settings
            syncTab
                .tabItem {
                    Label("Remote Sync", systemImage: "cloud")
                }

            // Integration
            integrationTab
                .tabItem {
                    Label("Integration", systemImage: "link")
                }

            // About
            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .padding(20)
        .frame(minWidth: 500, idealWidth: 550, maxWidth: 700,
               minHeight: 500, idealHeight: 550, maxHeight: 800)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("General Settings")
                .font(.headline)

            Divider()

            // Monitoring status
            HStack {
                Image(systemName: appState.isMonitoring ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(appState.isMonitoring ? .green : .red)
                Text(appState.isMonitoring ? "Monitoring Active" : "Monitoring Stopped")
                    .font(.subheadline)
            }

            // Conversation directory
            VStack(alignment: .leading, spacing: 8) {
                Text("Conversation Directory")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    TextField("", text: $conversationDirectory)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true) // Read-only for now

                    Button("Choose...") {
                        // TODO: File picker to change directory
                    }
                    .disabled(true) // Disabled for now
                }

                Text("Location: \(conversationDirectory)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Database location
            VStack(alignment: .leading, spacing: 8) {
                Text("Database Location")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack {
                    Text(appState.databasePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Open") {
                        appState.openDatabaseLocation()
                    }
                }
            }

            Divider()

            // Launch at login
            LaunchAtLogin.Toggle()

            Spacer()
        }
        .padding()
    }

    // MARK: - Remote Sync Tab

    private var syncTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Remote Sync Settings")
                .font(.headline)

            Divider()

            // API URL
            VStack(alignment: .leading, spacing: 8) {
                Text("Server URL")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField("https://...", text: $apiURL)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isAuthenticating || !apiKey.isEmpty)

                Text("Default: https://vibecheck.wanderingstan.com/api")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Authentication section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Authentication")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    if !apiKey.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Authenticated")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("Not authenticated")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if !apiKey.isEmpty {
                    // Show masked API key and logout
                    HStack {
                        Text("API Key: \(apiKey.prefix(8))...\(apiKey.suffix(4))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)

                        Spacer()

                        Button("Logout") {
                            logout()
                        }
                        .font(.caption)
                        .disabled(isAuthenticating)
                    }
                } else if isAuthenticating {
                    // Show authorization in progress
                    VStack(alignment: .leading, spacing: 8) {
                        if let userCode = authUserCode {
                            Text("Your verification code:")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                Text(userCode)
                                    .font(.system(.title2, design: .monospaced))
                                    .fontWeight(.bold)
                                    .foregroundColor(.accentColor)
                                    .padding(8)
                                    .background(Color.accentColor.opacity(0.1))
                                    .cornerRadius(4)

                                Spacer()
                            }

                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Waiting for authorization in browser...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Button("Cancel") {
                                cancelAuth()
                            }
                            .font(.caption)
                        } else {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Starting authorization...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } else {
                    // Show login button
                    Button("Login to Enable Sync") {
                        startAuth()
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Opens vibecheck.wanderingstan.com for authorization")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }

                // Show error if any
                if let error = authError {
                    HStack {
                        Image(systemName: "exclamation.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding(.top, 4)
                }
            }

            // Enable/disable sync toggle (only show if authenticated)
            if !apiKey.isEmpty {
                Divider()

                Toggle("Enable Remote Sync", isOn: $apiEnabled)
                    .toggleStyle(.switch)

                if apiEnabled {
                    HStack {
                        Image(systemName: "cloud.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Syncing events to \(maskedURL(apiURL))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("Unsynced: \(appState.unsyncedCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Remote sync is disabled. All data is stored locally only.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Integration Tab

    private var integrationTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Claude Code Integration")
                .font(.headline)

            Divider()

            // MCP Server section
            VStack(alignment: .leading, spacing: 12) {
                Text("MCP Server")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: mcpServerConfigured ? "checkmark.circle.fill" : "exclamation.triangle.fill")
                            .foregroundColor(mcpServerConfigured ? .green : .orange)
                        Text(mcpServerConfigured ? "Configured in Claude Code" : "Not yet configured")
                            .font(.caption)
                    }

                    if !mcpServerConfigured {
                        Text("To enable MCP tools, add this to ~/.claude/mcp_servers.json:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(mcpServerConfig)
                                .font(.system(.caption, design: .monospaced))
                                .padding(8)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)

                            Button("Copy Configuration") {
                                copyToClipboard(mcpServerConfig)
                            }
                            .font(.caption)
                        }
                    }
                }
            }

            Divider()

            // Skills section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Claude Skills")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Spacer()

                    Text("\(installedSkillsCount)/10 installed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(expectedSkills, id: \.self) { skill in
                        HStack(spacing: 6) {
                            Image(systemName: isSkillInstalled(skill) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(isSkillInstalled(skill) ? .green : .secondary)
                                .font(.caption)
                            Text(skill)
                                .font(.caption)
                                .foregroundColor(isSkillInstalled(skill) ? .primary : .secondary)
                        }
                    }
                }

                if installedSkillsCount < expectedSkills.count {
                    Text("Skills should be bundled in the app and auto-installed on first launch.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("VibeCheck")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 2.0.0 (Swift Edition)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 12) {
                StatRow(label: "Events Captured", value: "\(appState.totalEvents)")
                StatRow(label: "Sessions Tracked", value: "\(appState.totalSessions)")
                StatRow(label: "Unsynced Events", value: "\(appState.unsyncedCount)")
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            Text("Monitors Claude Code conversations and stores them locally with full-text search.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
        .padding()
    }

    // MARK: - Integration Helpers

    private let expectedSkills = [
        "vibe-check-stats",
        "vibe-check-search",
        "vibe-check-analyze-tools",
        "vibe-check-recent",
        "vibe-check-session-id",
        "vibe-check-share",
        "vibe-check-view-stats",
        "vibe-check-doctor",
        "vibe",
        "vibe-sql",
    ]

    private var mcpServerConfigured: Bool {
        let mcpConfigPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/mcp_servers.json")

        guard FileManager.default.fileExists(atPath: mcpConfigPath.path),
              let data = try? Data(contentsOf: mcpConfigPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any]
        else {
            return false
        }

        return servers["vibe-check"] != nil
    }

    private var mcpServerConfig: String {
        // Get the actual binary path
        let binaryPath: String
        if let bundlePath = Bundle.main.executablePath {
            binaryPath = bundlePath
        } else {
            binaryPath = "/Applications/VibeCheck.app/Contents/MacOS/VibeCheck"
        }

        return """
        {
          "mcpServers": {
            "vibe-check": {
              "command": "\(binaryPath)",
              "args": ["--mcp-server"]
            }
          }
        }
        """
    }

    private func isSkillInstalled(_ skill: String) -> Bool {
        let skillsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/\(skill)")
        return FileManager.default.fileExists(atPath: skillsPath.path)
    }

    private var installedSkillsCount: Int {
        expectedSkills.filter { isSkillInstalled($0) }.count
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Authentication Helpers

    private func startAuth() {
        guard !isAuthenticating else { return }
        authError = nil
        authUserCode = nil
        isAuthenticating = true

        authTask = Task {
            do {
                let authManager = AuthManager(apiURL: apiURL)
                let (userCode, verificationURL, pollForKey) = try await authManager.startDeviceFlow()

                await MainActor.run {
                    self.authUserCode = userCode
                }

                // Open browser
                await authManager.openVerificationURL(verificationURL)

                // Poll for approval
                let apiKey = try await pollForKey()

                // Success - save API key
                await MainActor.run {
                    self.apiKey = apiKey
                    self.apiEnabled = true
                    self.isAuthenticating = false
                    self.authUserCode = nil
                    self.authError = nil
                    print("✅ Authentication successful - API key saved")
                }

            } catch {
                await MainActor.run {
                    self.authError = error.localizedDescription
                    self.isAuthenticating = false
                    self.authUserCode = nil
                    print("❌ Authentication failed: \(error)")
                }
            }
        }
    }

    private func cancelAuth() {
        authTask?.cancel()
        authTask = nil
        isAuthenticating = false
        authUserCode = nil
        authError = nil
    }

    private func logout() {
        apiKey = ""
        apiEnabled = false
        authError = nil
        print("🔓 Logged out - API key removed")
    }

    private func maskedURL(_ url: String) -> String {
        guard let urlObj = URL(string: url),
              let host = urlObj.host else {
            return url
        }
        return host
    }
}

// MARK: - Helper Views

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView(appState: AppState())
}
