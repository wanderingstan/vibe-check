#!/usr/bin/env python3
"""
vibe-check Local Web Server

A lightweight HTTP server for viewing conversations stored in the local SQLite database.

Usage:
    python web_server.py
    # Serves at http://localhost:8765/

Routes:
    /                           List recent sessions
    /session/{session_id}       View full conversation
    /session/{session_id}?msg={uuid}  Jump to specific message

Environment:
    VIBE_CHECK_WEB_PORT         Port to serve on (default: 8765)
"""

import os
import re
import html
import socket
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from datetime import datetime

from database import execute_query, find_database_path

DEFAULT_PORT = 8765

# Try to import markdown for rich rendering, fall back to plain text
try:
    import markdown
    HAS_MARKDOWN = True
except ImportError:
    HAS_MARKDOWN = False


# =============================================================================
# HTML TEMPLATES
# =============================================================================

BASE_STYLE = """
<style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        background: #111827;
        color: #d1d5db;
        line-height: 1.6;
        padding: 2rem;
        max-width: 1000px;
        margin: 0 auto;
    }
    a { color: #a78bfa; text-decoration: none; }
    a:hover { text-decoration: underline; }
    h1 { color: #fff; margin-bottom: 1.5rem; }
    h2 { color: #fff; margin: 1.5rem 0 1rem 0; font-size: 1.25rem; }
    .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 2rem; }
    .back-link { font-size: 0.9rem; }

    /* Session list */
    .session-card {
        background: #1f2937;
        border: 1px solid #374151;
        border-radius: 0.5rem;
        padding: 1rem;
        margin-bottom: 1rem;
    }
    .session-card:hover { border-color: #4b5563; }
    .session-meta { display: flex; gap: 1rem; flex-wrap: wrap; font-size: 0.85rem; color: #9ca3af; margin-top: 0.5rem; }
    .session-meta span { background: #374151; padding: 0.25rem 0.5rem; border-radius: 0.25rem; }
    .first-message { color: #9ca3af; font-style: italic; margin-top: 0.5rem; font-size: 0.9rem; }

    /* Message cards */
    .message {
        border-radius: 0.5rem;
        padding: 1rem;
        margin-bottom: 0.75rem;
        scroll-margin-top: 1rem;
    }
    .message-user {
        background: #1f2937;
        border: 1px solid #374151;
    }
    .message-assistant {
        background: transparent;
        border: 1px solid #374151;
        border-left: 3px solid #9333ea;
    }
    .message-tool_use {
        background: #1f2937;
        border: 1px solid #374151;
        border-left: 3px solid #ca8a04;
    }
    .message-tool_result {
        background: #1f2937;
        border: 1px solid #374151;
        border-left: 3px solid #16a34a;
    }
    .message-highlighted {
        border: 2px solid #fbbf24 !important;
        box-shadow: 0 0 20px rgba(251, 191, 36, 0.3);
    }
    .message-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.5rem; }
    .badge {
        padding: 0.25rem 0.5rem;
        border-radius: 0.25rem;
        font-size: 0.75rem;
        font-weight: 500;
        color: #fff;
    }
    .badge-user { background: #2563eb; }
    .badge-assistant { background: #9333ea; }
    .badge-tool_use { background: #ca8a04; }
    .badge-tool_result { background: #16a34a; }
    .badge-unknown { background: #4b5563; }
    .timestamp { font-size: 0.8rem; color: #6b7280; }
    .timestamp-link { font-size: 0.8rem; color: #6b7280; text-decoration: none; }
    .timestamp-link:hover { color: #a78bfa; text-decoration: underline; }
    .message-meta { font-size: 0.75rem; color: #6b7280; display: flex; gap: 0.5rem; }
    .message-meta span { background: #374151; padding: 0.125rem 0.375rem; border-radius: 0.25rem; }
    .message-content {
        color: #d1d5db;
        white-space: pre-wrap;
        word-wrap: break-word;
        font-size: 0.9rem;
    }
    .message-user .message-content { font-family: monospace; }

    /* IDE notifications */
    .ide-notification {
        color: #6b7280;
        font-style: italic;
        font-size: 0.85rem;
        background: #1f2937;
        padding: 0.5rem;
        border-radius: 0.25rem;
        margin: 0.5rem 0;
    }

    /* Markdown content */
    .markdown-content { font-family: inherit; }
    .markdown-content pre {
        background: #1e293b;
        padding: 1rem;
        border-radius: 0.375rem;
        overflow-x: auto;
        margin: 0.5rem 0;
    }
    .markdown-content code {
        background: #374151;
        padding: 0.125rem 0.25rem;
        border-radius: 0.25rem;
        font-size: 0.85em;
    }
    .markdown-content pre code { background: transparent; padding: 0; }
    .markdown-content p { margin: 0.5rem 0; }
    .markdown-content ul, .markdown-content ol { margin: 0.5rem 0; padding-left: 1.5rem; }

    /* Syntax highlighting (highlight.js) */
    .hljs { background: #1e293b !important; }

    /* Empty state */
    .empty-state { text-align: center; padding: 3rem; color: #6b7280; }

    /* Session header info */
    .session-info {
        background: #1f2937;
        border: 1px solid #374151;
        border-radius: 0.5rem;
        padding: 1rem;
        margin-bottom: 1.5rem;
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
        gap: 0.5rem;
    }
    .session-info-item { font-size: 0.85rem; }
    .session-info-item strong { color: #9ca3af; }
</style>
"""

HIGHLIGHT_JS_CDN = """
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
<script>hljs.highlightAll();</script>
"""


def html_page(title: str, content: str, include_highlight: bool = False) -> str:
    """Wrap content in a full HTML page."""
    highlight = HIGHLIGHT_JS_CDN if include_highlight else ""
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{html.escape(title)} - vibe-check</title>
    {BASE_STYLE}
    {highlight}
</head>
<body>
    {content}
</body>
</html>"""


# =============================================================================
# MESSAGE PARSING
# =============================================================================

# Regex for IDE notification tags
IDE_TAG_PATTERN = re.compile(
    r'<(ide_opened_file|ide_selection|ide_diagnostics|system-reminder)>([\s\S]*?)</\1>',
    re.IGNORECASE
)


def parse_message_segments(message: str) -> list:
    """Parse message into text and IDE notification segments."""
    segments = []
    last_index = 0

    for match in IDE_TAG_PATTERN.finditer(message):
        # Text before this tag
        if match.start() > last_index:
            text = message[last_index:match.start()].strip()
            if text:
                segments.append({'type': 'text', 'content': text})

        # The IDE notification (collapsed by default)
        segments.append({
            'type': 'ide-notification',
            'tag': match.group(1),
            'content': match.group(2).strip()
        })
        last_index = match.end()

    # Remaining text
    if last_index < len(message):
        text = message[last_index:].strip()
        if text:
            segments.append({'type': 'text', 'content': text})

    return segments if segments else [{'type': 'text', 'content': message}]


def render_markdown(text: str) -> str:
    """Render markdown to HTML if library available."""
    if HAS_MARKDOWN:
        return markdown.markdown(
            text,
            extensions=['fenced_code', 'tables', 'nl2br']
        )
    return f"<pre>{html.escape(text)}</pre>"


def render_message_content(message: str, is_assistant: bool = False) -> str:
    """Render message content with IDE tag handling."""
    if not message:
        return '<span class="text-gray-500">No content</span>'

    segments = parse_message_segments(message)
    parts = []

    for seg in segments:
        if seg['type'] == 'ide-notification':
            # Show collapsed IDE notifications
            preview = seg['content'][:100] + '...' if len(seg['content']) > 100 else seg['content']
            parts.append(f'<div class="ide-notification">[{seg["tag"]}] {html.escape(preview)}</div>')
        else:
            content = seg['content']
            if is_assistant:
                parts.append(f'<div class="markdown-content">{render_markdown(content)}</div>')
            else:
                parts.append(html.escape(content))

    return ''.join(parts)


# =============================================================================
# ROUTE HANDLERS
# =============================================================================

def render_index() -> str:
    """Render the session list page."""
    try:
        sessions = execute_query("""
            WITH session_summary AS (
                SELECT
                    event_session_id,
                    MIN(event_timestamp) as session_start,
                    MAX(event_timestamp) as session_end,
                    COUNT(*) as event_count,
                    COUNT(CASE WHEN event_type = 'user' THEN 1 END) as user_messages,
                    COUNT(CASE WHEN event_type = 'assistant' THEN 1 END) as assistant_messages,
                    git_remote_url,
                    event_git_branch
                FROM conversation_events
                WHERE event_session_id IS NOT NULL
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
            LIMIT 50
        """)
    except Exception as e:
        return html_page("Error", f'<div class="empty-state">Error loading sessions: {html.escape(str(e))}</div>')

    if not sessions:
        return html_page("Sessions", '<div class="empty-state">No sessions found.<br>Is vibe-check monitor running?</div>')

    # Get first message for each session
    first_messages = {}
    for s in sessions:
        if s['event_session_id']:
            msg = execute_query("""
                SELECT SUBSTR(event_message, 1, 150) as first_msg
                FROM conversation_events
                WHERE event_session_id = ?
                    AND event_type = 'user'
                    AND event_message IS NOT NULL
                ORDER BY line_number ASC
                LIMIT 1
            """, (s['event_session_id'],))
            if msg:
                first_messages[s['event_session_id']] = msg[0]['first_msg']

    # Build session cards
    cards = []
    for s in sessions:
        session_id = s['event_session_id']
        session_short = session_id[:8] if session_id else 'unknown'
        repo = s['git_remote_url'].split('/')[-1].replace('.git', '') if s['git_remote_url'] else '(no repo)'
        branch = s['event_git_branch'] or ''
        duration = s['duration_minutes'] or 0

        first_msg = first_messages.get(session_id, '')
        if len(first_msg) >= 150:
            first_msg += '...'

        cards.append(f'''
        <div class="session-card">
            <a href="/session/{session_id}"><strong>Session {session_short}...</strong></a>
            <div class="session-meta">
                <span>{repo}</span>
                {f'<span>{html.escape(branch)}</span>' if branch else ''}
                <span>{duration:.0f} min</span>
                <span>{s["user_messages"]} user / {s["assistant_messages"]} assistant</span>
                <span>{s["session_start"]}</span>
            </div>
            {f'<div class="first-message">{html.escape(first_msg)}</div>' if first_msg else ''}
        </div>
        ''')

    content = f'''
    <h1>vibe-check Sessions</h1>
    <p style="color: #6b7280; margin-bottom: 1.5rem;">Showing {len(sessions)} recent sessions</p>
    {''.join(cards)}
    '''

    return html_page("Sessions", content)


def resolve_session_id(session_id: str) -> str:
    """Resolve a short session ID to its full form."""
    if len(session_id) == 36:  # Already full UUID
        return session_id
    # Search by prefix
    result = execute_query("""
        SELECT DISTINCT event_session_id
        FROM conversation_events
        WHERE event_session_id LIKE ?
        LIMIT 1
    """, (f"{session_id}%",))
    return result[0]['event_session_id'] if result else session_id


def resolve_message_uuid(message_uuid: str, session_id: str = None) -> str:
    """Resolve a short message UUID to its full form."""
    if len(message_uuid) == 36:  # Already full UUID
        return message_uuid
    # Search by prefix, optionally within a session
    if session_id:
        result = execute_query("""
            SELECT event_uuid
            FROM conversation_events
            WHERE event_uuid LIKE ? AND event_session_id = ?
            LIMIT 1
        """, (f"{message_uuid}%", session_id))
    else:
        result = execute_query("""
            SELECT event_uuid
            FROM conversation_events
            WHERE event_uuid LIKE ?
            LIMIT 1
        """, (f"{message_uuid}%",))
    return result[0]['event_uuid'] if result else message_uuid


def render_session(session_id: str, highlight_msg: str = None) -> str:
    """Render a full conversation session."""
    try:
        # Resolve short session ID to full
        full_session_id = resolve_session_id(session_id)

        # Resolve short message UUID if provided
        full_highlight_msg = None
        if highlight_msg:
            full_highlight_msg = resolve_message_uuid(highlight_msg, full_session_id)

        # Get session info
        session_info = execute_query("""
            SELECT
                event_session_id,
                MIN(event_timestamp) as session_start,
                MAX(event_timestamp) as session_end,
                COUNT(*) as total_events,
                COUNT(CASE WHEN event_type = 'user' THEN 1 END) as user_messages,
                COUNT(CASE WHEN event_type = 'assistant' THEN 1 END) as assistant_messages,
                git_remote_url,
                event_git_branch
            FROM conversation_events
            WHERE event_session_id = ?
        """, (full_session_id,))

        if not session_info or not session_info[0]['total_events']:
            return html_page("Not Found", f'<div class="empty-state">Session {html.escape(session_id[:8])}... not found</div>')

        info = session_info[0]
        # Use the resolved full session ID for display
        display_session_id = info['event_session_id'] or full_session_id

        # Get all events with messages only
        events = execute_query("""
            SELECT
                event_uuid,
                event_type,
                event_message,
                event_timestamp,
                inserted_at,
                line_number
            FROM conversation_events
            WHERE event_session_id = ?
                AND event_message IS NOT NULL
                AND event_message != ''
            ORDER BY line_number ASC
        """, (full_session_id,))

    except Exception as e:
        return html_page("Error", f'<div class="empty-state">Error: {html.escape(str(e))}</div>')

    # Build session header
    repo = info['git_remote_url'].split('/')[-1].replace('.git', '') if info['git_remote_url'] else '(no repo)'
    branch = info['event_git_branch'] or 'unknown'

    header = f'''
    <div class="header">
        <h1>Session {display_session_id[:8]}...</h1>
        <a href="/" class="back-link">&larr; All Sessions</a>
    </div>
    <div class="session-info">
        <div class="session-info-item"><strong>Repository:</strong> {html.escape(repo)}</div>
        <div class="session-info-item"><strong>Branch:</strong> {html.escape(branch)}</div>
        <div class="session-info-item"><strong>Started:</strong> {info["session_start"]}</div>
        <div class="session-info-item"><strong>Messages:</strong> {info["user_messages"]} user, {info["assistant_messages"]} assistant</div>
    </div>
    '''

    # Build message cards
    messages = []
    for e in events:
        event_type = e['event_type'] or 'unknown'
        event_uuid = e['event_uuid'] or ''
        is_assistant = event_type == 'assistant'
        is_highlighted = full_highlight_msg and event_uuid == full_highlight_msg

        badge_class = f"badge-{event_type}" if event_type in ('user', 'assistant', 'tool_use', 'tool_result') else 'badge-unknown'
        highlight_class = ' message-highlighted' if is_highlighted else ''

        timestamp = e['event_timestamp'] or e['inserted_at'] or ''
        timestamp_display = timestamp
        if timestamp:
            try:
                dt = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
                timestamp_display = dt.strftime('%b %d, %Y %I:%M %p')
            except:
                pass

        content = render_message_content(e['event_message'], is_assistant=is_assistant)

        msg_id = f'msg-{event_uuid}' if event_uuid else f'msg-{e["line_number"]}'

        # Make timestamp a deep link if event has a UUID
        if event_uuid:
            timestamp_html = f'<a href="/session/{display_session_id[:8]}?msg={event_uuid[:8]}" class="timestamp-link">{html.escape(timestamp_display)}</a>'
        else:
            timestamp_html = f'<span class="timestamp">{html.escape(timestamp_display)}</span>'

        # Only show badge for non-assistant messages (matching remote server behavior)
        badge_html = '' if is_assistant else f'<span class="badge {badge_class}">{event_type}</span>'

        messages.append(f'''
        <div id="{msg_id}" class="message message-{event_type}{highlight_class}">
            <div class="message-header">
                {badge_html}
                {timestamp_html}
            </div>
            <div class="message-content">{content}</div>
        </div>
        ''')

    # Add scroll-to script if highlighting a message
    scroll_script = ''
    if full_highlight_msg:
        scroll_script = f'''
        <script>
            document.addEventListener('DOMContentLoaded', function() {{
                const target = document.getElementById('msg-{full_highlight_msg}');
                if (target) {{
                    target.scrollIntoView({{ behavior: 'smooth', block: 'center' }});
                }}
            }});
        </script>
        '''

    content = header + ''.join(messages) + scroll_script

    return html_page(f"Session {session_id[:8]}", content, include_highlight=True)


# =============================================================================
# HTTP SERVER
# =============================================================================

class VibeCheckHandler(BaseHTTPRequestHandler):
    """HTTP request handler for vibe-check web server."""

    def log_message(self, format, *args):
        """Custom logging."""
        print(f"[{self.log_date_time_string()}] {args[0]}")

    def send_html(self, content: str, status: int = 200):
        """Send HTML response."""
        self.send_response(status)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(content.encode('utf-8'))

    def do_GET(self):
        """Handle GET requests."""
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        try:
            # Route: /
            if path == '/' or path == '':
                self.send_html(render_index())

            # Route: /session/{session_id}
            elif path.startswith('/session/'):
                session_id = path.split('/session/')[-1].strip('/')
                if not session_id:
                    self.send_html(render_index())
                    return

                highlight_msg = query.get('msg', [None])[0]
                self.send_html(render_session(session_id, highlight_msg))

            # 404 for everything else
            else:
                self.send_html(
                    html_page("Not Found", '<div class="empty-state">Page not found</div>'),
                    status=404
                )

        except Exception as e:
            self.send_html(
                html_page("Error", f'<div class="empty-state">Server error: {html.escape(str(e))}</div>'),
                status=500
            )


def is_port_in_use(port: int) -> bool:
    """Check if a port is already in use."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(('127.0.0.1', port)) == 0


def main():
    """Start the web server."""
    port = int(os.environ.get('VIBE_CHECK_WEB_PORT', DEFAULT_PORT))

    # Check database exists
    db_path = find_database_path()
    if not db_path:
        print("Error: Could not find vibe-check database.")
        print("Is vibe-check monitor running?")
        print("\nChecked locations:")
        print("  - ~/.vibe-check/vibe_check.db")
        print("  - /opt/homebrew/var/vibe-check/vibe_check.db")
        return 1

    print(f"Using database: {db_path}")

    if is_port_in_use(port):
        print(f"Error: Port {port} is already in use.")
        print(f"Set VIBE_CHECK_WEB_PORT environment variable to use a different port.")
        return 1

    server = HTTPServer(('127.0.0.1', port), VibeCheckHandler)
    print(f"\nvibe-check web server running at http://localhost:{port}/")
    print("Press Ctrl+C to stop.\n")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()

    return 0


if __name__ == '__main__':
    exit(main())
