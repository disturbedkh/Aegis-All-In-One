#!/bin/bash
# =============================================================================
# Shellder GUI Launcher
# =============================================================================
# Launches the Shellder web-based control panel for Aegis AIO
#
# Usage:
#   ./shellderGUI.sh                - Start (Docker if available, else venv)
#   ./shellderGUI.sh --docker       - Force Docker mode
#   ./shellderGUI.sh --local        - Force local Python/venv mode
#   ./shellderGUI.sh --stop         - Stop GUI server
#   ./shellderGUI.sh --status       - Check if running
#   ./shellderGUI.sh --build        - Build Docker image
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
DIM='\033[2m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# Configuration
# NOTE: We use shellder_service.py for both modes as it's the unified server
# gui_server.py is deprecated and will be removed
GUI_SERVER="$SCRIPT_DIR/Shellder/shellder_service.py"
SERVICE_SERVER="$SCRIPT_DIR/Shellder/shellder_service.py"
PID_FILE="$SCRIPT_DIR/Shellder/.gui_pid"
LOG_FILE="$SCRIPT_DIR/Shellder/gui_server.log"
VENV_DIR="$SCRIPT_DIR/Shellder/.venv"
PORT=5000
CONTAINER_NAME="shellder"

# Mode: docker or local
RUN_MODE="auto"

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

# =============================================================================
# DOCKER MODE FUNCTIONS
# =============================================================================

check_docker() {
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        return 0
    fi
    return 1
}

docker_is_running() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        return 0
    fi
    return 1
}

build_docker_image() {
    echo -e "${CYAN}Building Shellder Docker image...${NC}"
    
    if [ ! -f "$SCRIPT_DIR/Shellder/Dockerfile" ]; then
        echo -e "${RED}Error: Dockerfile not found${NC}"
        return 1
    fi
    
    docker build -t shellder:latest "$SCRIPT_DIR/Shellder/"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Docker image built successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to build Docker image${NC}"
        return 1
    fi
}

start_docker() {
    echo -e "${CYAN}Starting Shellder via Docker...${NC}"
    
    # Check if image exists, build if not
    if ! docker images | grep -q "shellder.*latest"; then
        echo -e "${YELLOW}Shellder image not found, building...${NC}"
        build_docker_image || return 1
    fi
    
    # Start via docker compose
    if [ -f "$SCRIPT_DIR/docker-compose.yaml" ]; then
        docker compose up -d shellder
        
        if [ $? -eq 0 ]; then
            sleep 2
            if docker_is_running; then
                echo -e "${GREEN}✓ Shellder container started${NC}"
                return 0
            fi
        fi
    fi
    
    # Fallback: start container directly
    echo -e "${YELLOW}Trying direct container start...${NC}"
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p 5000:5000 \
        -v /var/run/docker.sock:/var/run/docker.sock:ro \
        -v "$SCRIPT_DIR:/aegis:ro" \
        -v "$SCRIPT_DIR/Shellder/data:/app/data" \
        -v "$SCRIPT_DIR/Shellder/logs:/app/logs" \
        -e SHELLDER_PORT=5000 \
        -e AEGIS_ROOT=/aegis \
        shellder:latest
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Shellder container started${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to start Shellder container${NC}"
        return 1
    fi
}

stop_docker() {
    echo -e "${CYAN}Stopping Shellder container...${NC}"
    
    if docker_is_running; then
        docker stop "$CONTAINER_NAME" 2>/dev/null
        docker rm "$CONTAINER_NAME" 2>/dev/null
        echo -e "${GREEN}✓ Container stopped${NC}"
    else
        echo -e "${YELLOW}Container not running${NC}"
    fi
}

show_docker_status() {
    if docker_is_running; then
        echo -e "${GREEN}● Shellder container is running${NC}"
        docker ps --filter "name=$CONTAINER_NAME" --format "  ID: {{.ID}}\n  Status: {{.Status}}\n  Ports: {{.Ports}}"
    else
        echo -e "${RED}● Shellder container is not running${NC}"
    fi
}

# =============================================================================
# LOCAL/VENV MODE FUNCTIONS
# =============================================================================

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
    
    local REQUIREMENTS_FILE="$SCRIPT_DIR/Shellder/requirements.txt"
    
    # Check ALL required modules from requirements.txt
    # If any are missing, reinstall from requirements.txt
    if ! "$PYTHON_CMD" -c "import flask, flask_socketio, docker, psutil, pymysql, toml, requests" 2>/dev/null; then
        echo -e "${YELLOW}Installing/updating dependencies...${NC}"
        "$PIP_CMD" install --upgrade pip -q 2>/dev/null
        
        # Install from requirements.txt for consistency
        if [ -f "$REQUIREMENTS_FILE" ]; then
            "$PIP_CMD" install -q -r "$REQUIREMENTS_FILE"
        else
            # Fallback if requirements.txt not found
            "$PIP_CMD" install flask flask-cors flask-socketio python-socketio eventlet requests psutil docker pymysql toml -q
        fi
        
        if [ $? -ne 0 ]; then
            echo -e "${RED}Failed to install dependencies${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ Dependencies installed${NC}"
    else
        echo -e "${GREEN}✓ Dependencies OK${NC}"
    fi
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
    # Determine mode
    if [ "$RUN_MODE" = "auto" ]; then
        if check_docker; then
            RUN_MODE="docker"
        else
            RUN_MODE="local"
        fi
    fi
    
    echo -e "${DIM}Mode: $RUN_MODE${NC}"
    echo ""
    
    if [ "$RUN_MODE" = "docker" ]; then
        # Docker mode
        if docker_is_running; then
            echo -e "${YELLOW}Shellder is already running (Docker)${NC}"
            show_access_info
            return
        fi
        start_docker && show_access_info
    else
        # Local/venv mode
        if is_running; then
            echo -e "${YELLOW}Shellder is already running (Local)${NC}"
            show_access_info
            return
        fi
        start_local
    fi
}

start_local() {
    check_python
    setup_venv
    check_dependencies
    
    echo -e "${CYAN}Starting Shellder GUI server (local mode)...${NC}"
    
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
    echo -e "${CYAN}Stopping Shellder...${NC}"
    
    # Stop Docker container if running
    if check_docker && docker_is_running; then
        stop_docker
    fi
    
    # Stop local process if running via PID file
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            kill "$pid" 2>/dev/null
            sleep 1
            if ps -p "$pid" > /dev/null 2>&1; then
                kill -9 "$pid" 2>/dev/null
            fi
            echo -e "${GREEN}✓ Local server stopped (PID: $pid)${NC}"
        fi
        rm -f "$PID_FILE"
    fi
    
    # Kill ANY process using port 5000 (catches orphaned processes)
    kill_port_process
    
    echo -e "${GREEN}✓ Shellder stopped${NC}"
}

kill_port_process() {
    # Try multiple methods to kill anything on the port
    
    # Method 1: fuser (most reliable on Linux)
    if command -v fuser &> /dev/null; then
        fuser -k $PORT/tcp 2>/dev/null && echo -e "${DIM}  Killed process via fuser${NC}"
    fi
    
    # Method 2: lsof + kill (backup)
    if command -v lsof &> /dev/null; then
        local pids=$(lsof -t -i:$PORT 2>/dev/null)
        if [ -n "$pids" ]; then
            echo "$pids" | xargs -r kill -9 2>/dev/null && echo -e "${DIM}  Killed process via lsof${NC}"
        fi
    fi
    
    # Method 3: ss + kill (another backup)
    if command -v ss &> /dev/null; then
        local pid=$(ss -tlnp 2>/dev/null | grep ":$PORT " | grep -oP 'pid=\K\d+' | head -1)
        if [ -n "$pid" ]; then
            kill -9 "$pid" 2>/dev/null && echo -e "${DIM}  Killed process via ss${NC}"
        fi
    fi
    
    # Small delay to let OS release the port
    sleep 0.5
}

show_status() {
    local running=false
    
    # Check Docker
    if check_docker && docker_is_running; then
        echo -e "${GREEN}● Shellder is running (Docker)${NC}"
        show_docker_status
        running=true
    fi
    
    # Check local
    if is_running; then
        echo -e "${GREEN}● Shellder is running (Local)${NC}"
        if [ -f "$PID_FILE" ]; then
            echo "  PID: $(cat "$PID_FILE")"
        fi
        running=true
    fi
    
    if [ "$running" = true ]; then
        show_access_info
    else
        echo -e "${RED}● Shellder is not running${NC}"
        echo ""
        echo "  Start with: ./shellderGUI.sh"
        echo ""
        echo "  Options:"
        echo "    ./shellderGUI.sh --docker  Start via Docker (recommended)"
        echo "    ./shellderGUI.sh --local   Start via local Python/venv"
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
    echo -e "${WHITE}Start Commands:${NC}"
    echo "  (none)      Auto-detect: Docker if available, else local venv"
    echo "  --docker    Force Docker container mode (recommended)"
    echo "  --local     Force local Python/venv mode"
    echo ""
    echo -e "${WHITE}Management Commands:${NC}"
    echo "  --stop      Stop the server (both Docker and local)"
    echo "  --status    Show server status"
    echo "  --restart   Restart the server"
    echo "  --build     Build/rebuild Docker image"
    echo "  --logs      Show container logs (Docker mode)"
    echo "  --help      Show this help"
    echo ""
    echo -e "${WHITE}Features:${NC}"
    echo "  • Real-time container monitoring"
    echo "  • Live Xilriws proxy statistics"
    echo "  • Log streaming and aggregation"
    echo "  • Start/stop/restart Docker services"
    echo "  • WebSocket for live updates"
    echo ""
    echo -e "${WHITE}Access:${NC}"
    echo "  Local:   http://localhost:5000"
    echo "  Network: http://<your-ip>:5000"
    echo ""
}

show_logs() {
    if check_docker && docker_is_running; then
        echo -e "${CYAN}Shellder container logs:${NC}"
        docker logs -f --tail 100 "$CONTAINER_NAME"
    else
        if [ -f "$LOG_FILE" ]; then
            echo -e "${CYAN}Shellder local logs:${NC}"
            tail -f "$LOG_FILE"
        else
            echo -e "${YELLOW}No logs found${NC}"
        fi
    fi
}

# =============================================================================
# MAIN
# =============================================================================

show_banner

case "${1:-}" in
    --docker|-d)
        RUN_MODE="docker"
        if ! check_docker; then
            echo -e "${RED}Error: Docker is not available${NC}"
            echo "  Install Docker or use --local mode"
            exit 1
        fi
        start_server
        ;;
    --local|-l)
        RUN_MODE="local"
        start_server
        ;;
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
    --build|-b)
        if check_docker; then
            build_docker_image
        else
            echo -e "${RED}Error: Docker is not available${NC}"
            exit 1
        fi
        ;;
    --logs)
        show_logs
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

