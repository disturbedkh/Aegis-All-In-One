#!/bin/bash
# =============================================================================
# Shellder GUI Launcher
# =============================================================================
# Launches the Shellder web-based control panel for Aegis AIO
#
# Usage:
#   ./shellderGUI.sh           - Start GUI server
#   ./shellderGUI.sh --stop    - Stop GUI server
#   ./shellderGUI.sh --status  - Check if running
#
# Access the GUI at: http://localhost:5000
# Or from network:   http://<your-ip>:5000
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# Configuration
GUI_SERVER="$SCRIPT_DIR/Shellder/gui_server.py"
PID_FILE="$SCRIPT_DIR/Shellder/.gui_pid"
LOG_FILE="$SCRIPT_DIR/Shellder/gui_server.log"
VENV_DIR="$SCRIPT_DIR/Shellder/.venv"
PORT=5000

# =============================================================================
# FUNCTIONS
# =============================================================================

show_banner() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                    ${WHITE}SHELLDER GUI${NC}                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}        Web-based Control Panel for Aegis AIO                  ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

check_python() {
    if command -v python3 &> /dev/null; then
        PYTHON_CMD="python3"
    elif command -v python &> /dev/null; then
        PYTHON_CMD="python"
    else
        echo -e "${RED}Error: Python is not installed${NC}"
        echo "  Install Python 3:"
        echo "    sudo apt install python3 python3-venv"
        exit 1
    fi
}

setup_venv() {
    echo -e "${CYAN}Setting up Python virtual environment...${NC}"
    
    # Check if python3-venv is available
    if ! $PYTHON_CMD -m venv --help &>/dev/null; then
        echo -e "${YELLOW}Installing python3-venv...${NC}"
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y python3-venv python3-full -qq
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y python3-virtualenv -q
        elif command -v yum &>/dev/null; then
            sudo yum install -y python3-virtualenv -q
        fi
    fi
    
    # Create venv if it doesn't exist
    if [ ! -d "$VENV_DIR" ]; then
        echo -e "${CYAN}Creating virtual environment...${NC}"
        $PYTHON_CMD -m venv "$VENV_DIR"
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to create virtual environment${NC}"
            echo "  Try: sudo apt install python3-venv python3-full"
            exit 1
        fi
    fi
    
    # Set the Python command to use venv
    PYTHON_CMD="$VENV_DIR/bin/python"
    PIP_CMD="$VENV_DIR/bin/pip"
    
    echo -e "${GREEN}✓ Virtual environment ready${NC}"
}

check_dependencies() {
    echo -e "${CYAN}Checking dependencies...${NC}"
    
    # Check if Flask is installed in venv
    if ! "$PYTHON_CMD" -c "import flask" 2>/dev/null; then
        echo -e "${YELLOW}Installing Flask...${NC}"
        "$PIP_CMD" install --upgrade pip -q 2>/dev/null
        "$PIP_CMD" install flask flask-cors -q
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to install Flask${NC}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}✓ Dependencies OK${NC}"
}

is_running() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        fi
    fi
    
    # Also check if port is in use
    if command -v lsof &> /dev/null; then
        if lsof -i :$PORT > /dev/null 2>&1; then
            return 0
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tuln | grep -q ":$PORT "; then
            return 0
        fi
    fi
    
    return 1
}

get_local_ip() {
    # Try to get the local IP address
    local ip=""
    
    if command -v hostname &> /dev/null; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    
    if [ -z "$ip" ] && command -v ip &> /dev/null; then
        ip=$(ip route get 1 2>/dev/null | awk '{print $7}' | head -1)
    fi
    
    echo "${ip:-localhost}"
}

start_server() {
    if is_running; then
        echo -e "${YELLOW}Shellder GUI is already running${NC}"
        show_access_info
        return
    fi
    
    check_python
    setup_venv
    check_dependencies
    
    echo -e "${CYAN}Starting Shellder GUI server...${NC}"
    
    # Start server in background using venv python
    nohup "$PYTHON_CMD" "$GUI_SERVER" > "$LOG_FILE" 2>&1 &
    local pid=$!
    echo $pid > "$PID_FILE"
    
    # Wait a moment for server to start
    sleep 2
    
    # Check if it started successfully
    if ps -p $pid > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Server started successfully (PID: $pid)${NC}"
        show_access_info
    else
        echo -e "${RED}✗ Failed to start server${NC}"
        echo "  Check log file: $LOG_FILE"
        cat "$LOG_FILE" 2>/dev/null | tail -20
        rm -f "$PID_FILE"
        exit 1
    fi
}

stop_server() {
    echo -e "${CYAN}Stopping Shellder GUI server...${NC}"
    
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            kill "$pid" 2>/dev/null
            sleep 1
            if ps -p "$pid" > /dev/null 2>&1; then
                kill -9 "$pid" 2>/dev/null
            fi
        fi
        rm -f "$PID_FILE"
    fi
    
    # Also try to kill by port
    if command -v fuser &> /dev/null; then
        fuser -k $PORT/tcp 2>/dev/null
    fi
    
    echo -e "${GREEN}✓ Server stopped${NC}"
}

show_status() {
    if is_running; then
        echo -e "${GREEN}● Shellder GUI is running${NC}"
        if [ -f "$PID_FILE" ]; then
            echo "  PID: $(cat "$PID_FILE")"
        fi
        show_access_info
    else
        echo -e "${RED}● Shellder GUI is not running${NC}"
        echo ""
        echo "  Start with: ./shellderGUI.sh"
    fi
}

show_access_info() {
    local ip=$(get_local_ip)
    echo ""
    echo -e "${WHITE}Access the dashboard:${NC}"
    echo -e "  Local:   ${CYAN}http://localhost:$PORT${NC}"
    echo -e "  Network: ${CYAN}http://$ip:$PORT${NC}"
    echo ""
    echo -e "${WHITE}Commands:${NC}"
    echo "  ./shellderGUI.sh --stop    Stop the server"
    echo "  ./shellderGUI.sh --status  Check status"
    echo ""
}

show_help() {
    show_banner
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  (none)     Start the GUI server"
    echo "  --stop     Stop the GUI server"
    echo "  --status   Show server status"
    echo "  --restart  Restart the server"
    echo "  --help     Show this help"
    echo ""
    echo "The GUI provides a web-based dashboard for:"
    echo "  • Monitoring container status"
    echo "  • Starting/stopping Docker services"
    echo "  • Viewing logs"
    echo "  • Managing updates"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

show_banner

case "${1:-}" in
    --stop|-s)
        stop_server
        ;;
    --status|-t)
        show_status
        ;;
    --restart|-r)
        stop_server
        sleep 1
        start_server
        ;;
    --help|-h)
        show_help
        ;;
    "")
        start_server
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        echo "Use --help for usage information"
        exit 1
        ;;
esac

