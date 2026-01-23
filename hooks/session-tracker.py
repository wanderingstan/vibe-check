#!/usr/bin/env python3
"""
vibe-check UserPromptSubmit Hook

Injects session context into every prompt automatically.
This replaces the VIBE_SESSION_MARKER hack by receiving session_id
directly from Claude Code.

Input (via stdin JSON):
{
    "session_id": "abc123...",
    "prompt": "user's message",
    "cwd": "/current/directory",
    "transcript_path": "/path/to/transcript.jsonl",
    ...
}

Output:
Text printed to stdout is added to Claude's context.
"""

import json
import os
import sys
from pathlib import Path


def get_git_info(cwd: str) -> dict:
    """Get git branch and repo name from the working directory."""
    import subprocess

    result = {"repo": None, "branch": None}
    try:
        # Get current branch
        branch = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=2,
        )
        if branch.returncode == 0:
            result["branch"] = branch.stdout.strip()

        # Get repo name from remote or directory
        remote = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=2,
        )
        if remote.returncode == 0:
            url = remote.stdout.strip()
            # Extract repo name from URL (handles both HTTPS and SSH)
            if "/" in url:
                result["repo"] = url.split("/")[-1].replace(".git", "")
        else:
            # Fall back to directory name
            result["repo"] = Path(cwd).name

    except Exception:
        pass

    return result


def main():
    # Read hook input from stdin
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)  # Silent exit on invalid input

    session_id = input_data.get("session_id", "unknown")
    cwd = input_data.get("cwd", os.getcwd())

    # Get git context
    git_info = get_git_info(cwd)

    # Build context line
    parts = [f"Session: {session_id}"]
    if git_info.get("repo"):
        parts.append(f"Repo: {git_info['repo']}")
    if git_info.get("branch"):
        parts.append(f"Branch: {git_info['branch']}")

    context = "[vibe-check] " + " | ".join(parts)

    # Output context - this gets added to Claude's context automatically
    print(context)

    sys.exit(0)


if __name__ == "__main__":
    main()
