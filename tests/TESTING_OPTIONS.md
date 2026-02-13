# Vibe Check Testing Options

You have **three ways** to test vibe-check installation on a fresh macOS environment:

## 1. 🖥️ Physical Mac Mini (Real Hardware)

**Best for:** Final release validation, real-world testing

**Pros:**
- Real hardware, real environment
- Tests actual Remote Login/SSH setup
- Can validate Homebrew installation
- Permanent test environment

**Cons:**
- Requires physical Mac
- Slower iteration (manual cleanup)
- Uses actual hardware resources

**Setup:**
```bash
# On Mac Mini: Enable Remote Login
# System Settings > Sharing > Remote Login

# From your dev machine:
./tests/test-remote.sh --mock-claude testuser@mac-mini
```

See: [Physical Mac Testing Guide](#physical-mac-testing)

---

## 2. 🔲 macOS VM (Virtualization)

**Best for:** Rapid iteration, automated testing, CI/CD

**Pros:**
- Truly clean environment every time
- Fast snapshots and rollback
- No separate hardware needed
- Can run multiple VMs
- Perfect for CI/CD pipelines

**Cons:**
- Requires Apple Silicon Mac
- ~25GB download (first time only)
- Slightly slower than native

**Note:** The script uses `macos-sonoma-base` image which includes the Tart guest agent pre-installed, enabling automated command execution via `tart exec`.

**Setup:**
```bash
# Install Tart (one-time)
brew install cirruslabs/cli/tart

# Run tests in VM
./tests/vm-test.sh
```

See: [VM Testing Guide](#vm-testing)

---

## 3. 💻 Local Testing (Your Dev Machine)

**Best for:** Quick validation, development iteration

**Pros:**
- Instant feedback
- No additional setup
- Perfect for quick checks

**Cons:**
- Not a clean environment
- May have existing vibe-check installation
- Requires manual cleanup

**Setup:**
```bash
./tests/test-install.sh --mock-claude
```

See: [Local Testing Guide](#local-testing)

---

## 4. 🍺 Homebrew Testing (VM)

**Best for:** Testing Homebrew formula, pre-release validation

**Pros:**
- Tests production Homebrew install path
- Clean environment (VM-based)
- Can test published or local formula
- Validates `brew services` integration

**Cons:**
- Requires Apple Silicon Mac
- ~25GB VM download (shared with vm-test.sh)
- Slower than local testing

**Note:** Tests the **Homebrew installation path**, which is different from direct `install.sh`. Uses same VM infrastructure as regular VM tests.

**Setup:**
```bash
# Install Tart (one-time, shared with vm-test.sh)
brew install cirruslabs/cli/tart

# Test published formula
./tests/vm-test-homebrew.sh

# Test local formula (before publishing)
./tests/vm-test-homebrew.sh --local
```

See: [Homebrew Testing Guide](#homebrew-testing)

---

# Detailed Guides

## Physical Mac Testing

### Prerequisites

**On the Mac Mini:**
1. Enable Remote Login:
   - System Settings > Sharing
   - Enable "Remote Login"
   - Add your user to allowed users

2. Set up SSH key authentication:
   ```bash
   # From your dev machine
   ssh-copy-id testuser@mac-mini
   ```

3. Install prerequisites (optional - tests can check):
   ```bash
   # SSH to Mac Mini
   ssh testuser@mac-mini

   # Install Homebrew
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

   # Install dependencies
   brew install python git
   ```

### Running Tests

**Quick test:**
```bash
./tests/test-remote.sh --quick --mock-claude testuser@mac-mini
```

**Full test suite:**
```bash
./tests/test-remote.sh --mock-claude testuser@mac-mini
```

**What happens:**
1. Verifies SSH connection
2. Checks prerequisites (Python, Git)
3. Creates mock `~/.claude/projects` (since testuser doesn't have Claude Code)
4. Copies your local code to Mac Mini
5. Runs full installation and validation tests
6. Cleans up and reports results

### Cleanup

The tests automatically clean up, but to manually reset:

```bash
# SSH to Mac Mini
ssh testuser@mac-mini

# Remove vibe-check
rm -rf ~/.vibe-check
rm -rf ~/.claude/skills/vibe-check-*

# Remove from PATH (if added)
# Edit ~/.zshrc or ~/.bashrc and remove vibe-check lines
```

---

## VM Testing

### One-Time Setup

Install Tart (macOS VM manager):

```bash
brew install cirruslabs/cli/tart
```

That's it! The first test run will download the base macOS image (~25GB), which is cached for future use.

### Running Tests

**Create VM and run tests:**
```bash
./tests/vm-test.sh
```

**Quick tests only:**
```bash
./tests/vm-test.sh --quick
```

**Set up VM without running tests:**
```bash
./tests/vm-test.sh --setup
```

**Open shell in VM (for debugging):**
```bash
./tests/vm-test.sh --shell
```

**Clean up VM:**
```bash
./tests/vm-test.sh --cleanup
```

### What Happens

1. Creates/starts macOS VM (if not exists)
2. Installs Homebrew and dependencies
3. Creates mock Claude Code directory
4. Copies your local repository to VM
5. Runs full test suite
6. Stops VM and reports results

The VM persists between runs, so subsequent tests are much faster.

### Starting Fresh

To test with a completely clean VM:

```bash
./tests/vm-test.sh --cleanup   # Delete VM
./tests/vm-test.sh             # Create new VM and test
```

### Advantages for CI/CD

VM testing is perfect for GitHub Actions:

```yaml
- name: Install Tart
  run: brew install cirruslabs/cli/tart

- name: Run VM tests
  run: ./tests/vm-test.sh --quick
```

---

## Local Testing

### Prerequisites

Your Mac must have:
- Python 3
- Git
- Claude Code installed (or use `--mock-claude`)

### Running Tests

**Quick validation:**
```bash
./tests/quick-test.sh
```

**Full test suite:**
```bash
./tests/test-install.sh --mock-claude
```

**Full test with verbose output:**
```bash
./tests/test-install.sh --mock-claude --verbose
```

### Safety

Local tests automatically:
- Back up `~/.vibe-check/` to `~/.vibe-check.backup.<timestamp>`
- Back up skills to `~/.claude/skills.backup.<timestamp>`
- Restore everything on completion (pass or fail)

### When to Use

- ✅ Quick syntax/logic validation
- ✅ Testing specific components
- ✅ Pre-commit checks
- ❌ Final release validation (use VM or Mac Mini)

---

## Homebrew Testing

### Overview

Tests the **production Homebrew installation path** in a clean macOS VM. This is different from direct `install.sh` testing - it validates how users install via `brew install vibe-check`.

### Prerequisites

```bash
# Install Tart (same as VM testing)
brew install cirruslabs/cli/tart
```

First run downloads ~25GB base image (shared with `vm-test.sh`).

### Running Tests

**Test published formula (what users get):**
```bash
./tests/vm-test-homebrew.sh
```

**Test local formula (before publishing):**
```bash
./tests/vm-test-homebrew.sh --local
```

**Quick tests only:**
```bash
./tests/vm-test-homebrew.sh --quick
```

**Set up VM without tests:**
```bash
./tests/vm-test-homebrew.sh --setup
```

**Debug in VM:**
```bash
./tests/vm-test-homebrew.sh --shell
# Inside VM:
eval "$(/opt/homebrew/bin/brew shellenv)"
vibe-check status
```

**Clean up VM:**
```bash
./tests/vm-test-homebrew.sh --cleanup
```

### What Gets Tested

- ✓ Homebrew package installation from tap
- ✓ Proper Homebrew paths (Cellar, bin, share)
- ✓ `brew services` integration (start/stop/status)
- ✓ Data directory at `~/.vibe-check` (symlinked)
- ✓ Config and database creation
- ✓ Skills installation to `~/.claude/skills`
- ✓ MCP server files in share directory
- ✓ Daemon functionality
- ✓ Database operations

### Key Differences from Direct Install

| Aspect | Homebrew | Direct Install |
|--------|----------|----------------|
| **Source** | Release tarball | Git repo |
| **Code location** | `/opt/homebrew/Cellar/...` | `~/.vibe-check/` |
| **Venv** | Homebrew libexec | `~/.vibe-check/venv` |
| **Data** | `~/.vibe-check/` (symlinked) | `~/.vibe-check/` |
| **Auto-start** | `brew services` | launchd/systemd |
| **Updates** | `brew upgrade vibe-check` | `git pull` |

**Note:** Both paths use the same `~/.vibe-check/` directory for data storage.

### When to Use

- ✅ Before releasing new Homebrew version
- ✅ After updating `Formula/vibe-check.rb`
- ✅ Before tagging releases
- ✅ To validate production install path
- ❌ During active development (use `vm-test.sh` instead)

### Test Modes

**Published formula mode (default):**
- Tests what users actually get
- Requires formula pushed to `wanderingstan/vibe-check` tap
- Best for final release validation

**Local formula mode (`--local`):**
- Tests `Formula/vibe-check.rb` from your repo
- No need to publish first
- Best for testing formula changes pre-release

### Advantages for Release Workflow

1. Edit `Formula/vibe-check.rb` (version, URL, etc.)
2. Test locally: `./tests/vm-test-homebrew.sh --local`
3. Push formula to tap
4. Test published: `./tests/vm-test-homebrew.sh`
5. Tag release with confidence

---

# Comparison Matrix

| Feature | Physical Mac | VM (install.sh) | Homebrew VM | Local |
|---------|-------------|-----------------|-------------|-------|
| **Clean environment** | ✅ | ✅✅ | ✅✅ | ⚠️ |
| **Speed** | ✅✅ | ✅ | ✅ | ✅✅✅ |
| **Setup complexity** | Medium | Low | Low | None |
| **Cost** | Hardware | Free | Free | Free |
| **CI/CD ready** | ❌ | ✅✅ | ✅✅ | ✅ |
| **Snapshot/rollback** | Manual | ✅✅ | ✅✅ | ⚠️ |
| **Tests production path** | ✅✅ | ⚠️ (repo) | ✅✅ (brew) | ⚠️ |
| **Real hardware validation** | ✅✅ | ⚠️ | ⚠️ | ⚠️ |

---

# Recommended Workflow

## For Development

1. **Local quick tests** during development:
   ```bash
   ./tests/quick-test.sh
   ```

2. **VM tests** before committing:
   ```bash
   ./tests/vm-test.sh --quick
   ```

## For Release Validation

1. **Full VM test:**
   ```bash
   ./tests/vm-test.sh
   ```

2. **Physical Mac test** (final validation):
   ```bash
   ./tests/test-remote.sh --mock-claude testuser@mac-mini
   ```

3. **Homebrew test** (if applicable):
   ```bash
   ssh testuser@mac-mini
   brew install wanderingstan/vibe-check/vibe-check
   ```

## For CI/CD

Use VM testing in GitHub Actions:

```yaml
jobs:
  test-macos-vm:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Tart
        run: brew install cirruslabs/cli/tart
      - name: Run VM tests
        run: ./tests/vm-test.sh --quick
```

---

# Troubleshooting

## Physical Mac Issues

**Can't connect via SSH:**
```bash
# Test connection
ssh testuser@mac-mini echo "Connected"

# Check Remote Login is enabled
# System Settings > Sharing > Remote Login
```

**Tests fail on Mac Mini:**
```bash
# Run with verbose output
./tests/test-remote.sh --mock-claude testuser@mac-mini

# Or SSH in and run manually
ssh testuser@mac-mini
cd /tmp/vibe-check-*
./tests/test-install.sh --verbose
```

## VM Issues

**Tart not found:**
```bash
brew install cirruslabs/cli/tart
```

**VM won't start:**
```bash
# Clean up and recreate
./tests/vm-test.sh --cleanup
./tests/vm-test.sh
```

**Download fails:**
```bash
# Manually pull base image
tart pull ghcr.io/cirruslabs/macos-sonoma-base:latest
```

**Guest Agent not ready:**
```bash
# The script now uses 'base' image with guest agent pre-installed
# If you still have timeout issues:

# 1. Check which image you're using:
tart list

# 2. Clean up old vanilla image and retry:
./tests/vm-test.sh --cleanup
./tests/vm-test.sh

# 3. Manually verify guest agent:
./tests/vm-test.sh --shell
# Inside VM, check: ps aux | grep tart-guest-agent

# 4. Check VM diagnostics:
tart ip vibe-check-test    # Should show an IP
tart list                   # Check VM state
```

**First boot takes too long:**
The first boot of a fresh macOS VM can take 3-5 minutes while macOS completes its initial setup. The test script waits up to 3 minutes for the guest agent. If this isn't enough:
1. Let the VM finish booting manually: `./tests/vm-test.sh --shell`
2. Complete any macOS setup prompts
3. Exit the VM
4. Run tests again: `./tests/vm-test.sh`

## Local Issues

**Environment not restored:**
```bash
# Manually restore
mv ~/.vibe-check.backup.* ~/.vibe-check
mv ~/.claude/skills.backup.*/vibe-check-* ~/.claude/skills/
```

---

# Next Steps

Choose your testing approach:

- **Rapid iteration?** → Use [VM testing](#vm-testing)
- **Final validation?** → Use [Physical Mac](#physical-mac-testing)
- **Quick checks?** → Use [Local testing](#local-testing)

All three approaches use the same test suite, just in different environments!
