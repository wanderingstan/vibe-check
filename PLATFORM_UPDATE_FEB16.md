# /vibe Platform Update — Feb 16, 2026

Hey Stan — here's where things stand and where we're headed.

## What's Stable (V1)

Everything from the last 2 weeks is solid and deployed:

- **Presence** — multi-source heartbeat, Postgres-backed, 30s cache
- **DMs** — Postgres V2, SSE real-time, typing indicators
- **Buddy v0.5.1** — buddy list, DMs, inbox, auto-updater, session entities
- **MCP server** — 130+ tools, `npx slashvibe-mcp`
- **Guest messaging** — your GuestSessionPoller works with our `/api/session/guest` endpoint (unchanged)
- **Session entities** — `@handle/claude` in presence + DM routing
- **WebRTC calls** — signaling via KV, STUN+TURN
- **Broadcasting** — terminal streaming via SSE

## What Just Shipped (Tonight)

5 new features built in parallel — all ready to deploy:

### 1. Rooms (`api/room.js`)
Many:many spaces replacing the 1:1 pair system. Three types:
- `coding` — pair programming replacement
- `watching` — group viewing of broadcasts
- `hangout` — social space

Create/join/leave/list. KV-backed, 8hr TTL, max 8 members per room. Host auto-promotes on leave. SSE notifications to members on join/leave.

**Your integration:** Buddy could show room membership in the buddy list. Room status replaces pair status.

### 2. Prompt/Code Slider (`api/session/replay.js` + `public/slider.html`)
Web viewer at `/slider?handle=X` that lets you scrub through a live session:
- Three modes: Prompts only / Code only / Both
- Timeline scrubber at bottom with color-coded ticks
- Keyboard nav (j/k, arrow keys, 1/2/3 for modes)
- Syntax highlighting (CSS-only, no external deps)
- Polls every 5s for live sessions, auto-scrolls

**Your integration:** Buddy could embed this or link to it when viewing someone's live session. It reads from the same `session-live:{handle}` KV data your GuestSessionPoller already knows about.

### 3. Session Persistence (`api/sessions.js` + Postgres)
Sessions now save permanently. Previously 30min KV TTL — now auto-saves to Postgres when session stops (if >3 turns):
- Save / list / get / fork sessions
- Browse by handle, project, tags
- Fork = copy turns to new session under your name
- Migration already applied to Neon

**Your integration:** vibe-check could save sessions to this API too — gives users a way to persist their conversation history on /vibe, not just locally. `POST /api/sessions` with turns array.

### 4. Live Chat (`api/watch/chat.js` + `api/watch/react.js`)
Real-time chat alongside broadcasts:
- Chat messages in KV list per room, 2hr TTL
- Emoji reactions (fire, mind-blown, lightbulb, heart, clap, laugh)
- Rate limited: 10 msgs/min chat, 30/min reactions
- Integrated into existing broadcast SSE stream

**Your integration:** Buddy's watch view could show a chat panel. Same SSE connection that delivers broadcast chunks now also delivers chat + reaction events.

### 5. Scheduled Sessions (`api/schedule.js` + Postgres)
Creators announce upcoming streams:
- Create with title, description, start time, tags
- Set reminders (KV-backed, SSE notification when live)
- Auto-links to broadcast when creator goes live (30min window)
- Populates `scheduled` array in `/api/discover` response

**Your integration:** Buddy could show "upcoming sessions" in discover view. Reminder button that calls `POST /api/schedule?action=remind`.

## API Contracts (Quick Ref)

All new endpoints follow the same pattern: `{ success: true, ...data }` on success, `{ success: false, error: "..." }` on failure.

```
GET  /api/room?list=active         → { rooms: [...] }
GET  /api/room?id=X                → { room: {...} }
POST /api/room  {action:"join"...} → { room: {...} }

GET  /api/session/replay?handle=X  → { session: { turns: [...], totalTurns, duration } }

GET  /api/sessions?handle=X        → { sessions: [...], total }
POST /api/sessions                 → { session: { id: "sess_..." } }
POST /api/sessions?action=fork     → { session: { id: "sess_...", forked_from } }

GET  /api/watch/chat?roomId=X      → { messages: [...] }
POST /api/watch/chat               → { id: "chat_..." }
POST /api/watch/react              → { counted: true }

GET  /api/schedule                  → { sessions: [...], total }
POST /api/schedule                  → { session: { id: "sched_..." } }
POST /api/schedule?action=remind   → { reminded: true }
```

## Guest Messaging — No Changes

Your `GuestSessionPoller` flow is untouched:
1. Poll `GET /api/session/guest?handle=X` every 30s
2. Get messages, inject into Claude session
3. Ack with `?ack=true` to clear queue

The only new thing: DMs sent to `@handle/claude` now also route to the guest queue (unified messaging path). So Buddy DMs to session entities end up in the same place your poller reads.

## V2 Direction

We're spinning up an independent V2 optimization agent (Codex) that focuses on:
- Schema stability and unified field naming
- Scale optimization (KV anti-patterns, SSE efficiency)
- Automated testing and contract assertions

V2 won't break V1 APIs. It optimizes underneath while we keep inventing on top. Full source-of-truth contract doc is at `V1_SOURCE_OF_TRUTH.md` in the platform repo.

## What's Next

- Deploy tonight's 5 features
- Room-aware presence (show room membership in buddy list)
- Session replay in Buddy (embed slider or native equivalent)
- Grow toward the "Friday Night Coding" scheduled event experience

Let me know what you want to integrate first or if any of these contracts need adjustment for vibe-check.

— Seth
