#!/bin/bash
# =============================================================================
# Shellder Local GUI Launcher
# Automatically installs dependencies and starts the web GUI for local testing
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║          SHELLDER - Local GUI Launcher                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check for Python
if command -v python3 &>/dev/null; then
    PYTHON="python3"
elif command -v python &>/dev/null; then
    PYTHON="python"
else
    echo -e "${RED}[ERROR] Python not found. Please install Python 3.8+${NC}"
    exit 1
fi

echo -e "${GREEN}[✓]${NC} Using: $($PYTHON --version)"

# Check/install pip
if ! $PYTHON -m pip --version &>/dev/null; then
    echo -e "${YELLOW}[!]${NC} pip not found, attempting to install..."
    curl -sS https://bootstrap.pypa.io/get-pip.py | $PYTHON
fi

# Install requirements
echo -e "${CYAN}[...]${NC} Checking dependencies..."
if ! $PYTHON -c "import flask, flask_socketio, docker, psutil" 2>/dev/null; then
    echo -e "${YELLOW}[!]${NC} Installing required packages..."
    $PYTHON -m pip install -q -r requirements.txt
    echo -e "${GREEN}[✓]${NC} Dependencies installed"
else
    echo -e "${GREEN}[✓]${NC} Dependencies already installed"
fi

# Set environment for local testing (mock mode if Docker not available)
export SHELLDER_LOCAL_MODE=1
export SHELLDER_PORT=${SHELLDER_PORT:-5000}

# Check if port is already in use
if command -v lsof &>/dev/null && lsof -i:$SHELLDER_PORT &>/dev/null; then
    echo -e "${YELLOW}[!]${NC} Port $SHELLDER_PORT already in use"
    echo -e "${CYAN}[i]${NC} GUI may already be running at: http://localhost:$SHELLDER_PORT"
    
    # Try to open browser anyway
    if command -v xdg-open &>/dev/null; then
        xdg-open "http://localhost:$SHELLDER_PORT" 2>/dev/null &
    elif command -v open &>/dev/null; then
        open "http://localhost:$SHELLDER_PORT" 2>/dev/null &
    fi
    exit 0
fi

echo ""
echo -e "${GREEN}[✓]${NC} Starting Shellder GUI server..."
echo -e "${CYAN}[i]${NC} Dashboard: http://localhost:$SHELLDER_PORT"
echo -e "${CYAN}[i]${NC} Press Ctrl+C to stop"
echo ""

# Open browser after short delay (in background)
(
    sleep 2
    if command -v xdg-open &>/dev/null; then
        xdg-open "http://localhost:$SHELLDER_PORT" 2>/dev/null
    elif command -v open &>/dev/null; then
        open "http://localhost:$SHELLDER_PORT" 2>/dev/null
    fi
) &

# Start the server
$PYTHON shellder_service.py

