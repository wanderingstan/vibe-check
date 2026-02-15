import Foundation

/// MCP Server - handles stdio JSON-RPC communication
/// Launched with --mcp-server flag by Claude Code
actor MCPServer {
    private let dbPath: String
    private var isRunning = false

    init(dbPath: String) {
        self.dbPath = dbPath
    }

    /// Start the MCP server (runs until stdin closes)
    func run() async throws {
        isRunning = true
        print("MCP Server started - reading from stdin...", to: &stderrStream)

        // Read from stdin line by line
        while isRunning {
            guard let line = readLine() else {
                // stdin closed
                break
            }

            guard !line.isEmpty else {
                continue
            }

            await handleRequest(line)
        }

        print("MCP Server stopped", to: &stderrStream)
    }

    /// Handle a single JSON-RPC request
    private func handleRequest(_ line: String) async {
        do {
            // Parse JSON-RPC request
            guard let data = line.data(using: .utf8) else {
                throw MCPError.invalidJSON("Failed to encode line as UTF-8")
            }

            let request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)

            // Route to appropriate handler
            let response = await routeRequest(request)

            // Send response to stdout
            let responseData = try JSONEncoder().encode(response)
            if let responseString = String(data: responseData, encoding: .utf8) {
                print(responseString, to: &stdoutStream)
                fflush(stdout)
            }

        } catch let error as MCPError {
            sendError(message: error.message, code: -32603, id: nil)
        } catch {
            sendError(message: "Internal error: \(error)", code: -32603, id: nil)
        }
    }

    /// Route request to appropriate tool
    private func routeRequest(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard let params = request.params,
              let toolName = params.name
        else {
            return JSONRPCResponse(
                error: ResponseError(code: -32602, message: "Invalid params", data: nil),
                id: request.id
            )
        }

        let args = ToolArguments(params.arguments ?? [:])

        do {
            let output: String

            switch toolName {
            case "vibe_stats":
                output = try await VibeStats.execute(args: args, dbPath: dbPath)
            case "vibe_search":
                output = try await VibeSearch.execute(args: args, dbPath: dbPath)
            case "vibe_tools":
                output = try await VibeTools.execute(args: args, dbPath: dbPath)
            case "vibe_recent":
                output = try await VibeRecent.execute(args: args, dbPath: dbPath)
            case "vibe_session":
                output = try await VibeSession.execute(args: args, dbPath: dbPath)
            case "vibe_share":
                output = try await VibeShare.execute(args: args, dbPath: dbPath)
            case "vibe_open_stats":
                output = try await VibeOpenStats.execute(args: args, dbPath: dbPath)
            case "vibe_doctor":
                output = try await VibeDoctor.execute(args: args, dbPath: dbPath)
            case "vibe_sql":
                output = try await VibeSQL.execute(args: args, dbPath: dbPath)
            case "vibe_view":
                output = try await VibeView.execute(args: args, dbPath: dbPath)
            default:
                throw MCPError.unknownTool(toolName)
            }

            return JSONRPCResponse(
                result: ResponseResult(content: [
                    ResponseResult.ContentItem(type: "text", text: output)
                ]),
                id: request.id
            )

        } catch let error as MCPError {
            return JSONRPCResponse(
                error: ResponseError(code: -32603, message: error.message, data: nil),
                id: request.id
            )
        } catch {
            return JSONRPCResponse(
                error: ResponseError(code: -32603, message: "Tool error: \(error)", data: nil),
                id: request.id
            )
        }
    }

    /// Send error response
    private func sendError(message: String, code: Int, id: JSONRPCRequest.RequestID?) {
        let response = JSONRPCResponse(
            error: ResponseError(code: code, message: message, data: nil),
            id: id
        )

        if let data = try? JSONEncoder().encode(response),
           let string = String(data: data, encoding: .utf8)
        {
            print(string, to: &stdoutStream)
            fflush(stdout)
        }
    }

    /// Stop the server
    func stop() {
        isRunning = false
    }
}

// MARK: - MCP Error

enum MCPError: Error {
    case invalidJSON(String)
    case unknownTool(String)
    case databaseError(String)
    case toolError(String)

    var message: String {
        switch self {
        case .invalidJSON(let msg):
            return "Invalid JSON: \(msg)"
        case .unknownTool(let tool):
            return "Unknown tool: \(tool)"
        case .databaseError(let msg):
            return "Database error: \(msg)"
        case .toolError(let msg):
            return "Tool error: \(msg)"
        }
    }
}

// MARK: - Stream Helpers

/// Custom print to stderr
private var stderrStream = FileHandleOutputStream(fileHandle: .standardError)

/// Custom print to stdout
private var stdoutStream = FileHandleOutputStream(fileHandle: .standardOutput)

struct FileHandleOutputStream: TextOutputStream {
    let fileHandle: FileHandle

    func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            fileHandle.write(data)
        }
    }
}

/// Helper print function for specific stream
private func print(_ items: Any..., separator: String = " ", terminator: String = "\n", to stream: inout some TextOutputStream) {
    let output = items.map { "\($0)" }.joined(separator: separator) + terminator
    stream.write(output)
}
