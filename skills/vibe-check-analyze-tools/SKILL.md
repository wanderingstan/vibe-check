---
name: analyze-tools
description: Analyze which tools Claude uses most frequently. Use when user says "what tools do I use most", "tool usage stats", "analyze my claude tools", or "which tools does claude use".
---

# Analyze Claude Tool Usage

**Purpose:** Analyze which tools Claude uses most frequently in conversations using the MCP server

---

## Using the MCP Tool

The vibe-check MCP server provides a `vibe_tools` tool that analyzes Claude's tool usage patterns automatically.

### Tool: `mcp__vibe-check__vibe_tools`

**Parameters:**
- `days` (optional): Number of days to analyze (default: 30)
- `repo` (optional): Filter to specific repository
- `show_combinations` (optional): Include tool combination analysis (default: False)

---

## Usage Flow

When user requests tool analysis:

1. **Extract filters** from user's question:
   - Time range (if specified) → convert to `days` parameter
   - Repository (if specified) → use `repo` parameter
   - If they ask about "combinations" or "patterns" → set `show_combinations=True`

2. **Call the MCP tool** with appropriate parameters

3. **Present results** - the tool returns formatted output with:
   - Most used tools with usage counts and percentages
   - Visual bar charts
   - Total tool usage count
   - Tool combinations (if requested)

4. **Offer insights** based on the data:
   - Which tools dominate
   - What the tool mix suggests about work patterns
   - Recommendations for workflow improvements

---

## Example Interactions

### Example 1: Overall Tool Usage

```
User: "what tools do I use most?"

Claude: [Calls mcp__vibe-check__vibe_tools with days=30]

[Tool returns top tools with usage stats and bar charts]

This shows you're doing a lot of file reading and bash commands, suggesting
you're working with existing code and running tests/builds frequently.
```

### Example 2: Recent Tool Usage

```
User: "what tools have I been using this week?"

Claude: [Calls mcp__vibe-check__vibe_tools with days=7]

[Tool returns last 7 days of tool usage]
```

### Example 3: Repo-Specific Analysis

```
User: "analyze my tool usage in the vibe-check project"

Claude: [Calls mcp__vibe-check__vibe_tools with repo="vibe-check"]

[Tool returns vibe-check repo tool usage]
```

### Example 4: With Combinations

```
User: "show me which tools I use together most often"

Claude: [Calls mcp__vibe-check__vibe_tools with days=30, show_combinations=True]

[Tool returns top tools plus common tool combinations like "Grep + Read"]
```

---

## Interpreting Results

### Common Tool Patterns

**Heavy Read usage**: Exploring and understanding code
- Suggests research/learning phase or code review work

**Heavy Edit usage**: Actively modifying code
- Suggests active development and refactoring

**Heavy Bash usage**: Running commands, tests, git operations
- Suggests integration work, testing, deployment

**Grep + Glob combination**: Searching for code patterns
- Suggests investigative work or debugging

**Read + Edit combination**: Understanding then modifying
- Suggests careful, iterative development

**Write usage**: Creating new files
- Suggests new feature development or documentation

---

## Related Tools

Use these complementary MCP tools:

- **`mcp__vibe-check__vibe_stats`**: See overall usage statistics
- **`mcp__vibe-check__vibe_recent`**: View recent sessions to see context
- **`mcp__vibe-check__vibe_search`**: Search for specific tool usage patterns
- **`mcp__vibe-check__vibe_session`**: Deep dive into a specific session's tools

---

## Error Handling

The MCP tool handles errors automatically:

- If no tool usage found, it explains that no data is available
- If database not accessible, it provides helpful file path information
- All database locking is handled internally with read-only mode

---

## Tips

- Use default 30 days first to get a good overview
- Add `show_combinations=True` to understand workflow patterns
- Compare tool usage across different repos to see how work differs
- Use tool analysis to identify if you're spending too much time on certain activities
- If you see lots of Bash errors, might indicate test/build issues
- High Grep usage might suggest code organization could be improved

---

## Advanced: Custom SQL Queries

For custom tool analysis not covered by `vibe_tools`, use the `mcp__vibe-check__vibe_sql` tool:

```python
mcp__vibe-check__vibe_sql(
    query="""
        SELECT json_extract(value, '$.name') as tool, COUNT(*) as uses
        FROM conversation_events, json_each(json_extract(event_data, '$.message.content'))
        WHERE json_extract(value, '$.type') = 'tool_use'
        GROUP BY tool ORDER BY uses DESC
    """,
    limit=100
)
```

This provides read-only access to the full database with custom SQL. See the vibe-check-sql skill for more examples.

For schema information, see `~/.vibe-check/SCHEMA.md` (auto-generated) or use the Read tool.
