import Foundation

/// vibe_guest_messages - Check for guest messages sent to this user's session
struct VibeGuestMessages {
    static func execute(args: ToolArguments, poller: GuestSessionPoller?) async throws -> String {
        guard let poller = poller else {
            return """
                ## Guest Messages Not Configured

                Guest messaging is not enabled. To enable it:
                1. Open VibeCheck Settings
                2. Set your GitHub username
                3. Restart the MCP server

                Guest messages allow others to send you messages that appear in your Claude Code session.
                """
        }

        let action = args.getString("action") ?? "check"

        switch action {
        case "check":
            return await checkMessages(poller: poller)

        case "ack", "acknowledge":
            let messageIds = args.getString("message_ids")?.split(separator: ",").map(String.init) ?? []
            return await acknowledgeMessages(poller: poller, messageIds: messageIds)

        case "status":
            return await getStatus(poller: poller)

        case "refresh":
            await poller.refresh()
            return await checkMessages(poller: poller)

        default:
            return "Unknown action: \(action). Valid actions: check, ack, status, refresh"
        }
    }

    private static func checkMessages(poller: GuestSessionPoller) async -> String {
        let messages = await poller.getUnacknowledgedMessages()

        if messages.isEmpty {
            let (lastFetch, _, error) = await poller.getStatus()
            var output = "## No New Guest Messages\n\n"
            if let lastFetch = lastFetch {
                let formatter = RelativeDateTimeFormatter()
                let relative = formatter.localizedString(for: lastFetch, relativeTo: Date())
                output += "Last checked: \(relative)\n"
            }
            if let error = error {
                output += "\n⚠️ Last polling error: \(error)\n"
            }
            return output
        }

        var output = "## 📬 Guest Messages (\(messages.count) new)\n\n"

        // Sort by timestamp (oldest first)
        let sortedMessages = messages.sorted { msg1, msg2 in
            msg1.timestamp < msg2.timestamp
        }

        for message in sortedMessages {
            output += "---\n\n"
            output += "**From**: \(message.from)\n"
            if let sessionId = message.sessionId {
                output += "**Session**: `\(sessionId)`\n"
            }
            output += "**Time**: \(formatTimestamp(message.timestamp))\n\n"
            output += "> \(message.message)\n\n"
            output += "_Message ID: `\(message.id)`_\n\n"
        }

        output += """
            ---

            **Next Steps**:
            - To acknowledge these messages and clear them from the queue, call this tool again with:
              `action: "ack"`
            - Messages will remain visible until acknowledged
            """

        return output
    }

    private static func acknowledgeMessages(poller: GuestSessionPoller, messageIds: [String]) async -> String {
        do {
            // If no specific IDs provided, acknowledge all unacknowledged messages
            let idsToAck: [String]
            if messageIds.isEmpty {
                let messages = await poller.getUnacknowledgedMessages()
                idsToAck = messages.map { $0.id }
            } else {
                idsToAck = messageIds
            }

            guard !idsToAck.isEmpty else {
                return "No messages to acknowledge."
            }

            try await poller.acknowledgeMessages(idsToAck)

            return """
                ## ✅ Messages Acknowledged

                Acknowledged and cleared \(idsToAck.count) message(s) from the server queue.

                The messages have been removed from the server and won't appear again.
                """

        } catch {
            return "Failed to acknowledge messages: \(error.localizedDescription)"
        }
    }

    private static func getStatus(poller: GuestSessionPoller) async -> String {
        let (lastFetch, totalCount, error) = await poller.getStatus()
        let unackCount = await poller.getUnacknowledgedMessages().count

        var output = "## Guest Message Status\n\n"

        if let lastFetch = lastFetch {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            output += "**Last polled**: \(formatter.string(from: lastFetch))\n"
        } else {
            output += "**Last polled**: Never\n"
        }

        output += "**Total cached messages**: \(totalCount)\n"
        output += "**Unacknowledged messages**: \(unackCount)\n"

        if let error = error {
            output += "\n⚠️ **Last error**: \(error)\n"
        }

        output += "\n_Polling every 30 seconds in background_\n"

        return output
    }

    private static func formatTimestamp(_ timestamp: String) -> String {
        // Try to parse ISO 8601 timestamp
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: timestamp) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .short
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }
        return timestamp
    }
}
