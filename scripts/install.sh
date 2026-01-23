#!/bin/bash

# Vibe Check Installer (non-Homebrew)
#
# For macOS users: Use Homebrew instead:
#   brew tap wanderingstan/vibe-check
#   brew install vibe-check
#
# For Linux/other systems, install via:
#   curl -fsSL https://vibecheck.wanderingstan.com/install.sh | bash
#
# Or run from within the git repo:
#   ./scripts/install.sh
#
# Options:
#   --skip-auth    Skip authentication step (for testing/CI)

# Set up logging to temp file
INSTALL_LOG=$(mktemp /tmp/vibe-check-install.XXXXXX.log)
echo "Logging installation to: $INSTALL_LOG"

# Redirect all output to both console and log file
exec > >(tee -a "$INSTALL_LOG") 2>&1

# Error handler - launches Claude Code to diagnose issues
handle_error() {
    local exit_code=$?
    local line_number=$1

    echo ""
    echo -e "${RED}╔═══════════════════════════════════════╗${NC}"
    echo -e "${RED}║   Installation Failed (exit $exit_code)      ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Installation log saved to: $INSTALL_LOG${NC}"

    # Check if Claude Code CLI is available
    if command -v claude &> /dev/null; then
        echo ""
        echo -e "${BLUE}Launching Claude Code to diagnose the issue...${NC}"
        echo ""

        # Find the README.md (might be in the repo if cloned, or fetch from GitHub)
        local readme_path=""
        if [ -f "$INSTALL_DIR/README.md" ]; then
            readme_path="$INSTALL_DIR/README.md"
        elif [ -f "README.md" ]; then
            readme_path="README.md"
        fi

        # Create a prompt for Claude
        local prompt="The Vibe Check installation script failed with exit code $exit_code at line $line_number.

Please analyze the installation log below and the project README to diagnose what went wrong and suggest how to fix it.

Installation log:
\`\`\`
$(cat "$INSTALL_LOG")
\`\`\`
"

        # Pass the prompt to Claude (pipe to avoid shell escaping issues)
        echo "$prompt" | claude
    else
        echo ""
        echo -e "${YELLOW}Tip: Install Claude Code CLI to get automatic error diagnosis:${NC}"
        echo -e "${YELLOW}   https://claude.com/claude-code${NC}"
        echo ""
        echo -e "${BLUE}You can manually share this log with Claude Code:${NC}"
        echo -e "${BLUE}   cat $INSTALL_LOG${NC}"
    fi

    exit $exit_code
}

# Set up error trap
trap 'handle_error $LINENO' ERR
set -e

# Parse command line arguments
SKIP_AUTH=false
for arg in "$@"; do
    case $arg in
        --skip-auth) SKIP_AUTH=true ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Detect OS and package manager
detect_os() {
    OS="unknown"
    PKG_MANAGER="unknown"

    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        if command -v brew &> /dev/null; then
            PKG_MANAGER="brew"
            echo -e "${YELLOW}Note: For macOS with Homebrew, consider using:${NC}"
            echo -e "${YELLOW}  brew tap wanderingstan/vibe-check && brew install vibe-check${NC}"
            echo ""
        fi
    elif [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|pop|linuxmint|elementary)
                OS="debian"
                PKG_MANAGER="apt"
                ;;
            fedora|rhel|centos|rocky|alma)
                OS="fedora"
                PKG_MANAGER="dnf"
                ;;
            arch|manjaro|endeavouros)
                OS="arch"
                PKG_MANAGER="pacman"
                ;;
            opensuse*|sles)
                OS="suse"
                PKG_MANAGER="zypper"
                ;;
            *)
                OS="linux"
                ;;
        esac
    fi
}

# Show platform-specific hints for installing python3-venv
show_venv_hint() {
    echo -e "${YELLOW}Hint: Install the Python venv module:${NC}"
    case "$PKG_MANAGER" in
        apt)
            echo -e "${YELLOW}  sudo apt install python3-venv${NC}"
            ;;
        dnf)
            echo -e "${YELLOW}  sudo dnf install python3${NC}"
            ;;
        pacman)
            echo -e "${YELLOW}  sudo pacman -S python${NC}"
            ;;
        zypper)
            echo -e "${YELLOW}  sudo zypper install python3${NC}"
            ;;
        brew)
            echo -e "${YELLOW}  brew install python3${NC}"
            ;;
        *)
            echo -e "${YELLOW}  Install python3-venv using your package manager${NC}"
            ;;
    esac
}

# Show platform-specific hints for missing dependencies
show_install_hint() {
    local pkg="$1"
    echo -e "${YELLOW}Hint: Install $pkg:${NC}"
    case "$PKG_MANAGER" in
        apt)
            echo -e "${YELLOW}  sudo apt install $pkg${NC}"
            ;;
        dnf)
            echo -e "${YELLOW}  sudo dnf install $pkg${NC}"
            ;;
        pacman)
            echo -e "${YELLOW}  sudo pacman -S $pkg${NC}"
            ;;
        zypper)
            echo -e "${YELLOW}  sudo zypper install $pkg${NC}"
            ;;
        brew)
            echo -e "${YELLOW}  brew install $pkg${NC}"
            ;;
        *)
            echo -e "${YELLOW}  Install $pkg using your package manager${NC}"
            ;;
    esac
}

# Detect OS early
detect_os

# Configuration
REPO_URL="https://github.com/wanderingstan/vibe-check"

# Check if we're running from within the git repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
RUNNING_FROM_REPO=false

if [ -n "$SCRIPT_DIR" ]; then
    # Check if we're in a git repo with vibe-check.py at parent level
    PARENT_DIR="$(dirname "$SCRIPT_DIR")"
    if [ -f "$PARENT_DIR/vibe-check.py" ] && [ -d "$PARENT_DIR/.git" ]; then
        RUNNING_FROM_REPO=true
        INSTALL_DIR="$PARENT_DIR"
        echo -e "${BLUE}Running from git repo: $INSTALL_DIR${NC}"
    else
        INSTALL_DIR="$HOME/.vibe-check"
    fi
else
    INSTALL_DIR="$HOME/.vibe-check"
fi

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════╗"
echo "║   Vibe Check Installer v1.1           ║"
echo "║   (non-Homebrew installation)         ║"
echo "╚═══════════════════════════════════════╝"
echo -e "${NC}"

# Check if Claude Code is installed
if [ ! -d "$HOME/.claude/projects" ]; then
    echo -e "${RED}✗ Claude Code does not appear to be installed.${NC}"
    echo ""
    echo -e "${YELLOW}Vibe Check monitors Claude Code conversations, so Claude Code${NC}"
    echo -e "${YELLOW}must be installed and used at least once before installing.${NC}"
    echo ""
    echo -e "${BLUE}To install Claude Code:${NC}"
    echo -e "  https://code.claude.com/docs/en/quickstart"
    echo ""
    echo -e "${BLUE}After installing, run Claude Code at least once, then re-run this installer.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Claude Code detected${NC}"

# Check if already installed
if [ -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}⚠ Vibe Check is already installed at $INSTALL_DIR${NC}"
    echo -e "${BLUE}Updating to latest version...${NC}"

    cd "$INSTALL_DIR"

    # Update from git (skip if running from repo - user manages their own git)
    if [ "$RUNNING_FROM_REPO" = true ]; then
        echo -e "${GREEN}✓ Using repo directly (run 'git pull' to update)${NC}"
    elif [ -d ".git" ]; then
        # Stash any local changes before pulling
        if ! git diff --quiet 2>/dev/null; then
            echo -e "${YELLOW}⚠ Local changes detected, stashing...${NC}"
            git stash --quiet
        fi
        if ! git pull --quiet origin main; then
            echo -e "${RED}✗ Failed to update from GitHub${NC}"
            echo -e "${YELLOW}Try: cd $INSTALL_DIR && git pull origin main${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ Code updated from GitHub${NC}"
    else
        echo -e "${RED}✗ Not a git repository, cannot update${NC}"
        exit 1
    fi

    # Check if venv exists and is valid
    if [ ! -f "venv/bin/activate" ]; then
        echo -e "${YELLOW}⚠ Virtual environment missing or invalid, recreating...${NC}"
        rm -rf venv  # Clean up any partial/corrupted venv
        if ! python3 -m venv venv; then
            echo -e "${RED}✗ Failed to create virtual environment${NC}"
            show_venv_hint
            exit 1
        fi
        echo -e "${GREEN}✓ Virtual environment created${NC}"
    fi

    # Update dependencies
    echo -e "${BLUE}Updating Python dependencies...${NC}"
    source venv/bin/activate
    if ! pip install --quiet --upgrade pip || ! pip install --quiet -r requirements.txt; then
        echo -e "${RED}✗ Failed to install Python dependencies${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Dependencies updated${NC}"

    # Check if config.json exists (unified location: ~/.vibe-check/)
    CONFIG_FILE="$HOME/.vibe-check/config.json"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}⚠ Configuration file missing, need to authenticate...${NC}"
        NEED_AUTH=true
    else
        # Check if already authenticated
        API_KEY=$(grep -o '"api_key":"[^"]*' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f4)
        if [ -z "$API_KEY" ] || [ "$API_KEY" = "" ]; then
            echo -e "${YELLOW}⚠ Not authenticated, need to login...${NC}"
            NEED_AUTH=true
        else
            NEED_AUTH=false
            echo ""
            echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
            echo -e "${GREEN}║   Update Complete!                    ║${NC}"
            echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
            echo ""

            # Restart the service to pick up updates
            echo -e "${BLUE}Restarting service...${NC}"
            "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/vibe-check.py" restart 2>/dev/null || \
                "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/vibe-check.py" start 2>/dev/null || true

            # Show current status
            echo ""
            echo -e "${BLUE}Current status:${NC}"
            "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/vibe-check.py" status
            echo ""
            rm -f "$INSTALL_LOG"
            exit 0
        fi
    fi
fi

# Only do fresh install steps if venv doesn't exist
if [ ! -d "$INSTALL_DIR/venv" ]; then
    NEED_AUTH=true

    # Check dependencies
    echo -e "${BLUE}Checking dependencies...${NC}"

    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}✗ Python 3 is not installed.${NC}"
        show_install_hint "python3"
        exit 1
    fi

    # Only need git and curl if not running from repo
    if [ "$RUNNING_FROM_REPO" != true ]; then
        if ! command -v git &> /dev/null; then
            echo -e "${RED}✗ Git is not installed.${NC}"
            show_install_hint "git"
            exit 1
        fi

        if ! command -v curl &> /dev/null; then
            echo -e "${RED}✗ curl is not installed.${NC}"
            show_install_hint "curl"
            exit 1
        fi
    fi

    echo -e "${GREEN}✓ All dependencies found${NC}"

    # Clone repository (only if not running from repo)
    if [ "$RUNNING_FROM_REPO" != true ]; then
        echo -e "${BLUE}Creating installation directory...${NC}"
        mkdir -p "$INSTALL_DIR"

        echo -e "${BLUE}Cloning repository...${NC}"
        git clone "$REPO_URL" "$INSTALL_DIR" --quiet
    fi

    # Set up Python virtual environment
    echo -e "${BLUE}Setting up Python virtual environment...${NC}"
    cd "$INSTALL_DIR"
    if ! python3 -m venv venv; then
        echo -e "${RED}✗ Failed to create virtual environment${NC}"
        show_venv_hint
        exit 1
    fi

    # Activate virtual environment and install dependencies
    echo -e "${BLUE}Installing Python dependencies...${NC}"
    source venv/bin/activate
    if ! pip install --quiet --upgrade pip || ! pip install --quiet -r requirements.txt; then
        echo -e "${RED}✗ Failed to install Python dependencies${NC}"
        exit 1
    fi
fi

# Create wrapper script for vibe-check command
echo -e "${BLUE}Setting up vibe-check command...${NC}"
VIBE_CHECK_BIN="$INSTALL_DIR/vibe-check"

# Create wrapper script that uses the correct install dir
cat > "$VIBE_CHECK_BIN" <<WRAPPER
#!/bin/bash
INSTALL_DIR="$INSTALL_DIR"
source "\$INSTALL_DIR/venv/bin/activate"
exec python "\$INSTALL_DIR/vibe-check.py" "\$@"
WRAPPER
chmod +x "$VIBE_CHECK_BIN"

# Add to PATH if needed (skip for repo installs - developers manage their own PATH)
PATH_ADDED_TO_CONFIG=false
if [ "$RUNNING_FROM_REPO" != true ]; then
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        echo -e "${YELLOW}Adding $INSTALL_DIR to your PATH...${NC}"

        # Detect shell config file
        SHELL_CONFIG=""
        if [ -f "$HOME/.zshrc" ]; then
            SHELL_CONFIG="$HOME/.zshrc"
        elif [ -f "$HOME/.bashrc" ]; then
            SHELL_CONFIG="$HOME/.bashrc"
        elif [ -f "$HOME/.bash_profile" ]; then
            SHELL_CONFIG="$HOME/.bash_profile"
        fi

        if [ -n "$SHELL_CONFIG" ]; then
            # Check if already in config
            if ! grep -q "/.vibe-check" "$SHELL_CONFIG" 2>/dev/null; then
                echo "" >> "$SHELL_CONFIG"
                echo "# Vibe Check" >> "$SHELL_CONFIG"
                echo "export PATH=\"\$HOME/.vibe-check:\$PATH\"" >> "$SHELL_CONFIG"
                echo -e "${GREEN}✓ Added to $SHELL_CONFIG${NC}"
                PATH_ADDED_TO_CONFIG=true
            fi
        fi

        # Also add to current session (helps if script is sourced)
        export PATH="$INSTALL_DIR:$PATH"
    fi
    echo -e "${GREEN}✓ vibe-check command available${NC}"
    if [ "$PATH_ADDED_TO_CONFIG" = true ]; then
        echo -e "${YELLOW}  To use 'vibe-check' command: source $SHELL_CONFIG${NC}"
        echo -e "${YELLOW}  Or run now with: $VIBE_CHECK_BIN${NC}"
    fi
else
    echo -e "${GREEN}✓ Run with: $INSTALL_DIR/vibe-check${NC}"
fi

# Authentication
if [ "$NEED_AUTH" = true ] && [ "$SKIP_AUTH" = false ]; then
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Authentication Required             ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}You need to authenticate to sync your conversations.${NC}"
    echo -e "${YELLOW}This will open a browser to complete login.${NC}"
    echo ""

    # Run the auth login flow
    cd "$INSTALL_DIR"
    source venv/bin/activate

    if python vibe-check.py auth login; then
        echo ""
        echo -e "${GREEN}✓ Authentication successful!${NC}"
    else
        echo ""
        echo -e "${YELLOW}⚠ Authentication skipped or failed.${NC}"
        echo -e "${YELLOW}  You can authenticate later with: vibe-check auth login${NC}"
    fi
elif [ "$SKIP_AUTH" = true ]; then
    echo -e "${YELLOW}⚠ Authentication skipped (--skip-auth)${NC}"
    echo -e "${YELLOW}  Authenticate later with: vibe-check auth login${NC}"
fi

# Set up auto-start service (skip for repo installs)
if [ "$RUNNING_FROM_REPO" != true ]; then
    if [ "$OS" = "macos" ]; then
        # macOS: Create launchd plist
        echo -e "${BLUE}Setting up auto-start service...${NC}"
        mkdir -p "$HOME/Library/LaunchAgents"

        cat > "$HOME/Library/LaunchAgents/com.vibecheck.monitor.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.vibecheck.monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/vibe-check</string>
        <string>start</string>
        <string>--foreground</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/.vibe-check/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.vibe-check/launchd.error.log</string>
</dict>
</plist>
PLIST

        # Ensure data directory exists
        mkdir -p "$HOME/.vibe-check"

        launchctl load "$HOME/Library/LaunchAgents/com.vibecheck.monitor.plist" 2>/dev/null || true
        echo -e "${GREEN}✓ LaunchAgent installed (starts on login)${NC}"

    elif command -v systemctl &> /dev/null; then
        # Linux: Create systemd user service
        echo -e "${BLUE}Setting up auto-start service...${NC}"
        mkdir -p "$HOME/.config/systemd/user"

        cat > "$HOME/.config/systemd/user/vibe-check.service" <<SERVICE
[Unit]
Description=Vibe Check - Claude Code Monitor
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/vibe-check start --foreground
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
SERVICE

        # Try systemd user service (may fail for root or without dbus session)
        SYSTEMD_STARTED=false
        if systemctl --user daemon-reload 2>/dev/null; then
            systemctl --user enable vibe-check 2>/dev/null || true
            if systemctl --user start vibe-check 2>/dev/null; then
                # Verify it actually started
                sleep 1
                if systemctl --user is-active vibe-check &>/dev/null; then
                    SYSTEMD_STARTED=true
                    echo -e "${GREEN}✓ Systemd service installed and started${NC}"
                fi
            fi
        fi

        if [ "$SYSTEMD_STARTED" = false ]; then
            echo -e "${YELLOW}⚠ Systemd user service not available (common for root or SSH sessions)${NC}"
            echo -e "${BLUE}Starting daemon directly...${NC}"
            "$VIBE_CHECK_BIN" start 2>/dev/null || true
            echo -e "${GREEN}✓ Service file installed for future logins${NC}"
        fi
    else
        # No systemd - just start the daemon directly
        echo -e "${BLUE}Starting daemon...${NC}"
        "$VIBE_CHECK_BIN" start 2>/dev/null || true
    fi
else
    # Repo install - start daemon directly (no auto-start service)
    echo -e "${BLUE}Starting daemon...${NC}"
    "$VIBE_CHECK_BIN" start 2>/dev/null || true

    echo ""
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║   ⚠️  No Auto-Start Service Configured                     ║${NC}"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}Running from git repo - auto-start service not installed.${NC}"
    echo -e "${YELLOW}The daemon is running now, but won't restart after reboot.${NC}"
    echo ""
    echo -e "${BLUE}Options:${NC}"
    echo -e "  1. Manual start each session: ${NC}$INSTALL_DIR/vibe-check start"
    echo -e "  2. Install normally (with auto-start):${NC}"
    echo -e "     curl -fsSL https://vibecheck.wanderingstan.com/install.sh | bash"
    echo ""
fi

# Install Claude Code skills
echo -e "${BLUE}Installing Claude Code skills...${NC}"
SKILLS_SRC="$INSTALL_DIR/skills"
SKILLS_DEST="$HOME/.claude/skills"

if [ -d "$SKILLS_SRC" ]; then
    mkdir -p "$SKILLS_DEST"

    # Copy skill directories (each skill is a directory with SKILL.md inside)
    for skill_dir in "$SKILLS_SRC"/*/; do
        skill_name=$(basename "$skill_dir")
        # Skip if not a directory or no SKILL.md inside
        if [ ! -d "$skill_dir" ] || [ ! -f "$skill_dir/SKILL.md" ]; then
            continue
        fi

        dest_dir="$SKILLS_DEST/$skill_name"
        # Backup existing skill directory if present
        if [ -d "$dest_dir" ]; then
            backup="$SKILLS_DEST/.backup-$(date +%s)-$skill_name"
            mv "$dest_dir" "$backup"
        fi
        # Also clean up old flat format if present
        if [ -f "$SKILLS_DEST/${skill_name}.md" ]; then
            rm "$SKILLS_DEST/${skill_name}.md"
        fi
        cp -r "$skill_dir" "$dest_dir"
    done

    echo -e "${GREEN}✓ Claude Code skills installed to ~/.claude/skills/${NC}"
else
    echo -e "${YELLOW}⚠ Skills directory not found, skipping skills installation${NC}"
fi

# Installation complete
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Installation Complete!              ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
echo ""

# Give daemon time to process existing files before showing status
sleep 2

# Show current status
echo -e "${BLUE}Current status:${NC}"
"$VIBE_CHECK_BIN" status
echo ""

if [ "$RUNNING_FROM_REPO" = true ]; then
    echo -e "${BLUE}Commands (from repo):${NC}"
    echo -e "  $INSTALL_DIR/vibe-check stop       # Stop monitoring"
    echo -e "  $INSTALL_DIR/vibe-check status     # Check status"
    echo -e "  $INSTALL_DIR/vibe-check logs       # View logs"
    echo -e "  $INSTALL_DIR/vibe-check auth login # Re-authenticate"
else
    echo -e "${BLUE}Commands:${NC}"
    echo -e "  vibe-check stop      # Stop monitoring"
    echo -e "  vibe-check status    # Check status"
    echo -e "  vibe-check logs      # View logs"
    echo -e "  vibe-check auth login # Re-authenticate"
fi
echo ""

rm -f "$INSTALL_LOG"
