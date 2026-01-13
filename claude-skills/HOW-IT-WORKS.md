# How Claude Code Skills Work

This document explains how Claude Code skills are distributed and installed with vibe-check.

## Overview

Claude Code has a **skills system** that allows tools and packages to extend Claude's capabilities. Skills are markdown files placed in `~/.claude/skills/` that provide Claude with specialized knowledge.

## How Skills Are Discovered

1. **Auto-discovery:** Claude Code automatically scans `~/.claude/skills/*.md` files
2. **Trigger matching:** When you use certain phrases, Claude matches them to skill trigger phrases
3. **Skill loading:** The relevant skill file is read and used as context
4. **Execution:** Claude follows the instructions in the skill to query data and format responses

## Distribution Pattern

### For Package Maintainers (like vibe-check)

The standard pattern for distributing skills with a tool:

```
your-package/
├── README.md                     # Main docs (mention skills)
├── claude-skills/                # Skills directory
│   ├── README.md                # Skills documentation
│   ├── install-skills.sh        # Installation script
│   ├── skill-1.md               # Individual skills
│   ├── skill-2.md
│   └── ...
└── your-main-tool
```

### Installation Script Pattern

The `install-skills.sh` script:

1. **Creates** `~/.claude/skills/` if needed
2. **Backs up** existing skills with same names
3. **Copies** skill files to the user's skills directory
4. **Provides feedback** about what was installed

Example structure:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$HOME/.claude/skills"

# Create directory
mkdir -p "$SKILLS_DIR"

# Backup existing skills
# (implement backup logic)

# Copy skills
cp "$SCRIPT_DIR"/*.md "$SKILLS_DIR/"

echo "✅ Skills installed!"
```

## For Users

### Installing Skills from a Package

When a package includes Claude Code skills:

```bash
# Navigate to the package directory
cd ~/path/to/package

# Run the skills installer
./claude-skills/install-skills.sh
```

Skills are copied to `~/.claude/skills/` and immediately available.

### Manual Installation

Users can also manually install skills:

```bash
# Copy individual skill files
cp package/claude-skills/my-skill.md ~/.claude/skills/

# Or copy all skills
cp package/claude-skills/*.md ~/.claude/skills/
```

### Verifying Installation

Check installed skills:

```bash
ls -la ~/.claude/skills/
```

Each `.md` file is a skill that Claude can use.

## How vibe-check Uses This

### 1. **Package Structure**

```
vibe-check/
├── claude-skills/
│   ├── README.md                # Full documentation
│   ├── install-skills.sh        # Installer
│   ├── claude-stats.md          # Usage statistics skill
│   ├── search-conversations.md  # Search skill
│   ├── analyze-tools.md         # Tool analysis skill
│   └── recent-work.md           # Recent activity skill
├── README.md                    # Mentions skills
└── ...other files
```

### 2. **User Journey**

1. **Install vibe-check** (monitor starts collecting data)
2. **Install skills:** `./claude-skills/install-skills.sh`
3. **Use naturally:** Just ask Claude questions like "claude stats"

### 3. **Skills Access Local Data**

The skills contain SQL queries that:
- Query the local SQLite database (`vibe_check.db`)
- Use read-only mode to avoid locks
- Format results for presentation

Example skill structure:

```markdown
# Skill Name

**Trigger:** "trigger phrase"

**Purpose:** What this skill does

## Database Location

Path to the database

## Queries

```sql
SELECT * FROM table WHERE condition;
```

## Response Format

How to present the results
```

## Best Practices

### For Package Maintainers

1. **Separate directory:** Keep skills in `claude-skills/` or similar
2. **Install script:** Provide `install-skills.sh` for easy setup
3. **Document triggers:** Clearly list trigger phrases
4. **README:** Explain what skills do and how to install
5. **Backup existing:** Don't overwrite user's customized skills without backing up
6. **Git ignore:** Don't commit user's `~/.claude/skills/` directory

### For Users

1. **Review first:** Read skill files before installing
2. **Customize freely:** Skills are just markdown - edit as needed
3. **Check triggers:** Know what phrases activate skills
4. **Backup important:** Keep copies of customized skills
5. **Update carefully:** Re-running install overwrites customizations (backup made automatically)

## Skill File Format

Basic structure of a skill file:

```markdown
# Skill Title

**Trigger:** "phrase that activates this", "alternative phrase"

**Purpose:** Brief description of what this skill does

---

## Section 1: Context

Provide background information Claude needs

## Section 2: Instructions

Tell Claude what to do:
- Step 1
- Step 2
- Step 3

## Section 3: Queries

```sql
-- SQL queries or other code
SELECT * FROM table;
```

## Section 4: Output Format

Example of how to format the response:

```
Expected output structure
```
```

## Advanced: Skills with Dependencies

Some skills may require:

- **Database access:** Like vibe-check (requires local SQLite)
- **External tools:** Command-line utilities
- **API keys:** For external services
- **Other packages:** Installed dependencies

Document these requirements clearly in the skill's README.

## Security Considerations

Skills can execute code through Claude, so:

1. **Review before installing:** Check what queries/commands are in the skill
2. **Trust the source:** Only install skills from trusted packages
3. **Read-only when possible:** Database queries should use read-only mode
4. **No sensitive data:** Don't put API keys or passwords in skill files
5. **Sandbox awareness:** Skills run with your user permissions

## Future: Skill Distribution

Potential future improvements to the skills ecosystem:

- **Skill registry:** Central repository of skills
- **Package manager:** `claude install skill-name`
- **Version management:** Track skill versions
- **Dependency resolution:** Auto-install required skills
- **Skill marketplace:** Discover and share skills

## Examples in the Wild

Projects using Claude Code skills:

1. **vibe-check** - Database query skills for conversation analysis
2. **Your project here** - Add your own!

## Contributing

To improve the skills ecosystem:

1. Create useful skills for your tools
2. Share installation patterns
3. Document best practices
4. Report issues and improvements

## Resources

- [Claude Code Documentation](https://github.com/anthropics/claude-code)
- [vibe-check Skills](README.md) - Example implementation
- Community examples (TBD)

---

**Questions?** Open an issue or contribute to the documentation!
