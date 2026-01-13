# Claude Code Skills for Vibe Check

This directory contains Claude Code skills that enable Claude to query your local conversation database and answer questions about your usage.

## What are Claude Code Skills?

Claude Code skills are markdown files placed in `~/.claude/skills/` that provide Claude with specialized knowledge and capabilities. When you use certain trigger phrases, Claude reads these skill files and follows their instructions to query your data and format responses.

## Installation

### Quick Install

From the vibe-check directory, run:

```bash
./claude-skills/install-skills.sh
```

This will copy all 4 skills to `~/.claude/skills/`.

### Manual Install

If you prefer to install manually:

```bash
mkdir -p ~/.claude/skills
cp claude-skills/*.md ~/.claude/skills/
```

## Available Skills

### 1. [claude-stats.md](claude-stats.md)
**Triggers:** "claude stats", "usage stats", "my claude usage"

Shows comprehensive usage statistics:
- Total events, sessions, and days active
- Event type breakdown
- Daily activity trends
- Repository usage patterns

### 2. [search-conversations.md](search-conversations.md)
**Triggers:** "search my conversations", "find when I talked about X"

Search capabilities:
- Full-text search across all messages
- Filter by date range
- Filter by repository
- Find sessions by topic

### 3. [analyze-tools.md](analyze-tools.md)
**Triggers:** "what tools do I use most", "tool usage stats"

Analyzes Claude's tool usage:
- Most frequently used tools
- Tool usage trends over time
- Tool usage by repository
- Common tool combinations

### 4. [recent-work.md](recent-work.md)
**Triggers:** "what have I been working on", "recent work", "what did I do today"

Shows recent activity:
- Today's sessions with context
- This week's summary
- Session duration and message counts
- Repository and branch information

## How It Works

1. **Installation:** Skills are copied to `~/.claude/skills/`
2. **Recognition:** When you use a trigger phrase, Claude detects it
3. **Execution:** Claude reads the skill file for query instructions
4. **Response:** Claude executes SQLite queries on your local database
5. **Formatting:** Results are formatted and presented

## Database Requirements

These skills require:
- ✅ Vibe-check monitor running and collecting data
- ✅ Local SQLite database at `~/Developer/vibe-check/vibe_check.db` or `~/.vibe-check/vibe_check.db`
- ✅ SQLite3 command-line tool (pre-installed on macOS/Linux)

All queries use read-only mode to avoid database locks.

## Usage Examples

```
You: "claude stats"
Claude: [Shows comprehensive usage statistics]

You: "what did I work on yesterday?"
Claude: [Shows yesterday's sessions with context]

You: "search my conversations for authentication"
Claude: [Finds all conversations mentioning authentication]

You: "what tools do I use most?"
Claude: [Analyzes and shows tool usage patterns]
```

## Customization

Skills are just markdown files! You can:

1. **Edit existing skills:**
   - Modify trigger phrases
   - Add new queries
   - Change output formats

2. **Create new skills:**
   - Copy an existing skill as a template
   - Add your own queries
   - Define new trigger phrases

Example - create a custom skill:

```bash
# Create a new skill file
cat > ~/.claude/skills/my-custom-skill.md << 'EOF'
# My Custom Skill

**Trigger:** "my custom query"

**Purpose:** Description of what this does

## Query

```sql
SELECT * FROM conversation_events LIMIT 10;
```
EOF
```

## Uninstallation

To remove the skills:

```bash
rm ~/.claude/skills/claude-stats.md
rm ~/.claude/skills/search-conversations.md
rm ~/.claude/skills/analyze-tools.md
rm ~/.claude/skills/recent-work.md
```

Or to remove all skills:

```bash
rm -rf ~/.claude/skills
```

## Documentation

- [SKILLS-README.md](../SKILLS-README.md) - Detailed technical documentation
- [SKILLS-SUMMARY.md](../SKILLS-SUMMARY.md) - Quick reference guide
- [Main README](../README.md) - Vibe-check installation and usage

## Troubleshooting

**"Database not found"**
- Ensure vibe-check monitor is installed
- Check database exists at expected location
- Run `./query-helper.sh` to test access

**"Database is locked"**
- Skills use read-only mode to avoid this
- If it persists, temporarily stop the monitor

**"No results"**
- Ensure monitor has collected data
- Check if monitor is running
- Verify date ranges in queries

**Skills not working**
- Verify files are in `~/.claude/skills/`
- Check file permissions (should be readable)
- Try the exact trigger phrases listed above

## Contributing

To improve these skills:

1. Edit the skill files in this directory
2. Test with Claude Code
3. Run `./install-skills.sh` to update your local copy
4. Commit and share improvements!

## How Claude Discovers Skills

Claude Code automatically scans `~/.claude/skills/` for `.md` files. The skills system works by:

1. **Trigger detection:** Claude matches your natural language to trigger phrases in skill headers
2. **Skill loading:** The relevant skill file is read and provided as context
3. **Instruction following:** Claude executes the queries and formats output as specified
4. **Response:** Results are returned to you in the conversation

No configuration needed - just place `.md` files in the skills directory!
