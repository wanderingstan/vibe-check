import Foundation

/// Parses JSONL (JSON Lines) files containing conversation events
/// Works with StateManager to track processing position
actor JSONLParser {
    private let dbManager: DatabaseManager
    private let stateManager: StateManager
    private let gitInfoProvider: GitInfoProvider
    private let baseDirectory: URL

    init(dbManager: DatabaseManager, stateManager: StateManager, gitInfoProvider: GitInfoProvider, baseDirectory: URL) {
        self.dbManager = dbManager
        self.stateManager = stateManager
        self.gitInfoProvider = gitInfoProvider
        self.baseDirectory = baseDirectory
    }

    /// Process a JSONL file (only new lines since last processing)
    func processFile(_ fileURL: URL) async throws {
        // Only process .jsonl files
        guard fileURL.pathExtension == "jsonl" else {
            return
        }

        // Check file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        // Get relative path for better identification
        let fileName: String
        if fileURL.path.hasPrefix(baseDirectory.path) {
            fileName = String(fileURL.path.dropFirst(baseDirectory.path.count + 1))
        } else {
            fileName = fileURL.lastPathComponent
        }

        // Get last processed line
        let lastLine = try await stateManager.getLastLine(for: fileName)

        // Read all lines from file
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        // Get new lines to process
        let newLines = Array(lines.dropFirst(lastLine))

        // Handle empty files or no new lines
        if newLines.isEmpty || (lastLine == 0 && lines.count == 1 && lines[0].isEmpty) {
            if lastLine == 0 {
                try await stateManager.setLastLine(for: fileName, line: 0)
            }
            return
        }

        print("📄 Processing \(newLines.count) new line(s) from \(fileName)")

        // Collect events for batch insert
        // Git info fetched lazily from first event's cwd
        // (fileURL.deletingLastPathComponent() is ~/.claude/projects/... which is not a git repo)
        var eventsBatch: [(fileName: String, lineNumber: Int, eventData: String, gitRemoteURL: String?, gitCommitHash: String?)] = []
        var skippedCount = 0
        var finalLineNumber = lastLine
        var gitRemoteURL: String? = nil
        var gitCommitHash: String? = nil
        var gitInfoFetched = false

        // Process each new line
        for (index, line) in newLines.enumerated() {
            let lineNumber = lastLine + index + 1
            finalLineNumber = lineNumber

            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip empty lines
            if trimmedLine.isEmpty {
                skippedCount += 1
                continue
            }

            // Parse JSON
            guard let jsonData = trimmedLine.data(using: .utf8) else {
                print("⚠️  Invalid UTF-8 at \(fileName):\(lineNumber)")
                skippedCount += 1
                continue
            }

            do {
                // Parse JSON to extract cwd for git info
                let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]

                // Get git info once from the first event's working directory
                if !gitInfoFetched, let cwd = jsonObject?["cwd"] as? String {
                    let cwdURL = URL(fileURLWithPath: cwd)
                    let (remote, commit) = await gitInfoProvider.getGitInfo(for: cwdURL)
                    gitRemoteURL = remote
                    gitCommitHash = commit
                    gitInfoFetched = true
                }

                // Add to batch (store raw JSON string, not parsed object)
                eventsBatch.append((
                    fileName: fileName,
                    lineNumber: lineNumber,
                    eventData: trimmedLine,
                    gitRemoteURL: gitRemoteURL,
                    gitCommitHash: gitCommitHash
                ))

            } catch {
                print("⚠️  Invalid JSON at \(fileName):\(lineNumber): \(error)")
                skippedCount += 1
            }
        }

        // Batch insert all events
        let storedCount = try await dbManager.insertEventsBatch(eventsBatch)

        // Update state once at the end
        try await stateManager.setLastLine(for: fileName, line: finalLineNumber)

        // Log summary
        if storedCount > 0 {
            let gitInfo = buildGitInfo(remote: gitRemoteURL, commit: gitCommitHash)
            print("✅ Stored \(storedCount) event(s) from \(fileName)\(gitInfo)")
        }

        if skippedCount > 0 {
            print("⏭️  Skipped \(skippedCount) invalid/empty line(s)")
        }
    }

    /// Build git info string for logging
    private func buildGitInfo(remote: String?, commit: String?) -> String {
        var parts: [String] = []

        if let remote = remote {
            let repoName = remote.components(separatedBy: "/").last?.replacingOccurrences(of: ".git", with: "") ?? remote
            parts.append("repo:\(repoName)")
        }

        if let commit = commit {
            let shortHash = String(commit.prefix(7))
            parts.append("commit:\(shortHash)")
        }

        if parts.isEmpty {
            return ""
        }

        return " [\(parts.joined(separator: ", "))]"
    }
}
