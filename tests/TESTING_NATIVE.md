# Testing VibeCheck Native macOS App

Comprehensive testing guide for the VibeCheck Swift native macOS application.

## Quick Start

### VM Tests (Recommended for Release Validation)

Test DMG installation on a clean macOS VM using Tart:

```bash
# Quick test with cached VM (5-10 minutes)
./tests/vm-test-native.sh --quick

# Full test with fresh VM (first run: 25GB download + 10 minutes)
./tests/vm-test-native.sh

# Test specific macOS version
./tests/vm-test-native.sh --os-version 14

# Cleanup VM after testing
./tests/vm-test-native.sh --cleanup

# Open shell in VM for debugging
./tests/vm-test-native.sh --shell
```

### Swift Unit Tests (Fast, for Development)

```bash
# Run all unit tests
swift test

# Run with parallel execution (faster)
swift test --parallel

# Run specific test suite
swift test --filter DatabaseManagerTests

# Run specific test
swift test --filter testInsertEvent

# With verbose output
swift test --verbose
```

## VM Testing Details

### What It Tests

The VM test suite (`vm-test-native.sh`) validates:

1. **DMG Installation**
   - DMG mounts correctly
   - .app copies to /Applications
   - DMG unmounts cleanly

2. **App Launch**
   - App starts without errors
   - Process runs in background
   - No crash on startup

3. **Database Creation**
   - Database created at `~/Library/Application Support/VibeCheck/`
   - Schema initialized correctly
   - All tables present (conversation_events, conversation_file_state, messages_fts)
   - Generated columns configured
   - FTS5 full-text search enabled

4. **Skills Installation**
   - Skills directory created: `~/.claude/skills/`
   - All skills copied (vibe-check-*)
   - SKILL.md files present
   - Correct directory structure

5. **MCP Server Registration**
   - `~/.claude/mcp_servers.json` created
   - vibe-check server registered
   - Binary path correct
   - Args array includes --mcp-server flag

6. **File Monitoring**
   - Detects new .jsonl files in `~/.claude/projects/`
   - Processes events and stores in database
   - Incremental processing (tracks line numbers)

7. **Code Signing**
   - Code signature valid
   - Deep verification passes
   - Binary is executable

8. **Gatekeeper Compatibility**
   - Ad-hoc signature: Warning expected
   - Developer ID: Should be accepted
   - Notarized: Fully accepted

### Prerequisites

**Required:**
- Tart: `brew install cirruslabs/cli/tart`
- Built DMG: `dist/VibeCheck-2.0.0.dmg` (auto-builds if missing)

**Optional:**
- Developer ID certificate (for distribution testing)

### VM Resources

- **Download size**: ~25GB (macOS base image)
- **Cached**: Yes - only downloads once
- **Disk usage**: ~30GB per VM (snapshots reuse base image)
- **Memory**: 4GB allocated to VM
- **Time**:
  - First run: 15-30 minutes (includes download)
  - Subsequent runs: 5-10 minutes (cached VM)

### Supported macOS Versions

Test across multiple macOS versions:

```bash
# macOS 13 Ventura
./tests/vm-test-native.sh --os-version 13

# macOS 14 Sonoma (default)
./tests/vm-test-native.sh --os-version 14

# macOS 15 Sequoia
./tests/vm-test-native.sh --os-version 15
```

### Test Modes

**Quick Mode** (`--quick`)
- Uses existing VM snapshot
- Skips fresh installation
- Fastest (5-10 minutes)
- Good for rapid iteration

**Full Mode** (default)
- Creates fresh VM or uses existing
- Full installation test
- Comprehensive validation
- Recommended for releases

**Setup Only** (`--setup`)
- Creates VM without running tests
- Useful for one-time VM preparation
- Run tests later with `--quick`

**Cleanup** (`--cleanup`)
- Deletes test VM
- Frees ~30GB disk space
- Use before starting fresh

**Shell Mode** (`--shell`)
- Opens interactive shell in VM
- Shared directory at: `/Volumes/My Shared Files/repo`
- DMG available in shared directory
- Useful for debugging test failures

### Troubleshooting

**VM Won't Start**

On first boot, macOS requires approval for Tart Guest Agent:

1. Run: `./tests/vm-test-native.sh --shell`
2. Wait for notification: "Background Items Added - tart-guest-agent"
3. Exit VM (Command+Q)
4. Re-run tests: `./tests/vm-test-native.sh`

The guest agent is automatically allowed after first boot.

**Tests Fail**

Debug in VM:
```bash
# Open shell in VM
./tests/vm-test-native.sh --shell

# Manually run test script
/tmp/test-native-app.sh

# Check app logs
log show --predicate 'process == "VibeCheck"' --last 5m

# Inspect database
sqlite3 ~/Library/Application\ Support/VibeCheck/vibe_check.db ".tables"
```

**Clean Start**

```bash
# Delete VM and start fresh
./tests/vm-test-native.sh --cleanup
./tests/vm-test-native.sh
```

## Swift Unit Testing

### Architecture

- **In-memory GRDB databases**: Fast, isolated, no file I/O
- **Actor-based concurrency**: Tests use Swift async/await
- **Protocol mocking**: For external dependencies
- **Test fixtures**: Reusable sample data

### Test Structure

```
Tests/VibeCheckTests/
├── TestHelpers/
│   ├── DatabaseTestCase.swift      # Base class with in-memory DB
│   ├── TestFixtures.swift          # Sample data (TODO)
│   └── MockURLSession.swift        # HTTP mocking (TODO)
│
├── Database/
│   └── DatabaseManagerTests.swift  # Database operations
│
├── Monitoring/                     # TODO
│   ├── JSONLParserTests.swift
│   └── FileMonitorTests.swift
│
├── Sync/                          # TODO
│   ├── APIClientTests.swift
│   └── RemoteSyncWorkerTests.swift
│
└── MCP/                           # TODO
    ├── MCPServerTests.swift
    └── Tools/
        ├── VibeStatsTests.swift
        └── ...
```

### Current Coverage

**Implemented:**
- `DatabaseManagerTests`: 13 test cases
  - Schema initialization
  - Insert operations
  - Query operations (by session, statistics)
  - Full-text search
  - Sync status tracking
  - Git metadata
  - Performance tests

**TODO (Future):**
- JSONLParser tests
- FileMonitor tests
- APIClient tests (with mock URLSession)
- RemoteSyncWorker tests
- MCP tool tests
- Integration tests

### Writing Tests

**Example: Testing database operations**

```swift
final class MyDatabaseTests: DatabaseTestCase {

    func testMyFeature() async throws {
        // Insert test data
        try await insertTestEvent(
            sessionId: "test-123",
            content: "Test message"
        )

        // Perform operation
        let events = try await dbManager.getSessionEvents(sessionId: "test-123")

        // Assert results
        XCTAssertEqual(events.count, 1)
    }
}
```

**Helper methods available:**

```swift
// Insert single event
let id = try await insertTestEvent(
    fileName: "test.jsonl",
    lineNumber: 1,
    sessionId: "session-1",
    eventType: "message",
    content: "Message text",
    model: "claude-3-opus"
)

// Insert multiple events
let ids = try await insertTestEvents(count: 5, sessionId: "session-1")

// Get event count
let count = try await getEventCount(sessionId: "session-1")

// Verify schema
try await verifyDatabaseSchema()
```

### Running Specific Tests

```bash
# All tests
swift test

# Specific suite
swift test --filter DatabaseManagerTests

# Specific test
swift test --filter testInsertEvent

# With coverage (requires additional setup)
swift test --enable-code-coverage
```

### Test Performance

Expected execution times:

| Test Suite | Tests | Time |
|------------|-------|------|
| DatabaseManagerTests | 13 | <1s |
| **All Tests** | 13 | <2s |

(As more tests are added, times will increase)

## Integration with CI/CD

### GitHub Actions

Example workflow for automated testing:

```yaml
name: Test Native App

on:
  push:
    branches: [main, vibe-check-macos]
  pull_request:
    branches: [main]

jobs:
  swift-tests:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Swift tests
        run: swift test --parallel

  vm-tests:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Tart
        run: brew install cirruslabs/cli/tart
      - name: Build DMG
        run: |
          ./Scripts/build-release.sh
          ./Scripts/create-dmg.sh
      - name: Run VM tests
        run: ./tests/vm-test-native.sh
```

### Local Pre-commit Hook

Add to `.git/hooks/pre-commit`:

```bash
#!/bin/bash
echo "Running Swift tests..."
swift test --parallel || exit 1
echo "✓ All tests passed"
```

## Best Practices

### Before Every Commit

```bash
# Run fast unit tests
swift test --parallel
```

### Before Every Release

```bash
# Full test suite
./Scripts/build-release.sh
./Scripts/create-dmg.sh
./tests/vm-test-native.sh

# Multi-OS testing
./tests/vm-test-native.sh --os-version 13
./tests/vm-test-native.sh --os-version 14
./tests/vm-test-native.sh --os-version 15
```

### When Debugging

```bash
# Test specific feature
swift test --filter MyTest

# Debug in VM
./tests/vm-test-native.sh --shell

# Check app logs
log show --predicate 'process == "VibeCheck"' --style compact
```

## Known Issues

### Unit Tests Use Real Database

Currently, Swift unit tests use the real database file at `~/Library/Application Support/VibeCheck/vibe_check.db` instead of an in-memory database. This causes:

- Tests may fail if app is running
- Test data pollutes production database
- Tests are not isolated

**Workaround**: Stop VibeCheck app before running tests, or use VM tests for validation.

**Fix needed**: Modify `DatabaseManager` to accept a database path parameter and use `:memory:` for tests.

### Performance Tests Are Non-Deterministic

The `measure` blocks in performance tests depend on system load. Results may vary.

## Additional Resources

- **Distribution Guide**: [DISTRIBUTION.md](../DISTRIBUTION.md) - Building and signing releases
- **Testing Plan**: `~/.claude/plans/harmonic-wondering-lighthouse.md` - Full testing strategy
- **VM Tool (Tart)**: https://tart.run - macOS virtualization documentation
- **GRDB Testing**: https://github.com/groue/GRDB.swift#testing - Database testing patterns
