#!/bin/bash

# Vibe Check Installer
# Install via: curl -fsSL https://vibecheck.wanderingstan.com/install.sh | bash

set -e

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
INSTALL_DIR="$HOME/.vibe-check"
REPO_URL="https://github.com/wanderingstan/vibe-check"
API_URL="https://vibecheck.wanderingstan.com"

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════╗"
echo "║     Vibe Check Installer v1.0         ║"
echo "╚═══════════════════════════════════════╝"
echo -e "${NC}"

# Check if already installed
if [ -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}⚠ Vibe Check is already installed at $INSTALL_DIR${NC}"
    echo -e "${BLUE}Updating to latest version...${NC}"

    cd "$INSTALL_DIR"

    # Update from git
    if [ -d ".git" ]; then
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

    # Check if venv exists, create if missing
    if [ ! -d "venv" ]; then
        echo -e "${YELLOW}⚠ Virtual environment missing, creating...${NC}"
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

    # Check if config.json exists
    if [ ! -f "config.json" ]; then
        echo -e "${YELLOW}⚠ Configuration file missing, need to register...${NC}"
        SKIP_CLONE=true
        # Fall through to registration section
    else
        # Skip to the end (start monitoring)
        SKIP_BACKLOG="--skip-backlog"

        # Extract username from config for display (may be empty for old configs)
        USERNAME=$(grep -o '"username":"[^"]*' config.json 2>/dev/null | cut -d'"' -f4)

        echo ""
        echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   Update Complete! 🎉                 ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${BLUE}To start monitoring:${NC}"
        echo -e "  $INSTALL_DIR/start.sh"
        echo ""
        if [ -n "$USERNAME" ]; then
            echo -e "${BLUE}View your stats at:${NC}"
            echo -e "  https://vibecheck.wanderingstan.com/stats.php?user=$USERNAME"
            echo ""
        fi

        # Ask if user wants to start now
        read -p "Do you want to start monitoring now? (Y/n): " -n 1 -r </dev/tty
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo -e "${GREEN}Starting monitor...${NC}"
            echo ""
            exec "$INSTALL_DIR/start.sh" $SKIP_BACKLOG
        fi
        exit 0
    fi
fi

# Only do fresh install steps if not falling through from update
if [ "$SKIP_CLONE" != "true" ]; then
    # Check dependencies
    echo -e "${BLUE}Checking dependencies...${NC}"

    if ! command -v git &> /dev/null; then
        echo -e "${RED}✗ Git is not installed.${NC}"
        show_install_hint "git"
        exit 1
    fi

    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}✗ Python 3 is not installed.${NC}"
        show_install_hint "python3"
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        echo -e "${RED}✗ curl is not installed.${NC}"
        show_install_hint "curl"
        exit 1
    fi

    echo -e "${GREEN}✓ All dependencies found${NC}"

    # Create installation directory
    echo -e "${BLUE}Creating installation directory...${NC}"
    mkdir -p "$INSTALL_DIR"

    # Clone repository
    echo -e "${BLUE}Cloning repository...${NC}"
    git clone "$REPO_URL" "$INSTALL_DIR" --quiet

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

# Get username from user
echo ""
echo -e "${BLUE}Creating your API credentials...${NC}"
while true; do
    read -p "Enter your desired username: " USERNAME </dev/tty
    if [ -z "$USERNAME" ]; then
        echo -e "${RED}Username cannot be empty. Please try again.${NC}"
        continue
    fi
    # Sanitize username: only allow alphanumeric, underscore, hyphen
    if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}Username can only contain letters, numbers, underscores, and hyphens.${NC}"
        continue
    fi
    if [ ${#USERNAME} -gt 32 ]; then
        echo -e "${RED}Username must be 32 characters or less.${NC}"
        continue
    fi
    break
done

# Register user and get API key
echo -e "${BLUE}Registering user '$USERNAME'...${NC}"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/create-token" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$USERNAME\"}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "201" ]; then
    echo -e "${RED}✗ Failed to create API token${NC}"
    echo -e "${RED}Error: $BODY${NC}"
    exit 1
fi

API_KEY=$(echo "$BODY" | grep -o '"api_key":"[^"]*' | cut -d'"' -f4)

if [ -z "$API_KEY" ]; then
    echo -e "${RED}✗ Failed to extract API key from response${NC}"
    exit 1
fi

echo -e "${GREEN}✓ User registered successfully!${NC}"
echo -e "${GREEN}  Username: $USERNAME${NC}"
echo -e "${GREEN}  API Key: $API_KEY${NC}"

# Create config.json
echo -e "${BLUE}Creating configuration file...${NC}"
cat > "$INSTALL_DIR/config.json" <<EOF
{
  "api": {
    "url": "$API_URL",
    "api_key": "$API_KEY",
    "username": "$USERNAME"
  },
  "monitor": {
    "conversation_dir": "~/.claude/projects",
    "state_file": "state.json"
  }
}
EOF

echo -e "${GREEN}✓ Configuration saved to $INSTALL_DIR/config.json${NC}"

# Ask about skipping backlog
echo ""
read -p "Do you want to skip uploading existing conversation history? (Y/n): " -n 1 -r </dev/tty
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    SKIP_BACKLOG="--skip-backlog"
else
    SKIP_BACKLOG=""
fi

# Create a start script for convenience
cat > "$INSTALL_DIR/start.sh" <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
source venv/bin/activate
python monitor.py "$@"
EOF

chmod +x "$INSTALL_DIR/start.sh"

# Make uninstall.sh easily accessible (if it exists)
if [ -f "$INSTALL_DIR/uninstall.sh" ]; then
    chmod +x "$INSTALL_DIR/uninstall.sh"
fi

# Installation complete
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Installation Complete! 🎉           ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}To start monitoring:${NC}"
echo -e "  cd $INSTALL_DIR"
echo -e "  source venv/bin/activate"
echo -e "  python monitor.py $SKIP_BACKLOG"
echo ""
echo -e "${BLUE}Or use the convenience script:${NC}"
echo -e "  $INSTALL_DIR/start.sh $SKIP_BACKLOG"
echo ""
echo -e "${BLUE}To run in the background:${NC}"
echo -e "  nohup $INSTALL_DIR/start.sh $SKIP_BACKLOG > $INSTALL_DIR/monitor.log 2>&1 &"
echo ""
echo -e "${BLUE}View your stats at:${NC}"
echo -e "  ${BLUE}https://vibecheck.wanderingstan.com/stats.php?user=$USERNAME${NC}"
echo ""

# Ask if user wants to start now
read -p "Do you want to start monitoring now? (Y/n): " -n 1 -r </dev/tty
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    echo -e "${GREEN}Starting monitor...${NC}"
    echo ""
    exec "$INSTALL_DIR/start.sh" $SKIP_BACKLOG
fi
