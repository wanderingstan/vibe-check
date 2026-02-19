import Foundation

/// HTTP client for VibeCheck remote API
/// Handles authentication and event uploads
actor APIClient {
    private let session: URLSession
    private var apiURL: String
    private var apiKey: String

    init(apiURL: String, apiKey: String) {
        self.apiURL = apiURL.hasSuffix("/api") ? apiURL : apiURL + "/api"
        self.apiKey = apiKey

        // Configure URLSession
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    /// Check API health
    func healthCheck() async throws -> Bool {
        let url = URL(string: "\(apiURL)/health")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("vibe-check-macos/2.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            return true
        } else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    /// Upload events to remote API
    func uploadEvents(_ events: [[String: Any]]) async throws -> Int {
        let url = URL(string: "\(apiURL)/events")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("vibe-check-macos/2.0", forHTTPHeaderField: "User-Agent")

        // Prepare payload
        let payload: [String: Any] = [
            "events": events
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
            // Parse response to get count of uploaded events
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let uploaded = json["uploaded"] as? Int
            {
                return uploaded
            }
            return events.count
        } else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }
}

// MARK: - API Error

enum APIError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode, let body):
            return "HTTP \(statusCode): \(body)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
