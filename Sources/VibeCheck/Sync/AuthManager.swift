import Foundation
import AppKit

/// Manages device flow authentication with vibecheck server
/// Implements OAuth-like device flow for CLI authentication
actor AuthManager {
    private let apiURL: String

    struct DeviceFlowResponse: Codable {
        let deviceCode: String
        let userCode: String
        let verificationUrlComplete: String
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationUrlComplete = "verification_url_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }

    struct PollResponse: Codable {
        let status: String
        let apiKey: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case status
            case apiKey = "api_key"
            case error
        }
    }

    enum AuthError: Error, LocalizedError {
        case networkError(String)
        case timeout
        case expired
        case alreadyUsed
        case denied
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .networkError(let msg):
                return "Network error: \(msg)"
            case .timeout:
                return "Authorization timed out. Please try again."
            case .expired:
                return "Authorization code expired"
            case .alreadyUsed:
                return "Authorization code already used"
            case .denied:
                return "Authorization was denied"
            case .invalidResponse:
                return "Invalid response from server"
            }
        }
    }

    init(apiURL: String) {
        // Remove trailing /api if present
        var baseURL = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.hasSuffix("/api") {
            baseURL = String(baseURL.dropLast(4))
        }
        self.apiURL = baseURL
    }

    /// Start device flow authentication
    /// Returns (userCode, verificationURL) tuple and starts polling in background
    func startDeviceFlow() async throws -> (userCode: String, verificationURL: String, apiKey: () async throws -> String) {
        // Start device flow
        guard let url = URL(string: "\(apiURL)/api/cli/auth/start") else {
            throw AuthError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("vibe-check-macos/2.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [:])
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AuthError.networkError("Failed to start device flow")
        }

        let flowResponse = try JSONDecoder().decode(DeviceFlowResponse.self, from: data)

        // Return user code and verification URL, plus a closure to poll for the API key
        let pollClosure = { [weak self] () async throws -> String in
            guard let self = self else {
                throw AuthError.networkError("AuthManager deallocated")
            }
            return try await self.pollForApproval(
                deviceCode: flowResponse.deviceCode,
                interval: flowResponse.interval,
                expiresIn: flowResponse.expiresIn
            )
        }

        return (flowResponse.userCode, flowResponse.verificationUrlComplete, pollClosure)
    }

    /// Poll for device flow approval
    private func pollForApproval(deviceCode: String, interval: Int, expiresIn: Int) async throws -> String {
        let pollInterval = UInt64(interval) * 1_000_000_000 // Convert to nanoseconds
        let timeout = Date().addingTimeInterval(TimeInterval(expiresIn))

        while Date() < timeout {
            try await Task.sleep(nanoseconds: pollInterval)

            guard let url = URL(string: "\(apiURL)/api/cli/auth/poll") else {
                throw AuthError.invalidResponse
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("vibe-check-macos/2.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let body: [String: String] = ["device_code": deviceCode]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    continue // Network error, keep trying
                }

                if httpResponse.statusCode == 200 {
                    let pollResponse = try JSONDecoder().decode(PollResponse.self, from: data)

                    if pollResponse.status == "approved", let apiKey = pollResponse.apiKey {
                        return apiKey
                    } else if let error = pollResponse.error {
                        switch error {
                        case "expired_token":
                            throw AuthError.expired
                        case "token_already_used":
                            throw AuthError.alreadyUsed
                        case "denied":
                            throw AuthError.denied
                        default:
                            continue // Keep polling
                        }
                    }
                } else if httpResponse.statusCode == 202 {
                    // Still pending, continue polling
                    continue
                } else {
                    // Unexpected status, continue polling
                    continue
                }
            } catch is DecodingError {
                continue // Invalid response, keep trying
            } catch let error as AuthError {
                throw error // Re-throw auth errors
            } catch {
                continue // Network error, keep trying
            }
        }

        throw AuthError.timeout
    }

    /// Open verification URL in browser
    func openVerificationURL(_ urlString: String) async {
        await MainActor.run {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
