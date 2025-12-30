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
        git pull --quiet origin main
        echo -e "${GREEN}✓ Code updated from GitHub${NC}"
    else
        echo -e "${RED}✗ Not a git repository, cannot update${NC}"
        exit 1
    fi

    # Update dependencies
    echo -e "${BLUE}Updating Python dependencies...${NC}"
    source venv/bin/activate
    pip install --quiet --upgrade pip
    pip install --quiet -r requirements.txt
    echo -e "${GREEN}✓ Dependencies updated${NC}"

    # Skip to the end (start monitoring)
    SKIP_BACKLOG="--skip-backlog"

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   Update Complete! 🎉                 ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}To start monitoring:${NC}"
    echo -e "  $INSTALL_DIR/start.sh"
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
    exit 0
fi

# Check dependencies
echo -e "${BLUE}Checking dependencies...${NC}"

if ! command -v git &> /dev/null; then
    echo -e "${RED}✗ Git is not installed. Please install git first.${NC}"
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo -e "${RED}✗ Python 3 is not installed. Please install Python 3 first.${NC}"
    exit 1
fi

if ! command -v curl &> /dev/null; then
    echo -e "${RED}✗ curl is not installed. Please install curl first.${NC}"
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
python3 -m venv venv

# Activate virtual environment and install dependencies
echo -e "${BLUE}Installing Python dependencies...${NC}"
source venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt

# Get username from user
echo ""
echo -e "${BLUE}Creating your API credentials...${NC}"
while true; do
    read -p "Enter your desired username: " USERNAME </dev/tty
    if [ -z "$USERNAME" ]; then
        echo -e "${RED}Username cannot be empty. Please try again.${NC}"
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
    "api_key": "$API_KEY"
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

# Make uninstall.sh easily accessible
chmod +x "$INSTALL_DIR/uninstall.sh"

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
