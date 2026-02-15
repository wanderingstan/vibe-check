import Foundation

/// Background poller for guest session messages
/// Polls the vibe-check API every 30 seconds for incoming messages
actor GuestSessionPoller {
    private let apiBaseURL: String
    private let githubHandle: String
    private var cache = GuestMessagesCache()
    private var pollingTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 30

    init(apiBaseURL: String = "https://vibecheck.wanderingstan.com", githubHandle: String) {
        self.apiBaseURL = apiBaseURL
        self.githubHandle = githubHandle
    }

    /// Start background polling
    func startPolling() {
        guard pollingTask == nil else { return }

        pollingTask = Task {
            while !Task.isCancelled {
                await fetchMessages()

                // Wait for next poll interval
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
    }

    /// Stop background polling
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Fetch messages from API (called by background poller)
    private func fetchMessages() async {
        do {
            let url = URL(string: "\(apiBaseURL)/api/session/guest?handle=\(githubHandle)")!

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GuestSessionError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw GuestSessionError.httpError(statusCode: httpResponse.statusCode)
            }

            let decoder = JSONDecoder()
            let messagesResponse = try decoder.decode(GuestMessagesResponse.self, from: data)

            if messagesResponse.success {
                cache.update(with: messagesResponse)
            }

        } catch {
            cache.lastError = "Polling error: \(error.localizedDescription)"
        }
    }

    /// Get current cached messages (called by MCP tool)
    func getCachedMessages() -> [GuestMessage] {
        cache.messages
    }

    /// Get only unacknowledged messages
    func getUnacknowledgedMessages() -> [GuestMessage] {
        cache.unacknowledgedMessages()
    }

    /// Get cache status
    func getStatus() -> (lastFetch: Date?, messageCount: Int, error: String?) {
        (cache.lastFetch, cache.messages.count, cache.lastError)
    }

    /// Acknowledge messages and clear them from the server
    func acknowledgeMessages(_ messageIds: [String]) async throws {
        guard !messageIds.isEmpty else { return }

        // Mark as acknowledged locally
        cache.acknowledge(Set(messageIds))

        // ACK on server (clears the queue)
        let url = URL(string: "\(apiBaseURL)/api/session/guest?handle=\(githubHandle)&ack=true")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GuestSessionError.ackFailed
        }

        // Prune old acknowledged messages (keep for 5 minutes in case of retries)
        cache.pruneAcknowledged(olderThan: 300)
    }

    /// Force an immediate fetch (for manual refresh)
    func refresh() async {
        await fetchMessages()
    }
}

enum GuestSessionError: Error {
    case invalidResponse
    case httpError(statusCode: Int)
    case ackFailed
    case notConfigured

    var localizedDescription: String {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .ackFailed:
            return "Failed to acknowledge messages on server"
        case .notConfigured:
            return "GitHub handle not configured"
        }
    }
}
