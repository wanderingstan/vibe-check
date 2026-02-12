# Vibe Check Testing Guide

## Quick Reference

You have **three testing options**:

```bash
# 1. VM Testing (recommended - clean environment)
./tests/vm-test.sh

# 2. Physical Mac Testing (via SSH)
./tests/test-remote.sh --mock-claude testuser@mac-mini

# 3. Local Testing (quick validation)
./tests/quick-test.sh                # Fast checks
./tests/test-install.sh --mock-claude # Full suite
```

**See [TESTING_OPTIONS.md](TESTING_OPTIONS.md) for detailed comparison.**

## Choose Your Testing Environment

### Option 1: VM Testing (Recommended)

**Best for:** Clean environment, rapid iteration, CI/CD

```bash
# One-time setup
brew install cirruslabs/cli/tart

# Run tests
./tests/vm-test.sh
```

Advantages:
- Truly clean macOS environment every time
- Fast snapshots and rollback
- No separate hardware needed
- Perfect for automated testing

See: [VM Testing in TESTING_OPTIONS.md](TESTING_OPTIONS.md#vm-testing)

### Option 2: Physical Mac Testing

**Best for:** Final validation, real hardware testing

```bash
# From your development machine
./tests/test-remote.sh user@mac-mini

# If testing with a user that doesn't have Claude Code installed
./tests/test-remote.sh --mock-claude testuser@mac-mini
```

This single command will:
1. ✓ Verify SSH connection
2. ✓ Check remote prerequisites (Python, Git, Claude Code)
3. ✓ Copy your local repository to the Mac Mini
4. ✓ Run the complete test suite
5. ✓ Clean up automatically
6. ✓ Report results back to you

**No manual SSH required!**

### Prerequisites for Remote Testing

On the Mac Mini:
- Remote Login enabled (System Settings > Sharing > Remote Login)
- SSH key authentication set up
- Python 3 installed
- Git installed
- Claude Code installed and run at least once (or use `--mock-claude` flag)

On your local machine:
- SSH access to the Mac Mini
- Your local vibe-check repository

### Quick Mode

For faster iteration during development:

```bash
./tests/test-remote.sh --quick user@mac-mini
```

This skips time-consuming tests like reinstall scenarios.

## Local Testing

### Before Committing

Always run quick validation before committing:

```bash
./tests/quick-test.sh
```

This checks:
- Python syntax
- Shell script syntax
- JSON validity
- Required files present
- Skills structure
- Version consistency

### Full Test Suite

Run comprehensive tests before releasing:

```bash
./tests/test-install.sh
```

Tests include:
- **Prerequisites**: Python, Git, Claude Code detection
- **Installation**: Fresh install, directory structure, venv setup
- **Configuration**: Config file creation, database schema
- **Skills**: All skills installed correctly
- **Commands**: vibe-check command availability
- **Dependencies**: Python packages installed
- **Updates**: Reinstall/update scenarios
- **Functional**: Daemon start/stop, database operations

### Test Options

```bash
# Verbose output for debugging
./tests/test-install.sh --verbose

# Skip time-consuming tests
./tests/test-install.sh --quick

# Clean up test artifacts only
./tests/test-install.sh --cleanup
```

## What Gets Backed Up

The test suite is **safe** to run on your development machine:

**Automatically backed up:**
- `~/.vibe-check/` → `~/.vibe-check.backup.<timestamp>/`
- `~/.claude/skills/vibe-check-*` → `~/.claude/skills.backup.<timestamp>/`
- Shell config files (`.zshrc`, `.bashrc`, etc.)

**Automatically restored:**
- Everything is restored on test completion (pass or fail)
- Original installation preserved
- No data loss

## CI/GitHub Actions

Tests run automatically on:
- Push to `main` or `develop` branches
- Pull requests to `main`
- Manual workflow dispatch

See `.github/workflows/test-install.yml` for configuration.

## Common Scenarios

### Scenario 1: Testing a Bug Fix

```bash
# 1. Make your changes
vim vibe-check.py

# 2. Quick syntax check
./tests/quick-test.sh

# 3. Test locally
python3 vibe-check.py  # NOT vibe-check command!

# 4. Run full test suite
./tests/test-install.sh

# 5. Test on Mac Mini
./tests/test-remote.sh user@mac-mini
```

### Scenario 2: Testing Install Script Changes

```bash
# 1. Modify install script
vim scripts/install.sh

# 2. Validate syntax
bash -n scripts/install.sh

# 3. Test installation
./tests/test-install.sh

# 4. Test on fresh Mac Mini (with fresh user account)
./tests/test-remote.sh --mock-claude testuser@mac-mini
```

### Scenario 3: Testing on Fresh User Account

When testing on a Mac Mini with a test user that doesn't have Claude Code:

```bash
# Use --mock-claude to create a fake ~/.claude/projects directory
./tests/test-remote.sh --mock-claude testuser@mac-mini

# This allows the installer to pass the Claude Code prerequisite check
# without requiring a full Claude Code installation on the test account
```

### Scenario 3: Release Testing

```bash
# 1. Run all local tests
./tests/quick-test.sh
./tests/test-install.sh --verbose

# 2. Test on Mac Mini
./tests/test-remote.sh user@mac-mini

# 3. Test Homebrew installation (if applicable)
# On Mac Mini: brew install wanderingstan/vibe-check/vibe-check

# 4. Verify skills work in Claude Code
# Open Claude Code and test skills
```

## Troubleshooting

### Remote Test Fails to Connect

```bash
# Test SSH connection manually
ssh user@mac-mini

# Check Remote Login is enabled
# System Settings > Sharing > Remote Login

# Verify SSH keys
ssh-copy-id user@mac-mini
```

### Tests Fail on Mac Mini

```bash
# Run tests with verbose output
./tests/test-remote.sh --quick user@mac-mini

# SSH in and check manually
ssh user@mac-mini
cd /tmp/vibe-check-test-*  # Find the temp directory
./tests/test-install.sh --verbose
```

### Local Tests Fail

```bash
# Run with verbose output
./tests/test-install.sh --verbose

# Check specific logs
cat /tmp/vibe-check-test-install.log

# Clean up and retry
./tests/test-install.sh --cleanup
./tests/test-install.sh
```

### Environment Not Restored

```bash
# Manually restore from backup
ls -la ~/.vibe-check.backup.*
mv ~/.vibe-check.backup.XXXXXX ~/.vibe-check

# Restore skills
ls -la ~/.claude/skills.backup.*
mv ~/.claude/skills.backup.XXXXXX/vibe-check-* ~/.claude/skills/
```

## Adding New Tests

To add a new test to the suite:

1. Edit `tests/test-install.sh`
2. Create a test function:
   ```bash
   test_your_feature() {
       log_verbose "Testing your feature..."

       # Your test logic
       if [ condition ]; then
           log_error "What failed"
           return 1
       fi

       log_verbose "✓ Success message"
       return 0
   }
   ```
3. Add to test runner:
   ```bash
   run_test "Your Feature Name" test_your_feature
   ```

## Test Coverage

Currently tested:
- ✓ Prerequisites detection
- ✓ Fresh installation
- ✓ Installation directories
- ✓ Configuration creation
- ✓ Database schema
- ✓ Skills installation
- ✓ Command availability
- ✓ Python dependencies
- ✓ Reinstall/update
- ✓ Daemon start/stop
- ✓ Database operations
- ✓ Event monitoring and storage (end-to-end)

Not yet automated (manual testing required):
- API sync functionality
- Git hooks
- Homebrew formula
- Web stats page
- MCP server
- Skills invocation in Claude Code

## Performance

Typical test times:
- `quick-test.sh`: < 5 seconds
- `test-install.sh --quick`: ~2-3 minutes
- `test-install.sh` (full): ~5-10 minutes
- `test-remote.sh`: ~5-10 minutes (includes network transfer)

## Files

- `test-install.sh` - Main test suite
- `quick-test.sh` - Fast validation checks
- `test-remote.sh` - SSH testing helper
- `remote-test.sh` - Standalone remote installer test
- `README.md` - Test documentation
- `TESTING_GUIDE.md` - This file
- `.github/workflows/test-install.yml` - CI configuration
