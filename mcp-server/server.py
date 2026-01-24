#!/usr/bin/env python3
"""
vibe-check MCP Server

Provides Claude Code tools to query local conversation history
and usage statistics.

Tools:
  vibe_stats       - Show usage statistics
  vibe_search      - Search conversation history
  vibe_tools       - Analyze tool usage patterns
  vibe_recent      - Show recent sessions
  vibe_session     - Get session information
  vibe_share       - Create shareable session link
  vibe_view        - Open local web viewer for conversations
"""

from mcp.server.fastmcp import FastMCP
from typing import Optional
import json
import webbrowser
import urllib.request
import urllib.error
from pathlib import Path
import os

from database import execute_query, find_database_path

# Create MCP server
mcp = FastMCP("vibe-check")


# =============================================================================
# TOOLS
# =============================================================================


@mcp.tool()
def vibe_stats(days: Optional[int] = None, repo: Optional[str] = None) -> str:
    """
    Query Claude Code usage statistics from the local database.

    Args:
        days: Limit to last N days (optional)
        repo: Filter to specific repository name (optional)
    """
    where_clauses = []
    params = []

    if days:
        where_clauses.append("DATE(inserted_at) >= DATE('now', ?)")
        params.append(f"-{days} days")

    if repo:
        where_clauses.append("git_remote_url LIKE ?")
        params.append(f"%{repo}%")

    where_sql = " AND ".join(where_clauses) if where_clauses else "1=1"

    try:
        # Overview stats
        overview = execute_query(
            f"""
            SELECT
                COUNT(*) as total_events,
                COUNT(DISTINCT event_session_id) as total_sessions,
                COUNT(DISTINCT DATE(inserted_at)) as days_active,
                MIN(DATE(inserted_at)) as first_use,
                MAX(DATE(inserted_at)) as last_use
            FROM conversation_events
            WHERE {where_sql}
        """,
            tuple(params),
        )

        stats = overview[0] if overview else {}

        # Event type breakdown
        event_types = execute_query(
            f"""
            SELECT
                event_type,
                COUNT(*) as count
            FROM conversation_events
            WHERE {where_sql}
            GROUP BY event_type
            ORDER BY count DESC
        """,
            tuple(params),
        )

        total = stats.get("total_events", 0)

        # Top repositories
        repos = execute_query(
            f"""
            SELECT
                CASE
                    WHEN git_remote_url IS NULL THEN '(no repo)'
                    ELSE REPLACE(
                        SUBSTR(git_remote_url, INSTR(git_remote_url, '/')+1),
                        '.git', ''
                    )
                END as repository,
                COUNT(DISTINCT event_session_id) as sessions,
                COUNT(*) as events
            FROM conversation_events
            WHERE {where_sql}
            GROUP BY git_remote_url
            ORDER BY sessions DESC
            LIMIT 10
        """,
            tuple(params),
        )

        # Daily activity (last 14 days)
        daily = execute_query(
            f"""
            SELECT
                DATE(inserted_at) as date,
                COUNT(*) as events,
                COUNT(DISTINCT event_session_id) as sessions
            FROM conversation_events
            WHERE {where_sql}
            GROUP BY DATE(inserted_at)
            ORDER BY date DESC
            LIMIT 14
        """,
            tuple(params),
        )

        # Format output
        output = "## Claude Code Usage Statistics\n\n"

        output += "### Overview\n"
        output += f"- Total events: {stats.get('total_events', 0):,}\n"
        output += f"- Sessions: {stats.get('total_sessions', 0):,}\n"
        output += f"- Days active: {stats.get('days_active', 0)}\n"
        output += f"- First use: {stats.get('first_use', 'N/A')}\n"
        output += f"- Last use: {stats.get('last_use', 'N/A')}\n\n"

        output += "### Event Types\n"
        for et in event_types[:8]:
            pct = (et["count"] / total * 100) if total > 0 else 0
            output += f"- {et['event_type'] or 'unknown'}: {et['count']:,} ({pct:.1f}%)\n"
        output += "\n"

        output += "### Top Repositories\n"
        for r in repos[:5]:
            output += f"- {r['repository']}: {r['sessions']} sessions, {r['events']} events\n"
        output += "\n"

        output += "### Recent Daily Activity\n"
        for day in daily[:7]:
            output += f"- {day['date']}: {day['events']} events, {day['sessions']} sessions\n"

        return output

    except FileNotFoundError as e:
        return str(e)
    except Exception as e:
        return f"Error querying stats: {e}"


@mcp.tool()
def vibe_search(
    query: str,
    repo: Optional[str] = None,
    days: Optional[int] = None,
    session_id: Optional[str] = None,
    limit: int = 20,
) -> str:
    """
    Search through conversation history.

    Args:
        query: Search term to find in messages
        repo: Filter to specific repository (optional)
        days: Limit to last N days (optional)
        session_id: Search within specific session (optional)
        limit: Maximum results (default: 20)
    """
    where_clauses = ["event_message LIKE ?"]
    params = [f"%{query}%"]

    if repo:
        where_clauses.append("git_remote_url LIKE ?")
        params.append(f"%{repo}%")

    if days:
        where_clauses.append("DATE(inserted_at) >= DATE('now', ?)")
        params.append(f"-{days} days")

    if session_id:
        where_clauses.append("event_session_id = ?")
        params.append(session_id)

    where_sql = " AND ".join(where_clauses)
    params.append(limit)

    try:
        results = execute_query(
            f"""
            SELECT
                event_session_id,
                event_type,
                SUBSTR(event_message, 1, 150) as message_preview,
                inserted_at,
                git_remote_url,
                file_name
            FROM conversation_events
            WHERE {where_sql}
                AND event_message IS NOT NULL
            ORDER BY inserted_at DESC
            LIMIT ?
        """,
            tuple(params),
        )

        if not results:
            return f"No results found for '{query}'.\n\nTry:\n- Broader search terms\n- Different date range\n- Checking if the monitor was running"

        output = f"## Search Results for '{query}'\n\n"
        output += f"Found {len(results)} matching messages:\n\n"

        current_session = None
        for r in results:
            if r["event_session_id"] != current_session:
                current_session = r["event_session_id"]
                repo_name = (
                    r["git_remote_url"].split("/")[-1].replace(".git", "")
                    if r["git_remote_url"]
                    else "(no repo)"
                )
                session_short = (
                    r["event_session_id"][:8] if r["event_session_id"] else "unknown"
                )
                output += f"\n### Session {session_short}... ({repo_name})\n"

            msg_type = r["event_type"] or "unknown"
            preview = r["message_preview"] or ""
            if len(preview) >= 150:
                preview += "..."
            output += f"- [{msg_type}] {preview}\n"
            output += f"  _{r['inserted_at']}_\n"

        return output

    except FileNotFoundError as e:
        return str(e)
    except Exception as e:
        return f"Error searching: {e}"


@mcp.tool()
def vibe_tools(
    days: int = 30, repo: Optional[str] = None, show_combinations: bool = False
) -> str:
    """
    Analyze Claude's tool usage patterns.

    Args:
        days: Number of days to analyze (default: 30)
        repo: Filter to specific repository (optional)
        show_combinations: Include tool combination analysis (default: False)
    """
    where_clauses = [
        "event_type = 'assistant'",
        f"DATE(inserted_at) >= DATE('now', '-{days} days')",
    ]
    params = []

    if repo:
        where_clauses.append("git_remote_url LIKE ?")
        params.append(f"%{repo}%")

    where_sql = " AND ".join(where_clauses)

    try:
        # Top tools
        tools = execute_query(
            f"""
            SELECT
                json_extract(value, '$.name') as tool_name,
                COUNT(*) as usage_count
            FROM conversation_events,
                 json_each(json_extract(event_data, '$.message.content'))
            WHERE {where_sql}
                AND json_extract(value, '$.type') = 'tool_use'
                AND json_extract(value, '$.name') IS NOT NULL
            GROUP BY tool_name
            ORDER BY usage_count DESC
        """,
            tuple(params),
        )

        output = f"## Tool Usage Analysis (Last {days} Days)\n\n"

        if not tools:
            return output + "No tool usage data found for this period."

        total_uses = sum(t["usage_count"] for t in tools)

        output += "### Most Used Tools\n"
        for t in tools[:10]:
            pct = t["usage_count"] / total_uses * 100
            bar_len = int(pct / 5)
            bar = "#" * bar_len + "." * (20 - bar_len)
            output += f"- **{t['tool_name']}**: {t['usage_count']:,} ({pct:.1f}%) [{bar}]\n"
        output += f"\n_Total tool uses: {total_uses:,}_\n\n"

        if show_combinations:
            # Tool combinations
            combos = execute_query(
                f"""
                WITH tool_sessions AS (
                    SELECT
                        event_session_id,
                        json_extract(value, '$.name') as tool_name
                    FROM conversation_events,
                         json_each(json_extract(event_data, '$.message.content'))
                    WHERE {where_sql}
                        AND json_extract(value, '$.type') = 'tool_use'
                        AND json_extract(value, '$.name') IS NOT NULL
                )
                SELECT
                    a.tool_name as tool_1,
                    b.tool_name as tool_2,
                    COUNT(DISTINCT a.event_session_id) as sessions_together
                FROM tool_sessions a
                JOIN tool_sessions b ON a.event_session_id = b.event_session_id
                WHERE a.tool_name < b.tool_name
                GROUP BY a.tool_name, b.tool_name
                ORDER BY sessions_together DESC
                LIMIT 10
            """,
                tuple(params),
            )

            output += "### Common Tool Combinations\n"
            for c in combos:
                output += f"- {c['tool_1']} + {c['tool_2']}: {c['sessions_together']} sessions\n"

        return output

    except FileNotFoundError as e:
        return str(e)
    except Exception as e:
        return f"Error analyzing tools: {e}"


@mcp.tool()
def vibe_recent(period: str = "today", limit: int = 10) -> str:
    """
    Get recent Claude Code sessions.

    Args:
        period: Time period - today, yesterday, week, or month (default: today)
        limit: Maximum sessions to show (default: 10)
    """
    date_filter = {
        "today": "DATE(inserted_at) = DATE('now')",
        "yesterday": "DATE(inserted_at) = DATE('now', '-1 day')",
        "week": "DATE(inserted_at) >= DATE('now', '-7 days')",
        "month": "DATE(inserted_at) >= DATE('now', '-30 days')",
    }.get(period, "DATE(inserted_at) = DATE('now')")

    try:
        # Get sessions with summary
        sessions = execute_query(
            f"""
            WITH session_summary AS (
                SELECT
                    event_session_id,
                    MIN(inserted_at) as session_start,
                    MAX(inserted_at) as session_end,
                    COUNT(*) as event_count,
                    COUNT(CASE WHEN event_type = 'user' THEN 1 END) as user_messages,
                    COUNT(CASE WHEN event_type = 'assistant' THEN 1 END) as assistant_messages,
                    git_remote_url,
                    event_git_branch
                FROM conversation_events
                WHERE {date_filter}
                    AND event_session_id IS NOT NULL
                GROUP BY event_session_id
            )
            SELECT
                event_session_id,
                session_start,
                session_end,
                ROUND((JULIANDAY(session_end) - JULIANDAY(session_start)) * 24 * 60, 1) as duration_minutes,
                user_messages,
                assistant_messages,
                event_count,
                git_remote_url,
                event_git_branch
            FROM session_summary
            ORDER BY session_start DESC
            LIMIT ?
        """,
            (limit,),
        )

        if not sessions:
            return f"No sessions found for {period}.\n\nThe monitor may not have been running during this period."

        # Get first user message for each session
        first_messages = {}
        for s in sessions:
            if s["event_session_id"]:
                msg = execute_query(
                    """
                    SELECT SUBSTR(event_message, 1, 100) as first_msg
                    FROM conversation_events
                    WHERE event_session_id = ?
                        AND event_type = 'user'
                        AND event_message IS NOT NULL
                    ORDER BY line_number ASC
                    LIMIT 1
                """,
                    (s["event_session_id"],),
                )
                if msg:
                    first_messages[s["event_session_id"]] = msg[0]["first_msg"]

        output = f"## Recent Work ({period.title()})\n\n"
        output += f"Found {len(sessions)} session(s):\n\n"

        for s in sessions:
            session_short = (
                s["event_session_id"][:8] if s["event_session_id"] else "unknown"
            )
            repo = (
                s["git_remote_url"].split("/")[-1].replace(".git", "")
                if s["git_remote_url"]
                else "(no repo)"
            )
            branch = s["event_git_branch"] or "unknown"
            duration = s["duration_minutes"] or 0

            output += f"### Session {session_short}...\n"
            output += f"- **Repository**: {repo}\n"
            output += f"- **Branch**: {branch}\n"
            output += f"- **Duration**: {duration:.0f} minutes\n"
            output += f"- **Activity**: {s['user_messages']} user, {s['assistant_messages']} assistant messages\n"
            output += f"- **Started**: {s['session_start']}\n"

            if s["event_session_id"] in first_messages:
                msg = first_messages[s["event_session_id"]]
                if len(msg) >= 100:
                    msg += "..."
                output += f"- **First message**: _{msg}_\n"

            output += "\n"

        return output

    except FileNotFoundError as e:
        return str(e)
    except Exception as e:
        return f"Error getting sessions: {e}"


@mcp.tool()
def vibe_session(session_id: Optional[str] = None) -> str:
    """
    Get information about a session.

    Args:
        session_id: Session ID to look up (optional - uses most recent if not provided)
    """
    try:
        if session_id:
            # Look up specific session
            results = execute_query(
                """
                SELECT
                    event_session_id,
                    MIN(inserted_at) as session_start,
                    MAX(inserted_at) as session_end,
                    COUNT(*) as total_events,
                    COUNT(CASE WHEN event_type = 'user' THEN 1 END) as user_messages,
                    COUNT(CASE WHEN event_type = 'assistant' THEN 1 END) as assistant_messages,
                    git_remote_url,
                    event_git_branch,
                    file_name
                FROM conversation_events
                WHERE event_session_id = ?
                GROUP BY event_session_id
            """,
                (session_id,),
            )
        else:
            # Get most recent session
            results = execute_query(
                """
                SELECT
                    event_session_id,
                    MIN(inserted_at) as session_start,
                    MAX(inserted_at) as session_end,
                    COUNT(*) as total_events,
                    COUNT(CASE WHEN event_type = 'user' THEN 1 END) as user_messages,
                    COUNT(CASE WHEN event_type = 'assistant' THEN 1 END) as assistant_messages,
                    git_remote_url,
                    event_git_branch,
                    file_name
                FROM conversation_events
                WHERE event_session_id IS NOT NULL
                GROUP BY event_session_id
                ORDER BY MAX(inserted_at) DESC
                LIMIT 1
            """
            )

        if not results:
            return "No session found." if session_id else "No sessions in database."

        s = results[0]

        output = "## Session Information\n\n"
        output += f"- **Session ID**: {s['event_session_id']}\n"
        output += f"- **Log File**: {s['file_name']}\n"
        output += f"- **Started**: {s['session_start']}\n"
        output += f"- **Last Activity**: {s['session_end']}\n"
        output += f"- **Total Events**: {s['total_events']}\n"
        output += f"- **Messages**: {s['user_messages']} user, {s['assistant_messages']} assistant\n"

        if s["git_remote_url"]:
            repo = s["git_remote_url"].split("/")[-1].replace(".git", "")
            output += f"- **Repository**: {repo}\n"
        if s["event_git_branch"]:
            output += f"- **Branch**: {s['event_git_branch']}\n"

        return output

    except FileNotFoundError as e:
        return str(e)
    except Exception as e:
        return f"Error getting session: {e}"


@mcp.tool()
def vibe_share(
    session_id: str,
    title: Optional[str] = None,
    slug: Optional[str] = None,
    wait_for_sync: bool = True,
) -> str:
    """
    Create a shareable link for a session.

    Args:
        session_id: The session ID to share
        title: Optional title for the share (default: auto-generated)
        slug: Optional custom URL slug (default: auto-generated)
        wait_for_sync: If true, retry if session not synced yet (default: true)
    """
    import time
    # Find config file
    config_path = os.environ.get("VIBE_CHECK_CONFIG")
    if config_path:
        config_paths = [Path(config_path)]
    else:
        config_paths = [
            Path.home() / ".vibe-check" / "config.json",
            Path("/opt/homebrew/var/vibe-check/config.json"),
        ]

    config = None
    for path in config_paths:
        if path.exists():
            try:
                with open(path) as f:
                    config = json.load(f)
                break
            except (json.JSONDecodeError, IOError):
                continue

    if not config:
        return (
            "Could not find vibe-check configuration.\n\n"
            "Sharing requires remote API to be configured.\n"
            "Edit ~/.vibe-check/config.json and set api.enabled = true"
        )

    api_config = config.get("api", {})

    if not api_config.get("enabled", False):
        return (
            "Remote API is disabled in your configuration.\n\n"
            "To enable sharing, edit ~/.vibe-check/config.json and set:\n"
            '  "api": { "enabled": true, "url": "...", "api_key": "..." }'
        )

    api_url = api_config.get("url", "").rstrip("/")
    api_key = api_config.get("api_key", "")

    if not api_url or not api_key:
        return "API URL or API key missing in configuration."

    # Create share via API
    # Config URL may or may not include /api suffix
    if api_url.endswith("/api"):
        share_endpoint = f"{api_url}/shares"
    else:
        share_endpoint = f"{api_url}/api/shares"

    payload = {
        "scope_type": "session",
        "scope_session_id": session_id,
        "visibility": "public",
    }
    if title:
        payload["title"] = title
    if slug:
        payload["slug"] = slug

    # Retry settings for sync delay
    max_retries = 3 if wait_for_sync else 1
    retry_delay = 3  # seconds between retries

    for attempt in range(max_retries):
        try:
            data = json.dumps(payload).encode("utf-8")
            req = urllib.request.Request(
                share_endpoint,
                data=data,
                headers={
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                    "X-API-Key": api_key,
                    "User-Agent": "vibe-check-mcp/1.0",
                },
                method="POST",
            )

            with urllib.request.urlopen(req, timeout=10) as response:
                result = json.loads(response.read().decode("utf-8"))

            if result.get("status") == "ok" or result.get("share_url"):
                share_url = result.get("share_url", f"{api_url}/s/{result.get('share_token', 'unknown')}")
                output = "## Session Shared Successfully\n\n"
                output += f"**Share URL**: {share_url}\n\n"
                output += "Anyone with this link can view the session."
                return output
            else:
                return f"Failed to create share: {result.get('error', result.get('message', 'Unknown error'))}"

        except urllib.error.HTTPError as e:
            body = ""
            try:
                body = e.read().decode("utf-8")
            except:
                pass

            # Check if it's a "not synced yet" error (403 with ownership message)
            if e.code == 403 and "do not own" in body and attempt < max_retries - 1:
                # Session not synced yet, wait and retry
                time.sleep(retry_delay)
                continue

            return f"API error: {e.code} {e.reason}\n{body}"
        except urllib.error.URLError as e:
            return f"Network error: {e.reason}"
        except Exception as e:
            return f"Error creating share: {e}"

    return "Session not synced to server yet. The vibe-check daemon may need more time to upload. Try again in a few seconds."


@mcp.tool()
def vibe_open_stats() -> str:
    """Open the web-based vibe-check stats page in the browser."""
    # Find config file
    config_paths = [
        Path.home() / ".vibe-check" / "config.json",
        Path("/opt/homebrew/var/vibe-check/config.json"),
    ]

    config = None
    for path in config_paths:
        if path.exists():
            try:
                with open(path) as f:
                    config = json.load(f)
                break
            except (json.JSONDecodeError, IOError):
                continue

    if not config:
        return (
            "Could not find vibe-check configuration.\n\n"
            "Use vibe_stats tool to view local statistics instead."
        )

    api_config = config.get("api", {})
    sqlite_config = config.get("sqlite", {})

    if not api_config.get("enabled", False):
        return (
            "Remote stats are disabled in your configuration.\n\n"
            "You're currently only saving conversations locally to SQLite.\n"
            "Use vibe_stats tool to view local statistics."
        )

    url = api_config.get("url", "")
    username = sqlite_config.get("user_name", "")

    if not url or not username:
        return "Remote stats enabled but URL or username is missing in config."

    stats_url = f"{url}/stats.php?user={username}"

    try:
        webbrowser.open(stats_url)
        return f"Opened stats page in your browser:\n{stats_url}"
    except Exception as e:
        return f"Could not open browser. Visit manually:\n{stats_url}"


@mcp.tool()
def vibe_view(session_id: Optional[str] = None, message_uuid: Optional[str] = None) -> str:
    """
    Open the local web viewer for conversations.

    Opens a browser to view conversations stored in the local SQLite database.
    Requires the web server to be running (python mcp-server/web_server.py).

    Args:
        session_id: Session ID to view (optional - opens session list if not provided)
        message_uuid: Specific message UUID to highlight and scroll to (optional)
    """
    import socket

    port = int(os.environ.get('VIBE_CHECK_WEB_PORT', 8765))

    # Check if server is running
    def is_server_running():
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            return s.connect_ex(('127.0.0.1', port)) == 0

    if not is_server_running():
        return (
            f"Local web server is not running on port {port}.\n\n"
            "Start it with:\n"
            "```bash\n"
            "python ~/.vibe-check/mcp-server/web_server.py\n"
            "```\n\n"
            "Or if installed via git:\n"
            "```bash\n"
            "cd ~/Developer/vibe-check && python mcp-server/web_server.py\n"
            "```"
        )

    # Build URL
    if session_id:
        url = f"http://localhost:{port}/session/{session_id}"
        if message_uuid:
            url += f"?msg={message_uuid}"
    else:
        url = f"http://localhost:{port}/"

    try:
        webbrowser.open(url)
        if session_id:
            if message_uuid:
                return f"Opened session {session_id[:8]}... at message {message_uuid[:8]}... in browser:\n{url}"
            return f"Opened session {session_id[:8]}... in browser:\n{url}"
        return f"Opened session list in browser:\n{url}"
    except Exception as e:
        return f"Could not open browser. Visit manually:\n{url}"


# =============================================================================
# MAIN
# =============================================================================

if __name__ == "__main__":
    mcp.run()
