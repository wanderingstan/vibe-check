import Foundation

/// vibe_share - Create shareable session link
struct VibeShare {
    static func execute(args: ToolArguments, dbPath: String) async throws -> String {
        guard let sessionId = args.getString("session_id") else {
            return "Error: 'session_id' parameter is required"
        }

        let title = args.getString("title")
        let slug = args.getString("slug")
        let waitForSync = args.getBool("wait_for_sync") ?? true

        // Read UserDefaults for API configuration
        let defaults = UserDefaults.standard
        let apiEnabled = defaults.bool(forKey: "apiEnabled")

        if !apiEnabled {
            return """
                Remote API is disabled in your configuration.

                To enable sharing, open VibeCheck Settings and enable Remote Sync.
                """
        }

        let apiURL = defaults.string(forKey: "apiURL") ?? ""
        let apiKey = defaults.string(forKey: "apiKey") ?? ""

        if apiURL.isEmpty || apiKey.isEmpty {
            return "API URL or API key missing in configuration."
        }

        // Create share via API
        let shareEndpoint = apiURL.hasSuffix("/api") ? "\(apiURL)/shares" : "\(apiURL)/api/shares"

        var payload: [String: Any] = [
            "scope_type": "session",
            "scope_session_id": sessionId,
            "visibility": "public",
        ]
        if let title = title {
            payload["title"] = title
        }
        if let slug = slug {
            payload["slug"] = slug
        }

        // Retry settings for sync delay
        let maxRetries = waitForSync ? 3 : 1
        let retryDelay: UInt64 = 3_000_000_000 // 3 seconds in nanoseconds

        for attempt in 0 ..< maxRetries {
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: payload)

                var request = URLRequest(url: URL(string: shareEndpoint)!)
                request.httpMethod = "POST"
                request.httpBody = jsonData
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
                request.setValue("vibe-check-mcp/1.0", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 10

                let (data, response) = try await URLSession.shared.data(for: request)

                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        if let shareUrl = result?["share_url"] as? String {
                            var output = "## Session Shared Successfully\n\n"
                            output += "**Share URL**: \(shareUrl)\n\n"
                            output += "Anyone with this link can view the session."
                            return output
                        } else if result?["status"] as? String == "ok" {
                            let shareToken = result?["share_token"] as? String ?? "unknown"
                            let shareUrl = "\(apiURL)/s/\(shareToken)"
                            var output = "## Session Shared Successfully\n\n"
                            output += "**Share URL**: \(shareUrl)\n\n"
                            output += "Anyone with this link can view the session."
                            return output
                        } else {
                            let error = result?["error"] as? String ?? result?["message"] as? String ?? "Unknown error"
                            return "Failed to create share: \(error)"
                        }
                    } else if httpResponse.statusCode == 403 {
                        // Check if it's a "not synced yet" error
                        let bodyString = String(data: data, encoding: .utf8) ?? ""
                        if bodyString.contains("do not own") && attempt < maxRetries - 1 {
                            // Session not synced yet, wait and retry
                            try await Task.sleep(nanoseconds: retryDelay)
                            continue
                        }
                        return "API error: \(httpResponse.statusCode)\n\(bodyString)"
                    } else {
                        let bodyString = String(data: data, encoding: .utf8) ?? ""
                        return "API error: \(httpResponse.statusCode)\n\(bodyString)"
                    }
                }

            } catch {
                if attempt < maxRetries - 1 {
                    try await Task.sleep(nanoseconds: retryDelay)
                    continue
                }
                return "Network error: \(error.localizedDescription)"
            }
        }

        return "Session not synced to server yet. The vibe-check daemon may need more time to upload. Try again in a few seconds."
    }
}
