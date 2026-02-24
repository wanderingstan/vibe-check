import Foundation
import AppKit

/// Handles first-run setup tasks:
/// - Install skills to ~/.claude/skills/
/// - Update ~/.claude/mcp_servers.json
actor FirstRunSetup {
    private let userDefaults = UserDefaults.standard
    private let firstRunKey = "hasCompletedFirstRun"

    /// Check if first run setup is needed and execute if so
    func performIfNeeded() async throws {
        guard !userDefaults.bool(forKey: firstRunKey) else {
            print("✅ First run setup already completed")
            return
        }

        print("🚀 Performing first-run setup...")

        // Install skills
        try await installSkills()

        // Update MCP server config
        try await updateMCPConfig()

        // Mark first run as complete
        userDefaults.set(true, forKey: firstRunKey)

        print("✅ First run setup complete!")
    }

    /// Install bundled skills to ~/.claude/skills/
    private func installSkills() async throws {
        let fileManager = FileManager.default

        // Get skills directory from bundle resources
        guard let bundleSkillsPath = Bundle.main.resourcePath else {
            throw SetupError.bundleResourcesNotFound
        }

        // In SPM builds, skills are copied to Resources/skills/
        let bundleSkills = URL(fileURLWithPath: bundleSkillsPath)
            .appendingPathComponent("skills")

        // Target directory: ~/.claude/skills/
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let claudeSkillsDir = homeDir
            .appendingPathComponent(".claude")
            .appendingPathComponent("skills")

        // Create ~/.claude/skills if it doesn't exist
        try fileManager.createDirectory(at: claudeSkillsDir, withIntermediateDirectories: true)

        // Check if bundled skills exist
        guard fileManager.fileExists(atPath: bundleSkills.path) else {
            print("⚠️  No bundled skills found at \(bundleSkills.path)")
            print("   Skills installation will be skipped")
            return
        }

        // Get list of skill directories
        let skillDirs = try fileManager.contentsOfDirectory(
            at: bundleSkills,
            includingPropertiesForKeys: nil
        ).filter { $0.hasDirectoryPath }

        var installedCount = 0

        for skillDir in skillDirs {
            let skillName = skillDir.lastPathComponent
            let targetSkillDir = claudeSkillsDir.appendingPathComponent(skillName)

            // Check if skill already exists
            if fileManager.fileExists(atPath: targetSkillDir.path) {
                print("   Skill already exists: \(skillName)")
                continue
            }

            // Copy skill directory
            try fileManager.copyItem(at: skillDir, to: targetSkillDir)
            print("   ✓ Installed skill: \(skillName)")
            installedCount += 1
        }

        print("✅ Installed \(installedCount) skills to \(claudeSkillsDir.path)")
    }

    /// Update ~/.claude/mcp_servers.json to register vibe-check MCP server
    private func updateMCPConfig() async throws {
        let fileManager = FileManager.default

        // Get binary path
        guard let binaryPath = Bundle.main.executablePath else {
            throw SetupError.binaryPathNotFound
        }

        // MCP config path: ~/.claude/mcp_servers.json
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let claudeDir = homeDir.appendingPathComponent(".claude")
        let mcpConfigPath = claudeDir.appendingPathComponent("mcp_servers.json")

        // Create ~/.claude if it doesn't exist
        try fileManager.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Read existing config or create new one
        var config: [String: Any]

        if fileManager.fileExists(atPath: mcpConfigPath.path) {
            let data = try Data(contentsOf: mcpConfigPath)
            config = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } else {
            config = [:]
        }

        // Get or create mcpServers section
        var mcpServers = config["mcpServers"] as? [String: Any] ?? [:]

        // Add or update vibe-check server
        mcpServers["vibe-check"] = [
            "command": binaryPath,
            "args": ["--mcp-server"]
        ]

        config["mcpServers"] = mcpServers

        // Write back to file
        let jsonData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )
        try jsonData.write(to: mcpConfigPath)

        print("✅ Updated MCP config at \(mcpConfigPath.path)")
        print("   Binary: \(binaryPath)")
    }

    /// Reset first run status (for testing)
    func reset() {
        userDefaults.removeObject(forKey: firstRunKey)
        print("🔄 First run status reset")
    }
}

enum SetupError: Error, LocalizedError {
    case bundleResourcesNotFound
    case binaryPathNotFound

    var errorDescription: String? {
        switch self {
        case .bundleResourcesNotFound:
            return "Bundle resources directory not found"
        case .binaryPathNotFound:
            return "Could not determine binary path"
        }
    }
}
