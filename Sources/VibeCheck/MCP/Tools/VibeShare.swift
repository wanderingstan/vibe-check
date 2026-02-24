import Foundation
import AppKit

/// vibe_share - Create shareable session link
/// Handles auth, scope registration, and share creation in one flow:
///   1. If no API key → guide user through device-flow auth (browser opens automatically)
///   2. Register session in sync_scopes so RemoteSyncWorker uploads it
///   3. Create share via API (retries while waiting for sync)
struct VibeShare {
    static func execute(args: ToolArguments, dbPath: String) async throws -> String {
        guard let sessionId = args.getString("session_id") else {
            return "Error: 'session_id' parameter is required"
        }

        let title = args.getString("title")
        let slug = args.getString("slug")
        let waitForSync = args.getBool("wait_for_sync") ?? true

        // Read API credentials from UserDefaults
        let defaults = UserDefaults.standard
        var apiURL = defaults.string(forKey: "apiURL") ?? ""
        var apiKey = defaults.string(forKey: "apiKey") ?? ""

        if apiURL.isEmpty {
            apiURL = "https://vibecheck.wanderingstan.com/api"
        }

        // STEP 1: Ensure we have an API key (device flow if needed)
        if apiKey.isEmpty {
            let authResult = await performDeviceFlowAuth(apiURL: apiURL)
            switch authResult {
            case .success(let newKey):
                apiKey = newKey
                defaults.set(newKey, forKey: "apiKey")
                // Note: does NOT enable global sync — user chose selective sharing
            case .timedOut:
                return """
                    ## Authentication Required

                    Your browser was opened to authenticate with VibeCheck. The authorization \
                    timed out before you approved it.

                    Please run `vibe_share` again and approve the login request in your browser \
                    within 5 minutes.
                    """
            case .denied:
                return "Authorization was denied. Sharing requires a VibeCheck account."
            case .failed(let msg):
                return "Authentication failed: \(msg). Please try again."
            }
        }

        // STEP 2: Register session in sync_scopes so RemoteSyncWorker uploads it
        do {
            let dbManager = try DatabaseManager(databasePath: dbPath)
            try await dbManager.setupDatabase()
            try await dbManager.addSessionSyncScope(sessionId: sessionId)
            // RemoteSyncWorker in the GUI process reads sync_scopes every 5s
            // and will begin uploading this session's events automatically
        } catch {
            // Non-fatal: log but continue. Share creation will retry if not synced yet.
            fputs("VibeShare: Failed to register sync scope: \(error)\n", stderr)
        }

        // STEP 3: Create share link (retries while waiting for sync to complete)
        return try await createShareLink(
            sessionId: sessionId,
            apiURL: apiURL,
            apiKey: apiKey,
            title: title,
            slug: slug,
            waitForSync: waitForSync
        )
    }

    // MARK: - Auth Result

    enum AuthResult {
        case success(String)
        case timedOut
        case denied
        case failed(String)
    }

    // MARK: - Device Flow Auth

    private static func performDeviceFlowAuth(apiURL: String) async -> AuthResult {
        let authManager = AuthManager(apiURL: apiURL)

        do {
            let (userCode, verificationURL, pollForKey) = try await authManager.startDeviceFlow()

            // Open browser automatically — user just needs to approve
            await authManager.openVerificationURL(verificationURL)

            fputs("VibeShare: Auth required. Code: \(userCode), URL: \(verificationURL)\n", stderr)

            // Poll until approved or timed out (blocks up to ~5 minutes per device flow)
            let newApiKey = try await pollForKey()
            return .success(newApiKey)

        } catch let error as AuthManager.AuthError {
            switch error {
            case .timeout: return .timedOut
            case .expired: return .timedOut
            case .denied: return .denied
            case .alreadyUsed: return .timedOut
            default: return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Share Link Creation

    private static func createShareLink(
        sessionId: String,
        apiURL: String,
        apiKey: String,
        title: String?,
        slug: String?,
        waitForSync: Bool
    ) async throws -> String {
        let shareEndpoint = apiURL.hasSuffix("/api")
            ? "\(apiURL)/shares"
            : "\(apiURL)/api/shares"

        var payload: [String: Any] = [
            "scope_type": "session",
            "scope_session_id": sessionId,
            "visibility": "public",
        ]
        if let title { payload["title"] = title }
        if let slug { payload["slug"] = slug }

        // Extended retry window: RemoteSyncWorker polls every 5s and upload takes a few seconds.
        // 8 retries × 5s = up to 40s waiting for sync before giving up.
        let maxRetries = waitForSync ? 8 : 1
        let retryDelay: UInt64 = 5_000_000_000 // 5 seconds

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
                        let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        if let shareUrl = result?["share_url"] as? String {
                            return formatSuccess(shareUrl: shareUrl)
                        } else if result?["status"] as? String == "ok",
                                  let token = result?["share_token"] as? String {
                            let base = apiURL.hasSuffix("/api")
                                ? String(apiURL.dropLast(4))
                                : apiURL
                            return formatSuccess(shareUrl: "\(base)/s/\(token)")
                        }
                        let errMsg = (result?["error"] as? String)
                            ?? (result?["message"] as? String)
                            ?? "Unknown error"
                        return "Failed to create share: \(errMsg)"

                    } else if httpResponse.statusCode == 403 {
                        let body = String(data: data, encoding: .utf8) ?? ""
                        if body.contains("do not own") && attempt < maxRetries - 1 {
                            // Session not yet synced — wait for RemoteSyncWorker
                            try await Task.sleep(nanoseconds: retryDelay)
                            continue
                        }
                        return "API error 403: \(body)"

                    } else {
                        let body = String(data: data, encoding: .utf8) ?? ""
                        return "API error \(httpResponse.statusCode): \(body)"
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

        return """
            Session syncing is in progress but taking longer than expected.
            VibeCheck is uploading your session data. Please try again in 30 seconds.
            """
    }

    private static func formatSuccess(shareUrl: String) -> String {
        return """
            ## Session Shared Successfully

            **Share URL**: \(shareUrl)

            Anyone with this link can view the session.
            """
    }
}
