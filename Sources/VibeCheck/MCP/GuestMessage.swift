import Foundation

/// Guest message data structures

struct GuestMessage: Codable, Identifiable, Equatable {
    let id: String
    let from: String
    let message: String
    let sessionId: String?
    let timestamp: String
    var acknowledged: Bool = false

    /// When this message was first seen locally
    var firstSeenAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, from, message, sessionId, timestamp
    }

    static func == (lhs: GuestMessage, rhs: GuestMessage) -> Bool {
        lhs.id == rhs.id
    }
}

struct GuestMessagesResponse: Codable {
    let success: Bool
    let messages: [GuestMessage]
    let count: Int
}

struct GuestMessagesCache {
    var messages: [GuestMessage] = []
    var lastFetch: Date?
    var lastError: String?

    mutating func update(with response: GuestMessagesResponse) {
        // Merge new messages, preserving existing ones
        let existingIds = Set(messages.map { $0.id })
        let newMessages = response.messages.filter { !existingIds.contains($0.id) }

        messages.append(contentsOf: newMessages)
        lastFetch = Date()
        lastError = nil
    }

    mutating func acknowledge(_ messageIds: Set<String>) {
        for i in messages.indices {
            if messageIds.contains(messages[i].id) {
                messages[i].acknowledged = true
            }
        }
    }

    /// Remove acknowledged messages older than the given age
    mutating func pruneAcknowledged(olderThan age: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-age)
        messages.removeAll { message in
            message.acknowledged && message.firstSeenAt < cutoff
        }
    }

    func unacknowledgedMessages() -> [GuestMessage] {
        messages.filter { !$0.acknowledged }
    }
}
