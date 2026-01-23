#!/bin/bash
# vibe-check Plugin Installation Script
#
# This script sets up the vibe-check MCP server for Claude Code.
# It creates a virtual environment, installs dependencies, and registers
# the MCP server in ~/.claude.json.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIBE_CHECK_DIR="$(dirname "$SCRIPT_DIR")"
MCP_SERVER_DIR="$VIBE_CHECK_DIR/mcp-server"
VENV_DIR="$MCP_SERVER_DIR/.venv"
CLAUDE_JSON="$HOME/.claude.json"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         vibe-check Plugin Installation                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Check if vibe-check daemon is installed
if [ ! -f "$HOME/.vibe-check/vibe_check.db" ]; then
    echo "⚠️  Warning: vibe-check database not found at ~/.vibe-check/vibe_check.db"
    echo "   The MCP tools require the vibe-check daemon to be running."
    echo "   Install it with: ./scripts/install.sh"
    echo ""
fi

# Step 1: Create virtual environment and install dependencies
echo "📦 Setting up Python virtual environment..."
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    echo "   Created virtual environment at $VENV_DIR"
else
    echo "   Virtual environment already exists"
fi

echo "📥 Installing MCP dependencies..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet mcp

# Verify the server can be imported
echo "🔍 Verifying MCP server..."
cd "$MCP_SERVER_DIR"
"$VENV_DIR/bin/python" -c "import server; print('   Server imported successfully')" || {
    echo "❌ Failed to import server. Check for errors."
    exit 1
}

# Step 2: Register MCP server in ~/.claude.json
echo ""
echo "⚙️  Registering MCP server in Claude Code..."

if [ ! -f "$CLAUDE_JSON" ]; then
    echo "   Creating $CLAUDE_JSON..."
    echo '{"mcpServers":{}}' > "$CLAUDE_JSON"
fi

# Check if jq is available
if command -v jq &> /dev/null; then
    # Use jq to add/update the MCP server config
    TMP_FILE=$(mktemp)

    jq --arg venv "$VENV_DIR" --arg dir "$VIBE_CHECK_DIR" --arg home "$HOME" \
       '.mcpServers["vibe-check"] = {
          "type": "stdio",
          "command": ($venv + "/bin/python"),
          "args": [($dir + "/mcp-server/server.py")],
          "env": {
            "VIBE_CHECK_DB": ($home + "/.vibe-check/vibe_check.db"),
            "VIBE_CHECK_CONFIG": ($home + "/.vibe-check/config.json")
          }
        }' "$CLAUDE_JSON" > "$TMP_FILE"

    mv "$TMP_FILE" "$CLAUDE_JSON"
    echo "   ✓ Added vibe-check MCP server to ~/.claude.json"
else
    echo "   ⚠️  jq not installed. Please add the following to ~/.claude.json manually:"
    echo ""
    echo '   "mcpServers": {'
    echo '     "vibe-check": {'
    echo '       "type": "stdio",'
    echo "       \"command\": \"$VENV_DIR/bin/python\","
    echo "       \"args\": [\"$MCP_SERVER_DIR/server.py\"],"
    echo '       "env": {'
    echo "         \"VIBE_CHECK_DB\": \"$HOME/.vibe-check/vibe_check.db\","
    echo "         \"VIBE_CHECK_CONFIG\": \"$HOME/.vibe-check/config.json\""
    echo '       }'
    echo '     }'
    echo '   }'
    echo ""
fi

# Step 3: Ask about skills installation
SKILLS_DIR="$VIBE_CHECK_DIR/skills"
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"

echo ""
echo "📚 Skills Installation"
echo "   vibe-check includes Claude Code skills for natural language queries."
echo "   These are optional if you prefer using MCP tools directly."
echo ""

read -p "   Install skills to ~/.claude/skills/? [Y/n] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    if [ -d "$SKILLS_DIR" ]; then
        mkdir -p "$CLAUDE_SKILLS_DIR"

        # Install each skill directory
        for skill_dir in "$SKILLS_DIR"/*/; do
            if [ -d "$skill_dir" ]; then
                skill_name=$(basename "$skill_dir")
                target_dir="$CLAUDE_SKILLS_DIR/$skill_name"

                if [ -d "$target_dir" ]; then
                    echo "   Updating: $skill_name"
                    rm -rf "$target_dir"
                else
                    echo "   Installing: $skill_name"
                fi

                cp -r "$skill_dir" "$target_dir"
            fi
        done

        echo "   ✓ Skills installed to $CLAUDE_SKILLS_DIR"
    else
        echo "   ⚠️  Skills directory not found at $SKILLS_DIR. Skipping."
    fi
else
    echo "   Skipped skills installation."
fi

# Done!
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Installation Complete!                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "🎉 vibe-check plugin is now installed!"
echo ""
echo "Available MCP tools:"
echo "  • vibe_stats     - Usage statistics"
echo "  • vibe_search    - Search conversation history"
echo "  • vibe_tools     - Tool usage analysis"
echo "  • vibe_recent    - Recent sessions"
echo "  • vibe_session   - Session information"
echo "  • vibe_share     - Create shareable links"
echo ""
echo "To use: Restart Claude Code or start a new session."
echo ""
echo "Test with: \"claude stats\" or use tools directly."
