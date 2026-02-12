# Vibe Check Test Suite

Automated tests for the Vibe Check installation process.

## Testing Options

You have **four ways** to test vibe-check installation:

1. **🔲 VM Testing** (recommended) - Clean macOS VM using Tart
   ```bash
   ./vm-test.sh
   ```

2. **🍺 Homebrew VM Testing** - Test Homebrew installation in clean VM
   ```bash
   ./vm-test-homebrew.sh          # Test published formula
   ./vm-test-homebrew.sh --local  # Test local formula
   ```

3. **🖥️ Physical Mac** - Test on real Mac Mini via SSH
   ```bash
   ./test-remote.sh --mock-claude testuser@mac-mini
   ```

4. **💻 Local Testing** - Test on your development machine
   ```bash
   ./test-install.sh --mock-claude
   ```

See [TESTING_OPTIONS.md](TESTING_OPTIONS.md) for detailed comparison and guides.

## Quick Start

**VM testing (recommended for clean environment):**
```bash
brew install cirruslabs/cli/tart  # One-time setup
./vm-test.sh                      # Run tests in VM
```

**Quick validation:**
```bash
./quick-test.sh                   # Fast syntax/structure checks
```

**Full local test:**
```bash
./test-install.sh --mock-claude   # Full suite on your machine
```

**Homebrew testing:**
```bash
# Test published Homebrew formula
./vm-test-homebrew.sh

# Test local formula (before publishing)
./vm-test-homebrew.sh --local
```

## What Gets Tested

### Prerequisites
- Python 3 installation
- pip availability
- Git installation
- Claude Code installation (~/.claude/projects exists)
- Required repository files present

### Installation
- Fresh installation completes without errors
- All required directories created
- Virtual environment set up correctly
- Configuration file created with valid JSON
- Database created with correct schema
- All skills installed to ~/.claude/skills
- vibe-check command wrapper created and executable
- Python dependencies installed

### Update/Reinstall
- Reinstallation preserves configuration
- Updates work correctly
- Git pull succeeds

### Functional Tests
- Daemon starts and stops correctly
- Status command works
- Database can be queried
- Read-only database access works
- Event monitoring and storage (uses `simulate-event.sh` to verify events are captured)

## Test Safety

The test suite:
- **Backs up** your existing installation to `~/.vibe-check.backup.<timestamp>`
- **Backs up** your existing skills to `~/.claude/skills.backup.<timestamp>`
- **Backs up** your shell config files before modifying PATH
- **Restores** everything automatically on exit (success or failure)

## Running on a Fresh Mac

To test the installation on a fresh system:

```bash
# 1. Clone the repo
git clone https://github.com/wanderingstan/vibe-check.git
cd vibe-check

# 2. Ensure Claude Code is installed
# Visit: https://code.claude.com/docs/en/quickstart

# 3. Run the test suite
./tests/test-install.sh
```

## Remote Testing via SSH

### Method 1: Using the helper script (recommended)

```bash
# From your local machine, test on remote Mac
./tests/test-remote.sh user@mac-mini

# Quick test only
./tests/test-remote.sh --quick user@mac-mini

# Create mock Claude Code directory if it doesn't exist
./tests/test-remote.sh --mock-claude testuser@mac-mini

# Combine options
./tests/test-remote.sh --quick --mock-claude testuser@mac-mini
```

The helper script will:
- Verify SSH connection
- Check remote prerequisites (Python, Git, Claude Code)
- Optionally create mock `~/.claude/projects` with `--mock-claude` flag
- Copy the repository to the remote system
- Run the full test suite
- Clean up automatically
- Report results

**Testing on fresh user accounts:** Use `--mock-claude` to create a mock Claude Code directory if the test user doesn't have Claude Code installed. This allows testing the installer without requiring Claude Code on every test account.

### Method 2: Manual SSH testing

```bash
# SSH into the Mac
ssh user@mac-mini

# Run the automated test via curl
curl -fsSL https://raw.githubusercontent.com/wanderingstan/vibe-check/main/tests/remote-test.sh | bash
```

## CI/GitHub Actions

The test suite supports non-interactive mode for CI:

```bash
# Skip interactive prompts, use --skip-auth
./test-install.sh --quick
```

See `.github/workflows/test-install.yml` for CI configuration.

## Exit Codes

- `0` - All tests passed
- `1` - One or more tests failed
- `2` - Prerequisites not met (can't run tests)

## Debugging Failed Tests

If a test fails:

1. Check the test output for specific failure messages
2. Look at the installation logs:
   ```bash
   cat /tmp/vibe-check-test-install.log
   ```
3. Run with `--verbose` for detailed output
4. Check the specific component that failed

## Adding New Tests

To add a new test:

1. Create a test function following the pattern:
   ```bash
   test_your_feature() {
       log_verbose "Testing your feature..."

       # Test logic here
       if [ condition ]; then
           log_error "What went wrong"
           return 1
       fi

       log_verbose "✓ What succeeded"
       return 0
   }
   ```

2. Add it to the test runner in `main()`:
   ```bash
   run_test "Your Feature" test_your_feature
   ```

## Homebrew Testing

### Test Homebrew Installation in VM

Test the production Homebrew install path (different from direct install.sh):

```bash
# Test published formula from tap (what users get)
./vm-test-homebrew.sh

# Test local formula file (before publishing)
./vm-test-homebrew.sh --local

# Quick tests only
./vm-test-homebrew.sh --quick
```

**What's tested:**
- ✓ Homebrew package installation
- ✓ Proper paths (Cellar, bin, share)
- ✓ `brew services` integration
- ✓ Data directory and symlinks
- ✓ Config and database
- ✓ Skills and MCP server files

**Key differences from direct install:**
| Aspect | Homebrew | Direct Install |
|--------|----------|----------------|
| Code location | `/opt/homebrew/Cellar/...` | `~/.vibe-check/` |
| Venv | Homebrew libexec | `~/.vibe-check/venv` |
| Auto-start | `brew services` | launchd/systemd |
| Updates | `brew upgrade` | `git pull` |

### When to use Homebrew tests:
- Before releasing new Homebrew version
- After updating `Formula/vibe-check.rb`
- Before tagging releases
- To validate production install path

See `tests/README.md` in root for detailed Homebrew testing documentation.

## Manual Testing Checklist

For features not covered by automated tests:

- [ ] Installation from curl command works
- [ ] Homebrew installation works (use `./vm-test-homebrew.sh`)
- [ ] Skills appear correctly in Claude Code
- [ ] Skills can be invoked via Claude
- [ ] API sync works (requires auth)
- [ ] Git hooks work correctly
- [ ] Error messages are helpful
- [ ] Installation works on fresh macOS
- [ ] Installation works on Linux (Ubuntu, Fedora, Arch)
- [ ] Web stats page loads correctly
- [ ] MCP server works correctly
