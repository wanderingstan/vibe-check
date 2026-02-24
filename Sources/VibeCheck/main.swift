import AppKit
import Foundation

// Entry point for VibeCheck
// Supports two modes:
// 1. Menubar App (default) - native macOS menubar application
// 2. MCP Server (--mcp-server) - JSON-RPC server for Claude Code

// Check for MCP server flag
if CommandLine.arguments.contains("--mcp-server") {
    // MCP Server Mode - stdio JSON-RPC server
    Task {
        do {
            // Get database path from Application Support
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let vibeCheckDir = appSupport.appendingPathComponent("VibeCheck")
            let dbPath = vibeCheckDir.appendingPathComponent("vibe_check.db").path

            // Start MCP server
            let server = MCPServer(dbPath: dbPath)
            try await server.run()

            // Exit cleanly
            exit(0)
        } catch {
            fputs("MCP Server error: \(error)\n", stderr)
            exit(1)
        }
    }

    // Keep process alive for async task
    dispatchMain()
} else {
    // Menubar App Mode
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
