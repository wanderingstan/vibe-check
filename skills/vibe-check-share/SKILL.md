---
name: vibe-check-share
description: Create a public share link for the current Claude Code session. Use when user says "share session", "share this session", "get share link", "create share link", or "share my work".
---

# Share Current Session

**Purpose:** Create a public share link for the current Claude Code session so users can share their conversation with friends.

---

## Overview

This skill uses the vibe-check MCP tools to:
1. Get the current session ID using `mcp__vibe-check__vibe_session`
2. Create a share link using `mcp__vibe-check__vibe_share`

If the MCP tools are not available (fallback only), it can use the legacy marker technique.

---

## Primary Method: Use MCP Tools

### Step 1: Get Current Session ID

Call the MCP tool to get the current session information:

```
Use mcp__vibe-check__vibe_session with no parameters
```

This will return session information including the session ID.

### Step 2: Create Share Link

Call the MCP share tool with the session ID:

```
Use mcp__vibe-check__vibe_share with:
- session_id: [the session ID from step 1]
- title: (optional) Custom title for the share
- slug: (optional) Custom URL slug
```

The tool will:
- Read API configuration from ~/.vibe-check/config.json
- Create the share via the vibecheck API
- Return the shareable URL
- Handle retries if the session hasn't synced yet

### Step 3: Display the Result

The MCP tool will return the share URL. Present it to the user.

---

## Fallback Method: Legacy Marker Technique

**IMPORTANT:** Only use this if the MCP tools are unavailable or fail. This is a last resort.

<details>
<summary>Click to expand fallback instructions</summary>

### Step 1: Generate and Emit Session Marker

Generate a unique marker string:
```
VIBE_SESSION_MARKER_[random 16 character hex string]
```

**IMPORTANT:** Output this marker directly in your response:

```
Creating share link for this session...
Session marker: VIBE_SESSION_MARKER_[your-generated-marker]
```

### Step 2: Wait for Logging

Wait 2 seconds for vibe-check to log the marker:

```bash
sleep 2
```

### Step 3: Get Session ID from Database

Query the local SQLite database to find the session ID:

```bash
sqlite3 "file:$HOME/.vibe-check/vibe_check.db?mode=ro" \
  "SELECT event_session_id FROM conversation_events WHERE event_data LIKE '%VIBE_SESSION_MARKER_[your-marker]%' ORDER BY event_timestamp DESC LIMIT 1;"
```

Replace `[your-marker]` with the actual marker you generated.

Save the result as `SESSION_ID`.

### Step 4: Get API Configuration

Read the API key and URL from the vibe-check config:

```bash
# Get API key
cat ~/.vibe-check/config.json | jq -r '.api.api_key'

# Get API URL (defaults to https://vibecheck.wanderingstan.com)
cat ~/.vibe-check/config.json | jq -r '.api.url // "https://vibecheck.wanderingstan.com"'
```

### Step 5: Create the Share

Make the API call to create a public session share:

```bash
curl -s -X POST "${API_URL}/api/shares" \
  -H "X-API-Key: ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"scope_type\": \"session\",
    \"scope_session_id\": \"${SESSION_ID}\",
    \"visibility\": \"public\"
  }"
```

The response will include:
```json
{
  "status": "ok",
  "share_id": 123,
  "share_token": "7Kx9mPqR2vL...",
  "share_url": "https://vibecheck.wanderingstan.com/s/7Kx9mPqR2vL...",
  "slug": null
}
```

### Step 6: Display the Share URL

Present the share URL prominently to the user:

```
Session Share Created!

Share URL: https://vibecheck.wanderingstan.com/s/[token]

Anyone with this link can view your conversation from this session.
```

</details>

---

## Troubleshooting

### "Cannot share content you do not own"

This means the session ID doesn't have any events owned by this user. Possible causes:
- vibe-check isn't running or hasn't synced to the remote API yet
- The API key belongs to a different user
- The session is too new and hasn't been synced

**Fix:** Run `vibe-check status` to check if remote sync is working. The MCP tool automatically retries for a few seconds to handle sync delays.

### "Not authenticated" or "Remote API is disabled"

No API key found in config, or remote sync is disabled.

**Fix:** Run `vibe-check auth login` to authenticate and enable remote sync.

### MCP Tools Not Available

If the MCP server isn't running or configured, fall back to the legacy marker technique above.

---

## Advanced Options

When using the MCP tool, you can customize the share:

```
Use mcp__vibe-check__vibe_share with:
- session_id: [session ID]
- title: "My awesome coding session"
- slug: "my-cool-session"
```

With a custom slug, the URL becomes: `https://vibecheck.wanderingstan.com/s/my-cool-session`
