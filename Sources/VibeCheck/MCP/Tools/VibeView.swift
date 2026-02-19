import Foundation
import AppKit

/// vibe_view - Open local web viewer for conversations
struct VibeView {
    static func execute(args: ToolArguments, dbPath: String) async throws -> String {
        let sessionId = args.getString("session_id")
        let messageUuid = args.getString("message_uuid")
        let port = Int(ProcessInfo.processInfo.environment["VIBE_CHECK_WEB_PORT"] ?? "8765") ?? 8765

        // Check if server is running
        let isRunning = await checkServerRunning(port: port)

        if !isRunning {
            return """
                Local web server is not running on port \(port).

                Start it with:
                ```bash
                python ~/.vibe-check/mcp-server/web_server.py
                ```

                Or if installed via git:
                ```bash
                cd ~/Developer/vibe-check && python mcp-server/web_server.py
                ```
                """
        }

        // Build URL
        let urlString: String
        if let sessionId = sessionId {
            if let messageUuid = messageUuid {
                urlString = "http://localhost:\(port)/session/\(sessionId)?msg=\(messageUuid)"
            } else {
                urlString = "http://localhost:\(port)/session/\(sessionId)"
            }
        } else {
            urlString = "http://localhost:\(port)/"
        }

        if let url = URL(string: urlString) {
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }

            if let sessionId = sessionId {
                if let messageUuid = messageUuid {
                    return "Opened session \(String(sessionId.prefix(8)))... at message \(String(messageUuid.prefix(8)))... in browser:\n\(urlString)"
                }
                return "Opened session \(String(sessionId.prefix(8)))... in browser:\n\(urlString)"
            }
            return "Opened session list in browser:\n\(urlString)"
        } else {
            return "Could not open browser. Visit manually:\n\(urlString)"
        }
    }

    private static func checkServerRunning(port: Int) async -> Bool {
        // Try to connect to the port
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(sock, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }
}
