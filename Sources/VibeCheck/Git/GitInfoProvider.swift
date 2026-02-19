import Foundation

/// Provides git repository information (remote URL, commit hash)
/// Thread-safe actor that executes git commands via Process
actor GitInfoProvider {
    /// Get git remote URL and commit hash from a directory
    /// Returns (remoteURL, commitHash) or (nil, nil) if not a git repo or on error
    func getGitInfo(for directory: URL) async -> (remoteURL: String?, commitHash: String?) {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return (nil, nil)
        }

        // Run both git commands concurrently
        async let remoteURL = runGitCommand(["git", "-C", directory.path, "remote", "get-url", "origin"])
        async let commitHash = runGitCommand(["git", "-C", directory.path, "rev-parse", "HEAD"])

        let (remote, commit) = await (remoteURL, commitHash)
        return (remote, commit)
    }

    /// Run a git command and return stdout (or nil on failure)
    /// Timeout after 1 second to avoid blocking
    private func runGitCommand(_ arguments: [String]) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // Discard stderr

        do {
            try process.run()

            // Wait for process to finish (with 1 second timeout)
            let timeoutDate = Date().addingTimeInterval(1.0)
            while process.isRunning && Date() < timeoutDate {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }

            // If still running after timeout, terminate
            if process.isRunning {
                process.terminate()
                return nil
            }

            // Check exit code
            guard process.terminationStatus == 0 else {
                return nil
            }

            // Read output
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return nil
            }

            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed

        } catch {
            return nil
        }
    }
}
