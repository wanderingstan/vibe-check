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

# Check if we're running from within the git repo or a local copy
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
RUNNING_FROM_REPO=false
LOCAL_SOURCE_DIR=""

if [ -n "$SCRIPT_DIR" ]; then
    # Check if we're in a directory with vibe-check.py at parent level
    PARENT_DIR="$(dirname "$SCRIPT_DIR")"
    if [ -f "$PARENT_DIR/vibe-check.py" ] && [ -f "$PARENT_DIR/requirements.txt" ]; then
        if [ -d "$PARENT_DIR/.git" ]; then
            # Actual git repo - use it directly
            RUNNING_FROM_REPO=true
            INSTALL_DIR="$PARENT_DIR"
            echo -e "${BLUE}Running from git repo: $INSTALL_DIR${NC}"
        else
            # Local directory (e.g., tarball) - copy to standard location
            LOCAL_SOURCE_DIR="$PARENT_DIR"
            INSTALL_DIR="$HOME/.vibe-check"
            echo -e "${BLUE}Running from local directory: $LOCAL_SOURCE_DIR${NC}"
            echo -e "${BLUE}Will install to: $INSTALL_DIR${NC}"
        fi
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
    elif [ -n "$LOCAL_SOURCE_DIR" ]; then
        # Copy updated files from local directory
        echo -e "${BLUE}Updating files from local directory...${NC}"
        # Copy all files except venv, config, and database to preserve user data
        for item in "$LOCAL_SOURCE_DIR"/*; do
            basename_item=$(basename "$item")
            # Skip venv directories, config, database, and build artifacts
            if [[ "$basename_item" != "venv" && "$basename_item" != ".venv" && \
                  "$basename_item" != "config.json" && "$basename_item" != "vibe_check.db" && \
                  "$basename_item" != "__pycache__" && "$basename_item" != ".git" ]]; then
                cp -r "$item" "$INSTALL_DIR"/ 2>/dev/null || true
            fi
        done
        echo -e "${GREEN}✓ Files updated from local directory${NC}"
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

    # Get source files (clone from GitHub, copy from local dir, or use repo directly)
    if [ "$RUNNING_FROM_REPO" = true ]; then
        # Using git repo directly, no need to copy
        :
    elif [ -n "$LOCAL_SOURCE_DIR" ]; then
        # Copy from local directory (e.g., tarball)
        echo -e "${BLUE}Creating installation directory...${NC}"
        mkdir -p "$INSTALL_DIR"

        echo -e "${BLUE}Copying files from local directory...${NC}"
        # Copy files, excluding virtual environments and other build artifacts
        for item in "$LOCAL_SOURCE_DIR"/*; do
            basename_item=$(basename "$item")
            # Skip venv directories, Python cache, and build artifacts
            if [[ "$basename_item" != "venv" && "$basename_item" != ".venv" && \
                  "$basename_item" != "__pycache__" && "$basename_item" != "*.pyc" && \
                  "$basename_item" != ".git" ]]; then
                cp -r "$item" "$INSTALL_DIR"/ 2>/dev/null || true
            fi
        done
        echo -e "${GREEN}✓ Files copied${NC}"
    else
        # Clone from GitHub
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

# Run setup wizard
echo ""
echo -e "${BLUE}╔═══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Running Setup Wizard                ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════╝${NC}"
echo ""

cd "$INSTALL_DIR"
source venv/bin/activate

# Build setup flags
SETUP_FLAGS="--non-interactive"
if [ "$SKIP_AUTH" = true ]; then
    SETUP_FLAGS="$SETUP_FLAGS --skip-auth"
fi

# Run setup command
if python vibe-check.py setup $SETUP_FLAGS; then
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   Installation Complete!              ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    if [ "$RUNNING_FROM_REPO" = true ]; then
        echo -e "${BLUE}Commands (from repo):${NC}"
        echo -e "  $INSTALL_DIR/vibe-check status     # Check status"
        echo -e "  $INSTALL_DIR/vibe-check logs       # View logs"
        echo -e "  $INSTALL_DIR/vibe-check auth login # Re-authenticate"
    else
        echo -e "${BLUE}Commands:${NC}"
        echo -e "  vibe-check status      # Check status"
        echo -e "  vibe-check logs        # View logs"
        echo -e "  vibe-check auth login  # Re-authenticate"
    fi
    echo ""
else
    echo ""
    echo -e "${RED}╔═══════════════════════════════════════╗${NC}"
    echo -e "${RED}║   Setup incomplete                    ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}You can complete setup later with:${NC}"
    if [ "$RUNNING_FROM_REPO" = true ]; then
        echo -e "  $INSTALL_DIR/vibe-check setup"
    else
        echo -e "  vibe-check setup"
    fi
    echo ""
fi

rm -f "$INSTALL_LOG"
