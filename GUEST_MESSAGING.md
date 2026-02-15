# Guest Messaging Feature

## Overview

The Guest Messaging feature enables real-time communication with your Claude Code session through the vibe-check MCP server. Others can send you messages via the web API, and those messages become available to Claude through an MCP tool.

## Architecture

### Components

1. **GuestSessionPoller** (`Sources/VibeCheck/MCP/GuestSessionPoller.swift`)
   - Background actor that polls the API every 30 seconds
   - Fetches messages from `GET /api/session/guest?handle={HANDLE}`
   - Maintains an in-memory cache of messages
   - Handles acknowledgment via `GET /api/session/guest?handle={HANDLE}&ack=true`

2. **GuestMessage Models** (`Sources/VibeCheck/MCP/GuestMessage.swift`)
   - Data structures for messages and caching
   - Tracks acknowledged vs. unacknowledged messages
   - Auto-prunes old acknowledged messages

3. **VibeGuestMessages Tool** (`Sources/VibeCheck/MCP/Tools/VibeGuestMessages.swift`)
   - MCP tool that Claude can call to check messages
   - Actions: `check`, `ack`, `status`, `refresh`
   - Formats messages for display to Claude

4. **MCPServer Integration** (`Sources/VibeCheck/MCP/MCPServer.swift`)
   - Initializes poller on startup if GitHub handle is configured
   - Starts/stops polling with server lifecycle
   - Routes tool calls to the appropriate handler

5. **Settings UI** (`Sources/VibeCheck/UI/SettingsView.swift`)
   - GitHub username configuration field
   - Added to Integration tab
   - Visual feedback when configured

## API Endpoint

### GET /api/session/guest

**URL**: `https://www.slashvibe.dev/api/session/guest`

**Parameters**:
- `handle` (required): GitHub username of the recipient
- `ack` (optional): Set to `true` to acknowledge and clear messages

**Response**:
```json
{
  "success": true,
  "messages": [
    {
      "id": "guest_1234567890_abc123",
      "from": "sender_username",
      "message": "Hello from the guest!",
      "sessionId": "optional-session-id",
      "timestamp": "2026-02-15T09:30:00Z"
    }
  ],
  "count": 1
}
```

**Features**:
- Messages stored in Vercel KV (Redis)
- Max 20 messages per user queue
- 1-hour TTL (auto-expire)
- Message length capped at 2000 characters

## Usage

### Configuration

1. **Set GitHub Username**:
   - Open VibeCheck Settings → Integration tab
   - Enter your GitHub username in the "Guest Messaging" section
   - Polling automatically starts when MCP server launches

2. **Verify Setup**:
   ```swift
   // Check UserDefaults for configuration
   defaults read com.wanderingstan.vibe-check githubHandle
   ```

### MCP Tool Usage

Claude can call the `vibe_guest_messages` tool with these actions:

#### Check for Messages
```
vibe_guest_messages(action="check")
```
Returns formatted list of unacknowledged messages.

#### Acknowledge Messages
```
vibe_guest_messages(action="ack")
```
Marks all unacknowledged messages as read and clears them from the server queue.

To acknowledge specific messages:
```
vibe_guest_messages(action="ack", message_ids="msg1,msg2,msg3")
```

#### View Status
```
vibe_guest_messages(action="status")
```
Shows polling status, cached message count, and last error (if any).

#### Force Refresh
```
vibe_guest_messages(action="refresh")
```
Immediately polls the API and returns new messages.

### Natural Language Triggers

Users can say:
- "check my messages"
- "any guest messages?"
- "do I have any messages?"

And Claude will call the appropriate MCP tool.

## How It Works

### Message Flow

1. **Sending** (from web/API):
   ```
   POST /api/session/guest
   {
     "from": "alice",
     "to": "bob",
     "message": "Hey Bob, check out this code..."
   }
   ```

2. **Polling** (background, every 30s):
   ```
   GET /api/session/guest?handle=bob
   → Cache messages locally in memory
   ```

3. **Checking** (Claude calls tool):
   ```
   vibe_guest_messages(action="check")
   → Returns cached messages
   ```

4. **Acknowledging** (after Claude reads):
   ```
   vibe_guest_messages(action="ack")
   → Marks local messages as acknowledged
   → Sends GET /api/session/guest?handle=bob&ack=true
   → Server clears the queue
   ```

### Caching Strategy

- **In-Memory Cache**: Messages stored in `GuestMessagesCache`
- **Deduplication**: New messages merged by ID, existing ones preserved
- **Acknowledged Tracking**: Each message has an `acknowledged` flag
- **Pruning**: Old acknowledged messages removed after 5 minutes

### Lifecycle

1. **MCP Server Starts**:
   - Reads `githubHandle` from UserDefaults
   - Creates `GuestSessionPoller` if configured
   - Starts background polling task

2. **Polling Loop**:
   ```swift
   while !Task.isCancelled {
       await fetchMessages()  // GET /api/session/guest
       try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30s
   }
   ```

3. **MCP Server Stops**:
   - Cancels polling task
   - Cleans up resources

## Configuration Files

### UserDefaults Keys

- `githubHandle`: GitHub username for guest messaging
- `apiURL`: Base URL for guest session API (default: `https://www.slashvibe.dev`)

### PLUGIN-CLAUDE.md

Updated with new tool documentation:
```markdown
| `vibe_guest_messages` | Check for guest messages | `vibe_guest_messages(action="check")` |
```

## Error Handling

### Network Errors
- Stored in `cache.lastError`
- Polling continues despite errors
- Displayed via `status` action

### Configuration Errors
- If GitHub handle not set, tool returns helpful error message
- User directed to Settings → Integration

### API Errors
- HTTP error codes captured and logged
- Acknowledgment failures don't affect local cache

## Testing

### Manual Testing

1. **Send a test message** (via API or web interface):
   ```bash
   curl -X POST https://www.slashvibe.dev/api/session/guest \
     -H "Content-Type: application/json" \
     -d '{
       "from": "testuser",
       "to": "YOUR_GITHUB_HANDLE",
       "message": "Test message from API"
     }'
   ```

2. **Check in Claude**:
   ```
   User: "check my messages"
   Claude: [calls vibe_guest_messages(action="check")]
   → Shows the test message
   ```

3. **Acknowledge**:
   ```
   User: "acknowledge those messages"
   Claude: [calls vibe_guest_messages(action="ack")]
   → Clears queue
   ```

4. **Verify cleared**:
   ```bash
   curl "https://www.slashvibe.dev/api/session/guest?handle=YOUR_GITHUB_HANDLE"
   # Should return empty messages array
   ```

### Integration Testing

```bash
# 1. Build the app
swift build

# 2. Run MCP server with test GitHub handle
defaults write com.wanderingstan.vibe-check githubHandle "testuser"
./build/debug/VibeCheck --mcp-server

# 3. Send JSON-RPC request
echo '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"vibe_guest_messages","arguments":{"action":"status"}},"id":1}' | ./build/debug/VibeCheck --mcp-server
```

## Security Considerations

### Authentication
- Requires user to be logged in via GitHub OAuth (on web side)
- `handle` parameter links messages to authenticated GitHub user

### Rate Limiting
- Server-side: 20 messages per queue
- Client-side: 30-second polling interval (max 120 requests/hour)

### Data Privacy
- Messages transit through vibe-check server
- Messages expire after 1 hour
- No encryption at rest (stored in Vercel KV)

### Input Validation
- Message length: max 2000 characters
- Handle: validated against authenticated user
- No SQL injection risk (uses KV store, not SQL)

## Future Enhancements

### Potential Improvements

1. **Push Notifications**: Use MCP notifications API when available
2. **Message History**: Store acknowledged messages in SQLite
3. **Rich Media**: Support for code snippets, links, formatting
4. **Message Threads**: Reply to specific messages
5. **Presence**: Show who's currently online
6. **Typing Indicators**: Real-time feedback when others are typing
7. **Encryption**: End-to-end encryption for sensitive messages
8. **Desktop Notifications**: macOS notification center integration

### API Enhancements

1. **WebSocket Support**: Real-time bidirectional communication
2. **Message Read Receipts**: Track when messages are read
3. **Message Editing/Deletion**: Modify sent messages
4. **Attachments**: Send files, images, or code snippets

## Troubleshooting

### Messages Not Appearing

1. **Check GitHub handle is set**:
   ```bash
   defaults read com.wanderingstan.vibe-check githubHandle
   ```

2. **Verify MCP server is running**:
   ```bash
   ps aux | grep VibeCheck
   ```

3. **Check polling status**:
   ```
   vibe_guest_messages(action="status")
   ```

4. **Test API directly**:
   ```bash
   curl "https://www.slashvibe.dev/api/session/guest?handle=YOUR_HANDLE"
   ```

### Polling Errors

- Check `status` action for last error
- Verify network connectivity
- Confirm API URL is correct in settings
- Check server logs for API issues

### Acknowledgment Failures

- Messages remain in local cache even if ACK fails
- Retry acknowledgment with `ack` action
- Check network connectivity

## Related Files

- `Sources/VibeCheck/MCP/GuestMessage.swift` - Data models
- `Sources/VibeCheck/MCP/GuestSessionPoller.swift` - Polling logic
- `Sources/VibeCheck/MCP/Tools/VibeGuestMessages.swift` - MCP tool
- `Sources/VibeCheck/MCP/MCPServer.swift` - Server integration
- `Sources/VibeCheck/UI/SettingsView.swift` - UI configuration
- `PLUGIN-CLAUDE.md` - Tool documentation

## API Documentation

See `/Users/wanderingstan/Developer/vibe-platform/api/session/guest.js` for server-side implementation details.
