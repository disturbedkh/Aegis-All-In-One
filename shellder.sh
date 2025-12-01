#!/bin/bash

# =============================================================================
# Shellder 1.0 - Main Control Panel for Aegis AIO
# =============================================================================
# This is the main entry point for managing your Aegis AIO ecosystem
# and its Unown# stack.
# It provides:
#   - System status overview
#   - Quick access to all management scripts
#   - Update checking
#   - Help and documentation
# =============================================================================

VERSION="1.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Get the original user who called sudo (to prevent files being locked to root)
# This is critical - we need to pass this to sub-scripts
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    REAL_GROUP=$(id -gn "$SUDO_USER")
else
    REAL_USER="$USER"
    REAL_GROUP=$(id -gn)
fi

# Export for sub-scripts to inherit
export REAL_USER
export REAL_GROUP

# Source Shellder database helper for config management
if [ -f "$SCRIPT_DIR/Shellder/db_helper.sh" ]; then
    source "$SCRIPT_DIR/Shellder/db_helper.sh"
    DB_AVAILABLE=true
else
    DB_AVAILABLE=false
fi

# Source Shellder logging helper
SHELLDER_SCRIPT_NAME="shellder.sh"
if [ -f "$SCRIPT_DIR/Shellder/log_helper.sh" ]; then
    source "$SCRIPT_DIR/Shellder/log_helper.sh"
    LOG_AVAILABLE=true
else
    LOG_AVAILABLE=false
fi

# Track config alerts shown this session to avoid repetition
CONFIG_ALERT_SHOWN=false

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

draw_logo() {
    echo -e "${CYAN}"
    echo '   _____ __         ____    __         '
    echo '  / ___// /_  ___  / / /___/ /__  _____'
    echo '  \__ \/ __ \/ _ \/ / / __  / _ \/ ___/'
    echo ' ___/ / / / /  __/ / / /_/ /  __/ /    '
    echo '/____/_/ /_/\___/_/_/\__,_/\___/_/     '
    echo '                                        '
    echo -e "${NC}"
    echo -e "${DIM}      Shellder v${VERSION} for Aegis AIO${NC}"
    echo -e "${DIM}           By The Pokemod Group${NC}"
    echo ""
}

draw_box_top() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
}

draw_box_bottom() {
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
}

draw_box_divider() {
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════════════════╣${NC}"
}

draw_box_line() {
    printf "${CYAN}║${NC} %-72s ${CYAN}║${NC}\n" "$1"
}

print_status() {
    local label=$1
    local status=$2
    local color=$3
    printf "  %-25s ${color}%s${NC}\n" "$label" "$status"
}

press_enter() {
    echo ""
    read -p "Press Enter to continue..."
}

# =============================================================================
# DETECTION FUNCTIONS
# =============================================================================

# Check if Docker is installed and running
check_docker() {
    if command -v docker &> /dev/null; then
        if docker info &> /dev/null; then
            echo "running"
        else
            echo "installed"
        fi
    else
        echo "missing"
    fi
}

# Check if Docker Compose is available
check_docker_compose() {
    if docker compose version &> /dev/null; then
        echo "plugin"
    elif command -v docker-compose &> /dev/null; then
        echo "standalone"
    else
        echo "missing"
    fi
}

# Check if MariaDB/MySQL is installed (local or Docker)
check_mariadb() {
    # Check Docker container first
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        local db_status=$(docker ps --filter "name=^database$" --format "{{.Status}}" 2>/dev/null)
        if [ -n "$db_status" ] && [[ "$db_status" == *"Up"* ]]; then
            echo "docker"
            return
        fi
    fi
    
    # Check local installation
    if command -v mysql &> /dev/null; then
        if systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysql 2>/dev/null; then
            echo "local"
        else
            echo "installed"
        fi
    else
        echo "missing"
    fi
}

# Check if a script exists
check_script() {
    local script=$1
    if [ -f "$SCRIPT_DIR/Shellder/$script" ]; then
        echo "found"
    else
        echo "missing"
    fi
}

# Check git repo status
check_git_updates() {
    if [ ! -d ".git" ]; then
        echo "not_repo"
        return
    fi
    
    # Fetch updates silently
    git fetch origin 2>/dev/null
    
    local local_hash=$(git rev-parse HEAD 2>/dev/null)
    local remote_hash=$(git rev-parse origin/main 2>/dev/null || git rev-parse origin/master 2>/dev/null)
    
    if [ -z "$remote_hash" ]; then
        echo "unknown"
    elif [ "$local_hash" = "$remote_hash" ]; then
        echo "up_to_date"
    else
        local behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || git rev-list --count HEAD..origin/master 2>/dev/null)
        echo "behind:${behind:-?}"
    fi
}

# Count running containers
count_containers() {
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        local running=$(docker ps --filter "name=database\|golbat\|dragonite\|rotom\|reactmap\|koji\|admin\|grafana\|pma\|xilriws\|poracle\|fletchling\|victoriametrics\|vmagent" --format "{{.Names}}" 2>/dev/null | wc -l)
        local total=$(docker ps -a --filter "name=database\|golbat\|dragonite\|rotom\|reactmap\|koji\|admin\|grafana\|pma\|xilriws\|poracle\|fletchling\|victoriametrics\|vmagent" --format "{{.Names}}" 2>/dev/null | wc -l)
        echo "${running}/${total}"
    else
        echo "N/A"
    fi
}

# Get quick container summary for main dashboard
get_container_summary() {
    if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
        echo "docker_unavailable"
        return
    fi
    
    local containers=("database" "reactmap" "dragonite" "admin" "golbat" "rotom" "koji" "pma" "grafana" "victoriametrics" "vmagent" "xilriws")
    local running=0
    local stopped=0
    local missing=0
    
    for container in "${containers[@]}"; do
        local status=$(docker ps -a --filter "name=^${container}$" --format "{{.Status}}" 2>/dev/null)
        if [ -z "$status" ]; then
            ((missing++))
        elif [[ "$status" == *"Up"* ]]; then
            ((running++))
        else
            ((stopped++))
        fi
    done
    
    echo "${running}:${stopped}:${missing}"
}

# Check if .env exists and is configured
check_env() {
    if [ -f ".env" ]; then
        if grep -q "SuperSecure\|CHANGE_ME\|V3ryS3cUr3" .env 2>/dev/null; then
            echo "unconfigured"
        else
            echo "configured"
        fi
    else
        echo "missing"
    fi
}

# Check if Nginx is configured
check_nginx() {
    if command -v nginx &> /dev/null; then
        if [ -f "/etc/nginx/sites-enabled/aegis-reactmap" ] || [ -f "/etc/nginx/sites-enabled/aegis-admin" ]; then
            echo "configured"
        else
            echo "installed"
        fi
    else
        echo "missing"
    fi
}

# =============================================================================
# STATUS DASHBOARD
# =============================================================================

show_status_dashboard() {
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                        SYSTEM STATUS"
    draw_box_bottom
    echo ""

    # Core Components
    echo -e "${WHITE}${BOLD}Core Components${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    
    # Docker
    local docker_status=$(check_docker)
    case $docker_status in
        "running")
            print_status "Docker:" "Running" "$GREEN"
            local docker_ver=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            print_status "  Version:" "$docker_ver" "$DIM"
            ;;
        "installed")
            print_status "Docker:" "Installed (not running)" "$YELLOW"
            ;;
        *)
            print_status "Docker:" "Not installed" "$RED"
            ;;
    esac

    # Docker Compose
    local compose_status=$(check_docker_compose)
    case $compose_status in
        "plugin")
            local compose_ver=$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            print_status "Docker Compose:" "v$compose_ver (plugin)" "$GREEN"
            ;;
        "standalone")
            print_status "Docker Compose:" "Standalone" "$GREEN"
            ;;
        *)
            print_status "Docker Compose:" "Not installed" "$RED"
            ;;
    esac

    # MariaDB
    local mariadb_status=$(check_mariadb)
    case $mariadb_status in
        "docker")
            print_status "MariaDB:" "Running (Docker)" "$GREEN"
            ;;
        "local")
            print_status "MariaDB:" "Running (Local)" "$GREEN"
            ;;
        "installed")
            print_status "MariaDB:" "Installed (not running)" "$YELLOW"
            ;;
        *)
            print_status "MariaDB:" "Not detected" "$DIM"
            ;;
    esac

    # Containers - Enhanced display
    local container_summary=$(get_container_summary)
    if [ "$container_summary" != "docker_unavailable" ]; then
        local running=$(echo $container_summary | cut -d: -f1)
        local stopped=$(echo $container_summary | cut -d: -f2)
        local missing=$(echo $container_summary | cut -d: -f3)
        local installed=$((running + stopped))
        local total=$((installed + missing))
        
        if [ "$running" -eq "$installed" ] && [ "$installed" -gt 0 ]; then
            print_status "Containers:" "${running}/${installed} running" "$GREEN"
        elif [ "$running" -gt 0 ]; then
            print_status "Containers:" "${running}/${installed} running" "$YELLOW"
            if [ "$stopped" -gt 0 ]; then
                print_status "  Stopped:" "$stopped container(s)" "$RED"
            fi
        elif [ "$installed" -gt 0 ]; then
            print_status "Containers:" "0/${installed} running" "$RED"
        else
            print_status "Containers:" "Not deployed" "$DIM"
        fi
        
        if [ "$missing" -gt 0 ] && [ "$installed" -gt 0 ]; then
            print_status "  Not deployed:" "$missing service(s)" "$DIM"
        fi
    fi

    echo ""

    # Configuration
    echo -e "${WHITE}${BOLD}Configuration${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    
    # .env file
    local env_status=$(check_env)
    case $env_status in
        "configured")
            print_status ".env File:" "Configured" "$GREEN"
            ;;
        "unconfigured")
            print_status ".env File:" "Needs configuration" "$YELLOW"
            ;;
        *)
            print_status ".env File:" "Missing (run setup.sh)" "$RED"
            ;;
    esac

    # Nginx
    local nginx_status=$(check_nginx)
    case $nginx_status in
        "configured")
            print_status "Nginx:" "Configured for Aegis" "$GREEN"
            ;;
        "installed")
            print_status "Nginx:" "Installed (not configured)" "$YELLOW"
            ;;
        *)
            print_status "Nginx:" "Not installed" "$DIM"
            ;;
    esac

    echo ""

    # Available Scripts
    echo -e "${WHITE}${BOLD}Available Scripts${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    
    local scripts=("setup.sh" "dbsetup.sh" "check.sh" "logs.sh" "nginx-setup.sh" "poracle.sh" "fletchling.sh")
    local script_count=0
    local missing_count=0
    
    for script in "${scripts[@]}"; do
        if [ -f "$SCRIPT_DIR/Shellder/$script" ]; then
            ((script_count++))
        else
            ((missing_count++))
        fi
    done
    
    if [ $missing_count -eq 0 ]; then
        print_status "Scripts:" "All $script_count scripts available" "$GREEN"
    else
        print_status "Scripts:" "$script_count available, $missing_count missing" "$YELLOW"
    fi

    echo ""

    # Repository Status
    echo -e "${WHITE}${BOLD}Repository${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    
    local git_status=$(check_git_updates)
    case $git_status in
        "up_to_date")
            print_status "Updates:" "Up to date" "$GREEN"
            ;;
        behind:*)
            local count=$(echo $git_status | cut -d: -f2)
            print_status "Updates:" "$count update(s) available" "$YELLOW"
            ;;
        "not_repo")
            print_status "Updates:" "Not a git repository" "$DIM"
            ;;
        *)
            print_status "Updates:" "Unable to check" "$DIM"
            ;;
    esac
    
    if [ -d ".git" ]; then
        local branch=$(git branch --show-current 2>/dev/null)
        local commit=$(git rev-parse --short HEAD 2>/dev/null)
        print_status "  Branch:" "$branch ($commit)" "$DIM"
    fi
    
    # Quick Image Update Check (only for running containers)
    local image_status=$(quick_check_image_updates)
    if [ "$image_status" != "none" ]; then
        print_status "Images:" "$image_status" "$YELLOW"
    fi

    echo ""
}

# Quick check for image updates (fast, checks key services only)
quick_check_image_updates() {
    # Only check if Docker is running
    if ! docker info &> /dev/null; then
        echo "none"
        return
    fi
    
    # Key services to check (most frequently updated)
    local key_services=("dragonite" "golbat" "rotom" "reactmap" "xilriws")
    local updates_available=0
    local checked=0
    
    for service in "${key_services[@]}"; do
        # Check if container exists
        local container_exists=$(docker ps -a --filter "name=^${service}$" --format "{{.Names}}" 2>/dev/null)
        if [ -z "$container_exists" ]; then
            continue
        fi
        
        # Get the image used by the container
        local image=$(docker inspect --format='{{.Config.Image}}' "$service" 2>/dev/null)
        if [ -z "$image" ]; then
            continue
        fi
        
        ((checked++))
        
        # Compare local image creation time with what we'd get from a pull
        # This is a quick heuristic - check if image is older than 7 days
        local created=$(docker inspect --format='{{.Created}}' "$image" 2>/dev/null | cut -d'T' -f1)
        if [ -n "$created" ]; then
            local created_epoch=$(date -d "$created" +%s 2>/dev/null || echo "0")
            local now_epoch=$(date +%s)
            local age_days=$(( (now_epoch - created_epoch) / 86400 ))
            
            if [ "$age_days" -gt 7 ]; then
                ((updates_available++))
            fi
        fi
    done
    
    if [ "$updates_available" -gt 0 ]; then
        echo "${updates_available} image(s) may have updates (press 'v' to check)"
    else
        echo "none"
    fi
}

# =============================================================================
# SHELLDER GUI MANAGEMENT
# =============================================================================

shellder_gui_menu() {
    while true; do
        clear
        draw_logo
        
        draw_box_top
        draw_box_line "                    SHELLDER WEB DASHBOARD"
        draw_box_bottom
        echo ""
        
        # Check if Docker container is running
        local docker_status="${RED}●${NC} Not running"
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^shellder$"; then
            docker_status="${GREEN}●${NC} Running (Docker)"
        fi
        
        # Check if local process is running
        local local_status="${RED}●${NC} Not running"
        local pid_file="$SCRIPT_DIR/Shellder/.gui_pid"
        if [ -f "$pid_file" ] && ps -p "$(cat "$pid_file")" > /dev/null 2>&1; then
            local_status="${GREEN}●${NC} Running (PID: $(cat "$pid_file"))"
        fi
        
        echo -e "  ${WHITE}${BOLD}Status${NC}"
        echo -e "  ${DIM}────────────────────────────────────────────────────────────────${NC}"
        echo -e "    Docker Container: $docker_status"
        echo -e "    Local Process:    $local_status"
        echo ""
        echo -e "  ${WHITE}Access:${NC} ${CYAN}http://localhost:5000${NC}"
        echo ""
        
        echo -e "  ${WHITE}${BOLD}Actions${NC}"
        echo -e "  ${DIM}────────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo -e "    ${CYAN}Docker Mode (Recommended)${NC}"
        echo "    1) Start Shellder (Docker container)"
        echo "    2) Stop Shellder (Docker container)"
        echo "    3) Restart Shellder (Docker)"
        echo "    4) View Shellder logs (Docker)"
        echo "    5) Build/Rebuild Docker image"
        echo ""
        echo -e "    ${CYAN}Local Mode (Alternative)${NC}"
        echo "    6) Start Shellder (Local Python/venv)"
        echo "    7) Stop Shellder (Local)"
        echo ""
        echo -e "    ${CYAN}Configuration${NC}"
        echo "    n) Configure Nginx (External Access)"
        echo ""
        echo "    0) Back to Main Menu"
        echo ""
        read -p "  Select option: " choice
        
        case $choice in
            1)
                echo ""
                print_info "Starting Shellder via Docker..."
                docker compose up -d shellder
                if [ $? -eq 0 ]; then
                    print_success "Shellder container started"
                    echo ""
                    echo -e "  Access at: ${CYAN}http://localhost:5000${NC}"
                else
                    print_error "Failed to start Shellder container"
                fi
                press_enter
                ;;
            2)
                echo ""
                print_info "Stopping Shellder container..."
                docker compose stop shellder
                docker compose rm -f shellder 2>/dev/null
                print_success "Shellder container stopped"
                press_enter
                ;;
            3)
                echo ""
                print_info "Restarting Shellder container..."
                docker compose restart shellder
                print_success "Shellder container restarted"
                press_enter
                ;;
            4)
                echo ""
                echo -e "${CYAN}Shellder container logs (Ctrl+C to exit):${NC}"
                docker logs -f --tail 100 shellder 2>/dev/null || echo "Container not running"
                ;;
            5)
                echo ""
                print_info "Building Shellder Docker image..."
                docker compose build shellder
                if [ $? -eq 0 ]; then
                    print_success "Docker image built successfully"
                else
                    print_error "Failed to build Docker image"
                fi
                press_enter
                ;;
            6)
                echo ""
                print_info "Starting Shellder locally..."
                bash "$SCRIPT_DIR/shellderGUI.sh" --local
                press_enter
                ;;
            7)
                echo ""
                print_info "Stopping local Shellder..."
                bash "$SCRIPT_DIR/shellderGUI.sh" --stop
                press_enter
                ;;
            n|N)
                echo ""
                print_info "Opening Nginx setup for Shellder GUI..."
                echo "  Navigate to: Site Management → Setup Shellder GUI"
                sleep 2
                run_script "nginx-setup.sh" "Security Setup & Management"
                ;;
            0|"") return ;;
        esac
    done
}

# =============================================================================
# MAIN MENU
# =============================================================================

show_main_menu() {
    echo -e "${WHITE}${BOLD}Main Menu${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}Setup & Configuration${NC}"
    echo "    1) Initial Setup          - First-time setup, passwords, configs"
    echo "    2) Database Setup & Management  - DB setup, maintenance, user management"
    echo "    3) Security Setup & Management  - Nginx, SSL, firewall, authentication"
    echo ""
    echo -e "  ${CYAN}Monitoring & Maintenance${NC}"
    echo "    4) System Check           - Validate configs, check health"
    echo "    5) Log Manager            - View, analyze, and manage logs"
    echo ""
    echo -e "  ${CYAN}Optional Features${NC}"
    echo "    6) Poracle Setup          - Discord/Telegram notifications"
    echo "    7) Fletchling Setup       - Pokemon nest detection"
    echo ""
    echo -e "  ${CYAN}File Management${NC}"
    echo "    8) File Manager           - Manage files, restore from GitHub"
    echo ""
    echo -e "  ${CYAN}Web Dashboard${NC}"
    echo "    9) Shellder GUI           - Web-based control panel (port 5000)"
    echo ""
    echo -e "  ${CYAN}Stack Controls${NC}"
    echo "    s) Start Stack            - Start all containers"
    echo "    x) Stop Stack             - Stop all containers"
    echo "    t) Restart Stack          - Restart all containers"
    echo "    b) Force Rebuild          - Rebuild containers from scratch"
    echo "    c) Container Status       - View docker compose status"
    echo "    v) Container Dashboard    - Detailed status + image check"
    echo ""
    echo -e "  ${CYAN}Service Management${NC}"
    echo "    +) Start Service(s)       - Start individual services"
    echo "    -) Stop Service(s)        - Stop individual services"
    echo "    *) Restart Service(s)     - Restart individual services"
    echo ""
    echo -e "  ${CYAN}Updates & Images${NC}"
    echo "    i) Pull Images Only       - Pull latest images (no restart)"
    echo "    p) Pull Latest            - Git pull latest changes"
    echo "    u) Update & Rebuild       - Pull, rebuild, and restart stack"
    echo ""
    echo -e "  ${CYAN}Maintenance & Cleanup${NC}"
    echo "    d) Docker Purge           - Clean up Docker resources"
    echo "    z) Uninstall Stack        - Remove Aegis stack"
    echo ""
    echo -e "  ${CYAN}Other${NC}"
    echo "    h) Help & Documentation"
    echo "    r) Refresh Status"
    echo "    0) Exit"
    echo ""
}

# =============================================================================
# HELP SYSTEM
# =============================================================================

show_help() {
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                      HELP & DOCUMENTATION"
    draw_box_bottom
    echo ""

    echo -e "${WHITE}${BOLD}Script Descriptions${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    echo -e "${CYAN}1) Initial Setup (setup.sh)${NC}"
    echo "   First-time setup wizard that:"
    echo "   • Installs Docker and Docker Compose if needed"
    echo "   • Generates secure random passwords"
    echo "   • Creates configuration files from templates"
    echo "   • Tunes MariaDB for your hardware"
    echo "   • Creates databases and users"
    echo ""
    
    echo -e "${CYAN}2) Database Setup & Management (dbsetup.sh)${NC}"
    echo "   Two modes: Setup and Maintenance"
    echo "   Setup Mode:"
    echo "   • Install/configure MariaDB"
    echo "   • Create databases and users"
    echo "   • Performance tuning"
    echo "   Maintenance Mode:"
    echo "   • Clean up banned/invalid accounts"
    echo "   • Remove stale map data"
    echo "   • Manage nests"
    echo "   • Create missing databases/users"
    echo "   • Optimize and repair tables"
    echo ""
    
    echo -e "${CYAN}3) Security Setup & Management (nginx-setup.sh)${NC}"
    echo "   Secures your installation for external access:"
    echo "   • Nginx reverse proxy (subdomain or path routing)"
    echo "   • SSL certificates (Let's Encrypt)"
    echo "   • Authentication (Basic Auth or Authelia SSO)"
    echo "   • Fail2Ban intrusion prevention"
    echo "   • UFW firewall configuration"
    echo "   • Docker port security"
    echo ""
    
    press_enter
    
    clear
    draw_logo
    
    echo -e "${CYAN}4) System Check (check.sh)${NC}"
    echo "   Interactive status and validation tool:"
    echo "   • Status dashboard (Docker, MariaDB, containers)"
    echo "   • Configuration validation"
    echo "   • Password/secret alignment checking"
    echo "   • File and endpoint verification"
    echo "   • Port status checking"
    echo ""
    
    echo -e "${CYAN}5) Log Manager (logs.sh)${NC}"
    echo "   Comprehensive log analysis tool:"
    echo "   • Service status with error counts"
    echo "   • Error categorization (account, DB, connection, etc.)"
    echo "   • Search functionality (device disconnects, etc.)"
    echo "   • Log maintenance (clear, rotate)"
    echo "   • Docker daemon configuration"
    echo ""
    
    echo -e "${CYAN}6) Poracle Setup (poracle.sh)${NC}"
    echo "   Sets up Discord/Telegram alert notifications:"
    echo "   • Pokemon spawn alerts"
    echo "   • Raid notifications"
    echo "   • Quest alerts"
    echo "   • Configurable filters"
    echo ""
    
    echo -e "${CYAN}7) Fletchling Setup (fletchling.sh)${NC}"
    echo "   Enables Pokemon nest detection:"
    echo "   • Imports park data from OpenStreetMap"
    echo "   • Automatic nest detection"
    echo "   • ReactMap integration"
    echo "   Prerequisite: Create Koji project first"
    echo ""

    echo -e "${WHITE}${BOLD}Stack Controls${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  s) Start Stack    - docker compose up -d"
    echo "  x) Stop Stack     - docker compose stop (preserves containers)"
    echo "  t) Restart Stack  - docker compose restart"
    echo "  b) Force Rebuild  - docker compose up -d --force-recreate --build"
    echo "                      Pulls images, rebuilds containers from scratch"
    echo "  c) Status         - docker compose ps -a"
    echo "  v) Dashboard      - Detailed container status + image info"
    echo ""

    echo -e "${WHITE}${BOLD}Service Management${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  +) Start Service(s)   - Interactive menu to start individual services"
    echo "  -) Stop Service(s)    - Interactive menu to stop individual services"
    echo "  *) Restart Service(s) - Interactive menu to restart individual services"
    echo ""
    echo "  Select multiple services using comma-separated numbers (e.g., 1,3,5)"
    echo ""

    echo -e "${WHITE}${BOLD}Updates & Images${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  i) Pull Images      - Pull latest Docker images without restarting"
    echo "                        (Use to download updates before applying them)"
    echo "  p) Pull Latest      - Git pull latest changes only"
    echo "  u) Update & Rebuild - Pull changes, rebuild containers, restart stack"
    echo ""

    echo -e "${WHITE}${BOLD}Maintenance & Cleanup${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  d) Docker Purge     - Clean up Docker resources (containers, images,"
    echo "                        volumes, networks). Multiple cleanup options."
    echo "  z) Uninstall Stack  - Remove Aegis stack from system"
    echo "                        • Light: Keep configs, remove containers"
    echo "                        • Full: Reset configs, remove data"
    echo "                        • Complete: Delete entire directory"
    echo ""

    echo -e "${WHITE}${BOLD}Quick Tips${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  • First time? Run option 1 (Initial Setup) first"
    echo "  • Having issues? Run option 4 (System Check)"
    echo "  • Logs filling up? Run option 5 (Log Manager)"
    echo "  • Going public? Run option 3 (Security Setup & Management)"
    echo ""
    
    press_enter
}

# =============================================================================
# UPDATE FUNCTIONS
# =============================================================================

# Git pull only
git_pull() {
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                      GIT PULL"
    draw_box_bottom
    echo ""

    if [ ! -d ".git" ]; then
        echo -e "${YELLOW}This directory is not a git repository.${NC}"
        echo "To enable updates, clone the repository using git:"
        echo ""
        echo "  git clone https://github.com/disturbedkh/Aegis-All-In-One.git"
        echo ""
        press_enter
        return
    fi

    local branch=$(git branch --show-current 2>/dev/null)
    echo -e "Current branch: ${CYAN}$branch${NC}"
    echo ""
    
    local had_changes=false
    local stash_name="shellder-stash-$(date +%Y%m%d-%H%M%S)"
    
    # First check for unmerged files (from previous failed merge/pull)
    local unmerged=$(git ls-files --unmerged 2>/dev/null | wc -l)
    if [ "$unmerged" -gt 0 ]; then
        echo -e "${YELLOW}━━━ Detected Unresolved Merge Conflicts ━━━${NC}"
        echo ""
        echo -e "${DIM}Unmerged files:${NC}"
        git diff --name-only --diff-filter=U 2>/dev/null | head -5
        echo ""
        echo -e "${CYAN}Automatically resolving by keeping your local versions...${NC}"
        
        # For each unmerged file, accept local version
        git diff --name-only --diff-filter=U 2>/dev/null | while read file; do
            if [ -n "$file" ]; then
                git checkout --ours "$file" 2>/dev/null
                git add "$file" 2>/dev/null
            fi
        done
        
        # Complete the merge if we were in merge state
        if [ -f ".git/MERGE_HEAD" ]; then
            git commit -m "Auto-resolved merge conflicts (kept local configs)" --no-edit 2>/dev/null || true
        fi
        echo -e "${GREEN}✓ Conflicts resolved${NC}"
        echo ""
    fi
    
    # Check for local changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        had_changes=true
        
        echo -e "${CYAN}━━━ Detected Local Configuration Changes ━━━${NC}"
        echo ""
        echo -e "${DIM}Modified files:${NC}"
        git status --short | head -10
        local changed_count=$(git status --short | wc -l)
        [ "$changed_count" -gt 10 ] && echo -e "${DIM}  ... and $((changed_count - 10)) more${NC}"
        echo ""
        
        echo -e "${WHITE}These are your config customizations from setup.sh${NC}"
        echo -e "${GREEN}✓ Don't worry - they will be automatically preserved!${NC}"
        echo ""
        
        # Stage all changes first (required for stash to work with some files)
        git add -A 2>/dev/null
        
        # Auto-stash with a named stash
        echo -e "${CYAN}Temporarily saving your configs...${NC}"
        git stash push -m "$stash_name" --quiet 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Configs saved${NC}"
        else
            # Try alternative: stash with --include-untracked
            git stash push -m "$stash_name" --include-untracked --quiet 2>&1
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ Configs saved${NC}"
            else
                # Last resort: reset and let user know
                echo -e "${YELLOW}⚠ Could not stash changes automatically.${NC}"
                echo ""
                echo "Your local configs are in a complex state."
                echo "Options:"
                echo "  1. Run: ${CYAN}git reset --hard origin/$branch${NC} (loses local changes)"
                echo "  2. Manually backup your config files and re-run setup.sh"
                echo ""
                press_enter
                return
            fi
        fi
        echo ""
    fi

    echo -e "${CYAN}Pulling latest updates from GitHub...${NC}"
    echo ""
    git pull origin $branch 2>&1
    local pull_result=$?
    
    if [ $pull_result -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✓ Updates downloaded successfully!${NC}"
        
        # Restore stashed changes if we had any
        if [ "$had_changes" = true ]; then
            echo ""
            echo -e "${CYAN}Restoring your configs...${NC}"
            
            # Try to pop the stash
            git stash pop --quiet 2>&1
            local pop_result=$?
            
            if [ $pop_result -eq 0 ]; then
                echo -e "${GREEN}✓ Your configs have been restored!${NC}"
            else
                # There might be conflicts - try to show helpful info
                echo ""
                echo -e "${YELLOW}⚠ Some configs may have conflicts with new updates.${NC}"
                echo ""
                echo "Your original configs are safely stored in git stash."
                echo "To restore manually: ${CYAN}git stash pop${NC}"
                echo ""
                echo "If you see conflicts, you can either:"
                echo "  1. Edit the conflicting files to merge changes"
                echo "  2. Run setup.sh again to reconfigure"
                echo "  3. Use ${CYAN}git checkout -- <file>${NC} to use new version"
            fi
        fi
        
        echo ""
        echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "${GREEN}${BOLD}Update complete!${NC}"
        echo ""
        echo "Tip: Run 'Update & Rebuild' (option u) to apply container updates"
    else
        echo ""
        echo -e "${RED}Pull failed!${NC}"
        
        # Restore stash if we had changes
        if [ "$had_changes" = true ]; then
            echo ""
            echo -e "${CYAN}Restoring your configs...${NC}"
            git stash pop --quiet 2>/dev/null
            echo -e "${GREEN}✓ Configs restored${NC}"
        fi
        
        echo ""
        echo "Possible causes:"
        echo "  • No internet connection"
        echo "  • GitHub is unreachable"
        echo "  • Branch conflict"
    fi
    
    press_enter
}

# Full update: pull, rebuild, restart
update_and_rebuild() {
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                UPDATE & REBUILD STACK"
    draw_box_bottom
    echo ""

    if [ ! -d ".git" ]; then
        echo -e "${YELLOW}This directory is not a git repository.${NC}"
        press_enter
        return
    fi

    echo "This will:"
    echo "  1. Pull latest changes from git (your configs will be preserved)"
    echo "  2. Stop running containers"
    echo "  3. Rebuild containers with new images"
    echo "  4. Start the stack"
    echo ""
    
    read -p "Continue? (y/n) [n]: " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        return
    fi

    local branch=$(git branch --show-current 2>/dev/null)
    local had_changes=false
    local stash_name="shellder-stash-$(date +%Y%m%d-%H%M%S)"
    
    # Step 1: Pull
    echo ""
    echo -e "${CYAN}Step 1/4: Pulling latest changes...${NC}"
    
    # Check for local changes and auto-stash
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        had_changes=true
        echo -e "${DIM}Saving your config customizations...${NC}"
        git stash push -m "$stash_name" --quiet
        echo -e "${GREEN}✓ Configs saved${NC}"
    fi
    
    git pull origin $branch 2>&1
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Pull failed. Aborting.${NC}"
        # Restore stash
        if [ "$had_changes" = true ]; then
            git stash pop --quiet 2>/dev/null
        fi
        press_enter
        return
    fi
    
    # Restore configs after pull
    if [ "$had_changes" = true ]; then
        echo -e "${DIM}Restoring your configs...${NC}"
        git stash pop --quiet 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Configs restored${NC}"
        else
            echo -e "${YELLOW}⚠ Some config conflicts - may need manual review${NC}"
        fi
    fi
    
    # Step 2: Stop
    echo ""
    echo -e "${CYAN}Step 2/4: Stopping containers...${NC}"
    docker compose down
    
    # Step 3: Rebuild
    echo ""
    echo -e "${CYAN}Step 3/4: Rebuilding containers...${NC}"
    docker compose build --pull
    
    # Step 4: Start
    echo ""
    echo -e "${CYAN}Step 4/4: Starting stack...${NC}"
    docker compose up -d
    
    echo ""
    echo -e "${GREEN}✓ Update and rebuild complete!${NC}"
    echo ""
    
    # Show status
    echo "Container status:"
    docker compose ps
    
    press_enter
}

# Check for updates (info only)
check_updates() {
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                      UPDATE CHECK"
    draw_box_bottom
    echo ""

    if [ ! -d ".git" ]; then
        echo -e "${YELLOW}This directory is not a git repository.${NC}"
        echo "To enable updates, clone the repository using git:"
        echo ""
        echo "  git clone https://github.com/disturbedkh/Aegis-All-In-One.git"
        echo ""
        press_enter
        return
    fi

    echo "Checking for updates..."
    echo ""
    
    # Fetch updates
    git fetch origin 2>/dev/null
    
    local local_hash=$(git rev-parse HEAD 2>/dev/null)
    local remote_hash=$(git rev-parse origin/main 2>/dev/null || git rev-parse origin/master 2>/dev/null)
    local branch=$(git branch --show-current 2>/dev/null)
    
    echo -e "Current branch: ${CYAN}$branch${NC}"
    echo -e "Local commit:   ${DIM}$local_hash${NC}"
    echo -e "Remote commit:  ${DIM}$remote_hash${NC}"
    echo ""

    if [ "$local_hash" = "$remote_hash" ]; then
        echo -e "${GREEN}✓ You are up to date!${NC}"
    else
        local behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || git rev-list --count HEAD..origin/master 2>/dev/null)
        echo -e "${YELLOW}! $behind update(s) available${NC}"
        echo ""
        
        echo "Recent changes:"
        git log --oneline HEAD..origin/main 2>/dev/null | head -10 || git log --oneline HEAD..origin/master 2>/dev/null | head -10
        echo ""
        
        echo "Options:"
        echo "  p) Pull Latest       - Just pull changes"
        echo "  u) Update & Rebuild  - Pull, rebuild, restart"
        echo "  0) Back"
        echo ""
        read -p "Select: " choice
        
        case $choice in
            p|P) git_pull ;;
            u|U) update_and_rebuild ;;
        esac
        return
    fi
    
    press_enter
}

# =============================================================================
# DOCKER CONTROLS
# =============================================================================

# List of all Aegis stack services with their image names
# Format: "container_name:description:image_name"
AEGIS_SERVICES_FULL=(
    "database:MariaDB Database:mariadb:latest"
    "reactmap:ReactMap Web UI:ghcr.io/watwowmap/reactmap:main"
    "dragonite:Dragonite Scanner:ghcr.io/unownhash/dragonite-public:latest"
    "admin:Dragonite Admin UI:ghcr.io/unownhash/dragonite-public-admin:latest"
    "golbat:Golbat Data Parser:ghcr.io/unownhash/golbat:main"
    "rotom:Rotom Device Manager:ghcr.io/unownhash/rotom:main"
    "koji:Koji Geofence Manager:ghcr.io/turtiesocks/koji:main"
    "pma:phpMyAdmin:phpmyadmin:latest"
    "grafana:Grafana Statistics:grafana/grafana:latest"
    "victoriametrics:VictoriaMetrics DB:victoriametrics/victoria-metrics:latest"
    "vmagent:VictoriaMetrics Agent:victoriametrics/vmagent:latest"
    "xilriws:Xilriws Anti-Bot:ghcr.io/unownhash/xilriws:main"
    "poracle:Poracle Notifications:ghcr.io/kartuludus/poraclejs:develop"
    "fletchling:Fletchling Nests:ghcr.io/unownhash/fletchling:latest"
)

# List of all Aegis stack services
AEGIS_SERVICES=(
    "database:MariaDB Database"
    "reactmap:ReactMap Web UI"
    "dragonite:Dragonite Scanner"
    "admin:Dragonite Admin UI"
    "golbat:Golbat Data Parser"
    "rotom:Rotom Device Manager"
    "koji:Koji Geofence Manager"
    "pma:phpMyAdmin"
    "grafana:Grafana Statistics"
    "victoriametrics:VictoriaMetrics DB"
    "vmagent:VictoriaMetrics Agent"
    "xilriws:Xilriws Anti-Bot"
    "poracle:Poracle Notifications"
    "fletchling:Fletchling Nests"
)

# =============================================================================
# IMAGE UPDATE CHECKING
# =============================================================================

# Check if a local image is up to date with remote
# Returns: "up_to_date", "update_available", "not_pulled", or "unknown"
check_image_update() {
    local image=$1
    
    # Check if image exists locally
    local local_digest=$(docker images --digests --format "{{.Digest}}" "$image" 2>/dev/null | head -1)
    
    if [ -z "$local_digest" ] || [ "$local_digest" = "<none>" ]; then
        echo "not_pulled"
        return
    fi
    
    # Try to get remote digest (this requires network access)
    # Use docker manifest inspect for accurate comparison
    local remote_digest=$(docker manifest inspect "$image" 2>/dev/null | grep -m1 '"digest"' | cut -d'"' -f4)
    
    if [ -z "$remote_digest" ]; then
        echo "unknown"
        return
    fi
    
    if [ "$local_digest" = "$remote_digest" ]; then
        echo "up_to_date"
    else
        echo "update_available"
    fi
}

# Get detailed container info
get_container_info() {
    local container=$1
    local info=$(docker ps -a --filter "name=^${container}$" --format "{{.Status}}|{{.Image}}|{{.CreatedAt}}" 2>/dev/null)
    echo "$info"
}

# Show detailed container status dashboard
show_container_dashboard() {
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                    CONTAINER STATUS DASHBOARD"
    draw_box_bottom
    echo ""
    
    echo -e "${WHITE}${BOLD}Checking container and image status...${NC}"
    echo ""
    
    # Header
    printf "  ${WHITE}%-18s %-10s %-12s %-15s${NC}\n" "SERVICE" "STATUS" "INSTALLED" "IMAGE STATUS"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────${NC}"
    
    local updates_available=0
    local not_running=0
    local not_installed=0
    
    for service_entry in "${AEGIS_SERVICES_FULL[@]}"; do
        local container_name=$(echo "$service_entry" | cut -d: -f1)
        local service_desc=$(echo "$service_entry" | cut -d: -f2)
        local image_name=$(echo "$service_entry" | cut -d: -f3-)
        
        # Get container status
        local container_info=$(docker ps -a --filter "name=^${container_name}$" --format "{{.Status}}" 2>/dev/null)
        local container_exists=$(docker ps -a --filter "name=^${container_name}$" --format "{{.Names}}" 2>/dev/null)
        
        # Determine running status
        local status_icon status_text
        if [ -z "$container_exists" ]; then
            status_icon="${DIM}○${NC}"
            status_text="${DIM}--${NC}"
            installed_text="${DIM}No${NC}"
            ((not_installed++))
        elif [[ "$container_info" == *"Up"* ]]; then
            status_icon="${GREEN}●${NC}"
            status_text="${GREEN}Running${NC}"
            installed_text="${GREEN}Yes${NC}"
        else
            status_icon="${RED}●${NC}"
            status_text="${RED}Stopped${NC}"
            installed_text="${YELLOW}Yes${NC}"
            ((not_running++))
        fi
        
        # Check image status (only if container exists or we want to show all)
        local image_status_text
        if [ -n "$container_exists" ]; then
            # Quick check - just see if image exists locally
            local local_image=$(docker images -q "$image_name" 2>/dev/null)
            if [ -z "$local_image" ]; then
                image_status_text="${DIM}Not pulled${NC}"
            else
                # For speed, just show "Pulled" - full update check is slow
                image_status_text="${CYAN}Pulled${NC}"
            fi
        else
            image_status_text="${DIM}--${NC}"
        fi
        
        printf "  ${status_icon} %-16s %-18b %-20b %-15b\n" "$service_desc" "$status_text" "$installed_text" "$image_status_text"
    done
    
    echo ""
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────${NC}"
    
    # Summary
    local total=${#AEGIS_SERVICES_FULL[@]}
    local installed=$((total - not_installed))
    local running=$((installed - not_running))
    
    echo ""
    printf "  ${WHITE}Summary:${NC} %d/%d installed, %d/%d running\n" "$installed" "$total" "$running" "$installed"
    echo ""
    
    echo -e "  ${CYAN}Options:${NC}"
    echo "    i) Check for image updates (slow - queries registries)"
    echo "    p) Pull all latest images"
    echo "    0) Back to main menu"
    echo ""
    
    read -p "  Select option: " choice
    
    case $choice in
        i|I)
            check_all_image_updates
            ;;
        p|P)
            docker_pull_images
            ;;
        0|"")
            return
            ;;
        *)
            show_container_dashboard
            ;;
    esac
}

# Check all images for updates (slow operation)
check_all_image_updates() {
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                    CHECKING IMAGE UPDATES"
    draw_box_bottom
    echo ""
    
    echo -e "${YELLOW}Checking registries for updates... This may take a minute.${NC}"
    echo ""
    
    printf "  ${WHITE}%-25s %-20s %-20s${NC}\n" "IMAGE" "LOCAL" "STATUS"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────────${NC}"
    
    local updates_count=0
    
    for service_entry in "${AEGIS_SERVICES_FULL[@]}"; do
        local container_name=$(echo "$service_entry" | cut -d: -f1)
        local service_desc=$(echo "$service_entry" | cut -d: -f2)
        local image_name=$(echo "$service_entry" | cut -d: -f3-)
        
        # Show we're checking
        printf "  Checking %-40s\r" "$service_desc..."
        
        # Get local image info
        local local_created=$(docker images --format "{{.CreatedSince}}" "$image_name" 2>/dev/null | head -1)
        
        if [ -z "$local_created" ]; then
            printf "  %-25s %-20s ${DIM}%-20s${NC}\n" "$service_desc" "Not pulled" "--"
            continue
        fi
        
        # Check for updates
        local update_status=$(check_image_update "$image_name")
        
        case $update_status in
            "up_to_date")
                printf "  %-25s %-20s ${GREEN}%-20s${NC}\n" "$service_desc" "$local_created" "Up to date"
                ;;
            "update_available")
                printf "  %-25s %-20s ${YELLOW}%-20s${NC}\n" "$service_desc" "$local_created" "Update available"
                ((updates_count++))
                ;;
            "not_pulled")
                printf "  %-25s %-20s ${DIM}%-20s${NC}\n" "$service_desc" "Not pulled" "--"
                ;;
            *)
                printf "  %-25s %-20s ${DIM}%-20s${NC}\n" "$service_desc" "$local_created" "Unknown"
                ;;
        esac
    done
    
    echo ""
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    if [ $updates_count -gt 0 ]; then
        echo -e "  ${YELLOW}$updates_count update(s) available${NC}"
        echo ""
        read -p "  Pull updates now? (y/n) [n]: " pull_now
        if [ "$pull_now" = "y" ] || [ "$pull_now" = "Y" ]; then
            docker_pull_images
            return
        fi
    else
        echo -e "  ${GREEN}All images are up to date!${NC}"
    fi
    
    press_enter
}

# Pull all images without starting containers
docker_pull_images() {
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                    PULL LATEST IMAGES"
    draw_box_bottom
    echo ""
    
    if [ ! -f "docker-compose.yaml" ] && [ ! -f "docker-compose.yml" ]; then
        echo -e "${RED}docker-compose.yaml not found${NC}"
        press_enter
        return
    fi
    
    echo -e "${CYAN}Pulling latest images from registries...${NC}"
    echo -e "${DIM}This will NOT start or restart any containers.${NC}"
    echo ""
    
    docker compose pull
    
    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✓ All images pulled successfully${NC}"
        echo ""
        echo -e "${CYAN}Options:${NC}"
        echo "  1) Start/restart stack with new images"
        echo "  2) Return to menu (containers unchanged)"
        echo ""
        read -p "  Select option [1-2]: " choice
        
        case $choice in
            1)
                echo ""
                echo "Recreating containers with new images..."
                docker compose up -d --force-recreate
                echo ""
                echo -e "${GREEN}✓ Stack restarted with new images${NC}"
                ;;
            *)
                echo ""
                echo -e "${CYAN}Images pulled but containers not restarted.${NC}"
                echo "Run 'docker compose up -d --force-recreate' to apply updates."
                ;;
        esac
    else
        echo ""
        echo -e "${RED}Some images failed to pull. Check your network connection.${NC}"
    fi
    
    press_enter
}

docker_start() {
    clear
    echo ""
    echo "Starting all containers..."
    echo ""
    
    [ "$LOG_AVAILABLE" = "true" ] && log_user_action "Start all containers"
    
    if [ -f "docker-compose.yaml" ] || [ -f "docker-compose.yml" ]; then
        if docker compose up -d 2>&1; then
            echo ""
            echo -e "${GREEN}✓ Containers started${NC}"
            [ "$LOG_AVAILABLE" = "true" ] && log_docker "start" "all" "Success"
        else
            [ "$LOG_AVAILABLE" = "true" ] && log_error "Failed to start containers" "docker compose up -d failed"
        fi
    else
        echo -e "${RED}docker-compose.yaml not found${NC}"
        [ "$LOG_AVAILABLE" = "true" ] && log_error "docker-compose.yaml not found" "" "Run from Aegis AIO directory"
    fi
    
    press_enter
}

docker_stop() {
    clear
    echo ""
    echo "Stopping all containers..."
    echo ""
    
    [ "$LOG_AVAILABLE" = "true" ] && log_user_action "Stop all containers"
    
    if [ -f "docker-compose.yaml" ] || [ -f "docker-compose.yml" ]; then
        if docker compose stop 2>&1; then
            echo ""
            echo -e "${GREEN}✓ Containers stopped${NC}"
            echo -e "${DIM}(Containers preserved - use 'docker compose down' to remove them)${NC}"
            [ "$LOG_AVAILABLE" = "true" ] && log_docker "stop" "all" "Success"
        else
            [ "$LOG_AVAILABLE" = "true" ] && log_error "Failed to stop containers" "docker compose stop failed"
        fi
    else
        echo -e "${RED}docker-compose.yaml not found${NC}"
        [ "$LOG_AVAILABLE" = "true" ] && log_error "docker-compose.yaml not found"
    fi
    
    press_enter
}

docker_restart() {
    clear
    echo ""
    echo "Restarting all containers..."
    echo ""
    
    [ "$LOG_AVAILABLE" = "true" ] && log_user_action "Restart all containers"
    
    if [ -f "docker-compose.yaml" ] || [ -f "docker-compose.yml" ]; then
        if docker compose restart 2>&1; then
            echo ""
            echo -e "${GREEN}✓ Containers restarted${NC}"
            [ "$LOG_AVAILABLE" = "true" ] && log_docker "restart" "all" "Success"
        else
            [ "$LOG_AVAILABLE" = "true" ] && log_error "Failed to restart containers" "docker compose restart failed"
        fi
    else
        echo -e "${RED}docker-compose.yaml not found${NC}"
        [ "$LOG_AVAILABLE" = "true" ] && log_error "docker-compose.yaml not found"
    fi
    
    press_enter
}

docker_force_rebuild() {
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                    FORCE REBUILD CONTAINERS"
    draw_box_bottom
    echo ""
    
    if [ ! -f "docker-compose.yaml" ] && [ ! -f "docker-compose.yml" ]; then
        echo -e "${RED}docker-compose.yaml not found${NC}"
        press_enter
        return
    fi
    
    echo -e "${YELLOW}This will:${NC}"
    echo "  1. Stop all running containers"
    echo "  2. Remove existing containers"
    echo "  3. Pull latest images from registries"
    echo "  4. Rebuild containers from scratch"
    echo "  5. Start all containers"
    echo ""
    echo -e "${DIM}Command: docker compose up -d --force-recreate --build --pull always${NC}"
    echo ""
    
    echo -e "${WHITE}${BOLD}Rebuild Options${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo "  1) Full rebuild (pull images + recreate + build)"
    echo "  2) Recreate only (no image pull, just rebuild containers)"
    echo "  3) Rebuild specific service(s)"
    echo "  0) Cancel"
    echo ""
    
    read -p "  Select option: " choice
    
    case $choice in
        1)
            echo ""
            echo -e "${CYAN}Performing full force rebuild...${NC}"
            echo ""
            
            echo -e "${DIM}Step 1/2: Pulling latest images...${NC}"
            docker compose pull
            
            echo ""
            echo -e "${DIM}Step 2/2: Rebuilding and starting containers...${NC}"
            docker compose up -d --force-recreate --build
            
            echo ""
            echo -e "${GREEN}✓ Full force rebuild complete!${NC}"
            echo ""
            docker compose ps
            ;;
        2)
            echo ""
            echo -e "${CYAN}Recreating containers (no image pull)...${NC}"
            echo ""
            
            docker compose up -d --force-recreate --build
            
            echo ""
            echo -e "${GREEN}✓ Containers recreated!${NC}"
            echo ""
            docker compose ps
            ;;
        3)
            force_rebuild_services
            return
            ;;
        0|"")
            return
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            sleep 1
            docker_force_rebuild
            return
            ;;
    esac
    
    press_enter
}

force_rebuild_services() {
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                REBUILD SPECIFIC SERVICES"
    draw_box_bottom
    echo ""
    
    echo -e "${WHITE}${BOLD}Available Services${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    local i=1
    local available_services=()
    
    for service_entry in "${AEGIS_SERVICES[@]}"; do
        local service_name=$(echo "$service_entry" | cut -d: -f1)
        local service_desc=$(echo "$service_entry" | cut -d: -f2)
        local status=$(get_service_status "$service_name")
        
        case $status in
            "running")
                printf "  ${GREEN}●${NC} %2d) %-20s ${GREEN}Running${NC}\n" "$i" "$service_desc"
                available_services+=("$service_name:$service_desc")
                ;;
            "stopped")
                printf "  ${RED}●${NC} %2d) %-20s ${RED}Stopped${NC}\n" "$i" "$service_desc"
                available_services+=("$service_name:$service_desc")
                ;;
            *)
                printf "  ${DIM}○${NC} %2d) %-20s ${DIM}Not deployed${NC}\n" "$i" "$service_desc"
                available_services+=("$service_name:$service_desc")
                ;;
        esac
        ((i++))
    done
    
    echo ""
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo "   0) Back"
    echo ""
    
    read -p "  Select service(s) to rebuild (comma-separated, e.g., 1,3,5): " selection
    
    if [ "$selection" = "0" ] || [ -z "$selection" ]; then
        docker_force_rebuild
        return
    fi
    
    # Parse comma-separated selections
    IFS=',' read -ra selections <<< "$selection"
    
    local services_to_rebuild=""
    
    for sel in "${selections[@]}"; do
        sel=$(echo "$sel" | tr -d ' ')
        
        if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt ${#available_services[@]} ]; then
            echo -e "${RED}Invalid selection: $sel${NC}"
            continue
        fi
        
        local idx=$((sel - 1))
        local entry="${available_services[$idx]}"
        local service_name=$(echo "$entry" | cut -d: -f1)
        services_to_rebuild="$services_to_rebuild $service_name"
    done
    
    if [ -n "$services_to_rebuild" ]; then
        echo ""
        echo -e "${CYAN}Rebuilding:${NC}$services_to_rebuild"
        echo ""
        
        echo -e "${DIM}Pulling images...${NC}"
        docker compose pull $services_to_rebuild
        
        echo ""
        echo -e "${DIM}Force rebuilding containers...${NC}"
        docker compose up -d --force-recreate --build $services_to_rebuild
        
        echo ""
        echo -e "${GREEN}✓ Services rebuilt!${NC}"
    fi
    
    press_enter
}

docker_status() {
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                      CONTAINER STATUS"
    draw_box_bottom
    echo ""
    
    if [ ! -f "docker-compose.yaml" ] && [ ! -f "docker-compose.yml" ]; then
        echo -e "${RED}docker-compose.yaml not found${NC}"
        press_enter
        return
    fi
    
    # Define expected core services (always should be running)
    local core_services=("database" "reactmap" "dragonite" "admin" "golbat" "rotom" "koji" "pma" "grafana" "victoriametrics" "vmagent" "xilriws")
    # Define optional services (might not be deployed)
    local optional_services=("poracle" "fletchling" "fletchling-tools")
    
    # Counters
    local running=0
    local stopped=0
    local missing=0
    local unhealthy=0
    
    # Header
    echo -e "  ${WHITE}${BOLD}Core Services${NC}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${NC}"
    printf "  ${DIM}%-20s %-12s %-20s %-15s${NC}\n" "SERVICE" "STATUS" "UPTIME" "HEALTH"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${NC}"
    
    for service in "${core_services[@]}"; do
        # Get container info
        local container_info=$(docker ps -a --filter "name=^${service}$" --format "{{.Status}}|{{.State}}|{{.RunningFor}}" 2>/dev/null | head -1)
        
        if [ -z "$container_info" ]; then
            # Container doesn't exist
            printf "  %-20s ${RED}%-12s${NC} %-20s %-15s\n" "$service" "NOT CREATED" "-" "-"
            ((missing++))
        else
            local status=$(echo "$container_info" | cut -d'|' -f1)
            local state=$(echo "$container_info" | cut -d'|' -f2)
            local uptime=$(echo "$container_info" | cut -d'|' -f3)
            
            # Parse health from status if present
            local health="-"
            if [[ "$status" == *"(healthy)"* ]]; then
                health="${GREEN}healthy${NC}"
            elif [[ "$status" == *"(unhealthy)"* ]]; then
                health="${RED}unhealthy${NC}"
                ((unhealthy++))
            elif [[ "$status" == *"(health:"* ]]; then
                health="${YELLOW}starting${NC}"
            fi
            
            # Clean up uptime display
            uptime=$(echo "$uptime" | sed 's/About /~/' | sed 's/ ago//' | cut -c1-18)
            
            if [ "$state" = "running" ]; then
                printf "  ${GREEN}●${NC} %-18s ${GREEN}%-12s${NC} %-20s %-15b\n" "$service" "Running" "$uptime" "$health"
                ((running++))
            elif [ "$state" = "exited" ]; then
                # Get exit code
                local exit_code=$(docker inspect "$service" --format '{{.State.ExitCode}}' 2>/dev/null)
                if [ "$exit_code" = "0" ]; then
                    printf "  ${YELLOW}●${NC} %-18s ${YELLOW}%-12s${NC} %-20s %-15s\n" "$service" "Stopped" "-" "Exit: 0"
                else
                    printf "  ${RED}●${NC} %-18s ${RED}%-12s${NC} %-20s %-15s\n" "$service" "Stopped" "-" "Exit: $exit_code"
                fi
                ((stopped++))
            elif [ "$state" = "restarting" ]; then
                printf "  ${YELLOW}●${NC} %-18s ${YELLOW}%-12s${NC} %-20s %-15s\n" "$service" "Restarting" "$uptime" "-"
                ((unhealthy++))
            elif [ "$state" = "created" ]; then
                printf "  ${DIM}●${NC} %-18s ${DIM}%-12s${NC} %-20s %-15s\n" "$service" "Created" "-" "-"
                ((stopped++))
            else
                printf "  ${DIM}●${NC} %-18s ${DIM}%-12s${NC} %-20s %-15s\n" "$service" "$state" "$uptime" "-"
            fi
        fi
    done
    
    echo ""
    echo -e "  ${WHITE}${BOLD}Optional Services${NC}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${NC}"
    
    local optional_found=false
    for service in "${optional_services[@]}"; do
        local container_info=$(docker ps -a --filter "name=^${service}$" --format "{{.Status}}|{{.State}}|{{.RunningFor}}" 2>/dev/null | head -1)
        
        if [ -n "$container_info" ]; then
            optional_found=true
            local status=$(echo "$container_info" | cut -d'|' -f1)
            local state=$(echo "$container_info" | cut -d'|' -f2)
            local uptime=$(echo "$container_info" | cut -d'|' -f3)
            uptime=$(echo "$uptime" | sed 's/About /~/' | sed 's/ ago//' | cut -c1-18)
            
            if [ "$state" = "running" ]; then
                printf "  ${GREEN}●${NC} %-18s ${GREEN}%-12s${NC} %-20s\n" "$service" "Running" "$uptime"
                ((running++))
            else
                printf "  ${YELLOW}●${NC} %-18s ${YELLOW}%-12s${NC} %-20s\n" "$service" "Stopped" "-"
                ((stopped++))
            fi
        fi
    done
    
    if [ "$optional_found" = false ]; then
        echo -e "  ${DIM}No optional services deployed${NC}"
    fi
    
    # Summary
    echo ""
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    local total_expected=${#core_services[@]}
    local total_deployed=$((running + stopped))
    
    # Status summary with color coding
    echo -n "  Summary: "
    if [ $running -eq $total_expected ]; then
        echo -e "${GREEN}All $running core services running${NC}"
    elif [ $running -gt 0 ]; then
        echo -e "${YELLOW}$running running${NC}, ${RED}$stopped stopped${NC}, ${DIM}$missing not created${NC}"
    else
        echo -e "${RED}No services running${NC}"
    fi
    
    if [ $unhealthy -gt 0 ]; then
        echo -e "  ${RED}⚠ $unhealthy service(s) unhealthy or restarting${NC}"
    fi
    
    if [ $missing -gt 0 ]; then
        echo ""
        echo -e "  ${YELLOW}Tip:${NC} Run 'docker compose up -d' to create missing containers"
    fi
    
    if [ $stopped -gt 0 ]; then
        echo ""
        echo -e "  ${YELLOW}Tip:${NC} Run 's' to start stopped containers"
    fi
    
    echo ""
    echo -e "  ${DIM}Press 'r' for raw docker output, Enter to return${NC}"
    read -p "  " choice
    
    if [ "$choice" = "r" ] || [ "$choice" = "R" ]; then
        echo ""
        echo -e "  ${CYAN}Raw docker compose output:${NC}"
        echo ""
        docker compose ps -a
        press_enter
    fi
}

# =============================================================================
# INDIVIDUAL SERVICE MANAGEMENT
# =============================================================================

# Get service status (running/stopped/not_found)
get_service_status() {
    local service=$1
    local status=$(docker ps -a --filter "name=^${service}$" --format "{{.Status}}" 2>/dev/null)
    
    if [ -z "$status" ]; then
        echo "not_found"
    elif [[ "$status" == *"Up"* ]]; then
        echo "running"
    else
        echo "stopped"
    fi
}

# Show service management menu
show_service_menu() {
    local action=$1  # "start" or "stop"
    local action_past=$2  # "started" or "stopped"
    local action_verb=$3  # "Start" or "Stop"
    
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                    ${action_verb^^} INDIVIDUAL SERVICES"
    draw_box_bottom
    echo ""
    
    echo -e "${WHITE}${BOLD}Available Services${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    local i=1
    local available_services=()
    
    for service_entry in "${AEGIS_SERVICES[@]}"; do
        local service_name=$(echo "$service_entry" | cut -d: -f1)
        local service_desc=$(echo "$service_entry" | cut -d: -f2)
        local status=$(get_service_status "$service_name")
        
        case $status in
            "running")
                printf "  ${GREEN}●${NC} %2d) %-20s ${GREEN}Running${NC}\n" "$i" "$service_desc"
                available_services+=("$service_name:$service_desc:running")
                ;;
            "stopped")
                printf "  ${RED}●${NC} %2d) %-20s ${RED}Stopped${NC}\n" "$i" "$service_desc"
                available_services+=("$service_name:$service_desc:stopped")
                ;;
            *)
                printf "  ${DIM}○${NC} %2d) %-20s ${DIM}Not deployed${NC}\n" "$i" "$service_desc"
                available_services+=("$service_name:$service_desc:not_found")
                ;;
        esac
        ((i++))
    done
    
    echo ""
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo "   a) ${action_verb} ALL services"
    echo "   0) Back to main menu"
    echo ""
    
    read -p "  Select service(s) to ${action} (comma-separated, e.g., 1,3,5): " selection
    
    if [ "$selection" = "0" ]; then
        return
    fi
    
    if [ "$selection" = "a" ] || [ "$selection" = "A" ]; then
        echo ""
        if [ "$action" = "start" ]; then
            docker compose up -d
        else
            docker compose stop
        fi
        echo ""
        echo -e "${GREEN}✓ All services ${action_past}${NC}"
        press_enter
        return
    fi
    
    # Parse comma-separated selections
    IFS=',' read -ra selections <<< "$selection"
    
    echo ""
    for sel in "${selections[@]}"; do
        # Trim whitespace
        sel=$(echo "$sel" | tr -d ' ')
        
        # Validate selection
        if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt ${#available_services[@]} ]; then
            echo -e "${RED}Invalid selection: $sel${NC}"
            continue
        fi
        
        local idx=$((sel - 1))
        local entry="${available_services[$idx]}"
        local service_name=$(echo "$entry" | cut -d: -f1)
        local service_desc=$(echo "$entry" | cut -d: -f2)
        local service_status=$(echo "$entry" | cut -d: -f3)
        
        if [ "$service_status" = "not_found" ]; then
            echo -e "${YELLOW}Skipping $service_desc - not deployed${NC}"
            continue
        fi
        
        if [ "$action" = "start" ]; then
            if [ "$service_status" = "running" ]; then
                echo -e "${DIM}$service_desc is already running${NC}"
            else
                echo -e "Starting ${CYAN}$service_desc${NC}..."
                docker compose up -d "$service_name" 2>/dev/null || docker start "$service_name" 2>/dev/null
                echo -e "${GREEN}✓ $service_desc started${NC}"
            fi
        else
            if [ "$service_status" = "stopped" ]; then
                echo -e "${DIM}$service_desc is already stopped${NC}"
            else
                echo -e "Stopping ${CYAN}$service_desc${NC}..."
                docker compose stop "$service_name" 2>/dev/null || docker stop "$service_name" 2>/dev/null
                echo -e "${GREEN}✓ $service_desc stopped${NC}"
            fi
        fi
    done
    
    press_enter
}

# Wrapper functions for service management
service_start_menu() {
    show_service_menu "start" "started" "Start"
}

service_stop_menu() {
    show_service_menu "stop" "stopped" "Stop"
}

# Restart individual service menu
service_restart_menu() {
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                    RESTART INDIVIDUAL SERVICES"
    draw_box_bottom
    echo ""
    
    echo -e "${WHITE}${BOLD}Available Services${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    local i=1
    local available_services=()
    
    for service_entry in "${AEGIS_SERVICES[@]}"; do
        local service_name=$(echo "$service_entry" | cut -d: -f1)
        local service_desc=$(echo "$service_entry" | cut -d: -f2)
        local status=$(get_service_status "$service_name")
        
        case $status in
            "running")
                printf "  ${GREEN}●${NC} %2d) %-20s ${GREEN}Running${NC}\n" "$i" "$service_desc"
                available_services+=("$service_name:$service_desc:running")
                ;;
            "stopped")
                printf "  ${RED}●${NC} %2d) %-20s ${RED}Stopped${NC}\n" "$i" "$service_desc"
                available_services+=("$service_name:$service_desc:stopped")
                ;;
            *)
                printf "  ${DIM}○${NC} %2d) %-20s ${DIM}Not deployed${NC}\n" "$i" "$service_desc"
                available_services+=("$service_name:$service_desc:not_found")
                ;;
        esac
        ((i++))
    done
    
    echo ""
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo "   a) Restart ALL services"
    echo "   0) Back to main menu"
    echo ""
    
    read -p "  Select service(s) to restart (comma-separated, e.g., 1,3,5): " selection
    
    if [ "$selection" = "0" ]; then
        return
    fi
    
    if [ "$selection" = "a" ] || [ "$selection" = "A" ]; then
        echo ""
        docker compose restart
        echo ""
        echo -e "${GREEN}✓ All services restarted${NC}"
        press_enter
        return
    fi
    
    # Parse comma-separated selections
    IFS=',' read -ra selections <<< "$selection"
    
    echo ""
    for sel in "${selections[@]}"; do
        sel=$(echo "$sel" | tr -d ' ')
        
        if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt ${#available_services[@]} ]; then
            echo -e "${RED}Invalid selection: $sel${NC}"
            continue
        fi
        
        local idx=$((sel - 1))
        local entry="${available_services[$idx]}"
        local service_name=$(echo "$entry" | cut -d: -f1)
        local service_desc=$(echo "$entry" | cut -d: -f2)
        local service_status=$(echo "$entry" | cut -d: -f3)
        
        if [ "$service_status" = "not_found" ]; then
            echo -e "${YELLOW}Skipping $service_desc - not deployed${NC}"
            continue
        fi
        
        echo -e "Restarting ${CYAN}$service_desc${NC}..."
        docker compose restart "$service_name" 2>/dev/null || docker restart "$service_name" 2>/dev/null
        echo -e "${GREEN}✓ $service_desc restarted${NC}"
    done
    
    press_enter
}

# =============================================================================
# DOCKER PURGE FUNCTIONS
# =============================================================================

docker_purge_menu() {
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                      DOCKER PURGE"
    draw_box_bottom
    echo ""
    
    echo -e "${RED}${BOLD}⚠ WARNING: These actions are destructive and cannot be undone!${NC}"
    echo ""
    echo -e "${WHITE}${BOLD}Purge Options${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  1) Stop & Remove Aegis containers only"
    echo "  2) Remove Aegis containers + volumes (keeps images)"
    echo "  3) Remove unused Docker images (docker image prune)"
    echo "  4) Remove all unused Docker data (prune system)"
    echo "  5) Remove Docker networks"
    echo "  6) Nuclear option - Remove ALL Docker data (containers, images, volumes, networks)"
    echo ""
    echo "  0) Back to main menu"
    echo ""
    
    read -p "  Select option: " choice
    
    case $choice in
        1)
            echo ""
            echo -e "${YELLOW}This will stop and remove all Aegis containers.${NC}"
            read -p "Continue? (y/n) [n]: " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                echo ""
                echo "Stopping and removing Aegis containers..."
                docker compose down 2>/dev/null
                echo ""
                echo -e "${GREEN}✓ Aegis containers removed${NC}"
            fi
            press_enter
            ;;
        2)
            echo ""
            echo -e "${YELLOW}This will remove all Aegis containers AND their volumes.${NC}"
            echo -e "${RED}Database data will be lost!${NC}"
            read -p "Continue? (y/n) [n]: " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                read -p "Are you REALLY sure? Type 'DELETE' to confirm: " confirm2
                if [ "$confirm2" = "DELETE" ]; then
                    echo ""
                    echo "Removing Aegis containers and volumes..."
                    docker compose down -v 2>/dev/null
                    echo ""
                    echo -e "${GREEN}✓ Aegis containers and volumes removed${NC}"
                else
                    echo -e "${YELLOW}Aborted${NC}"
                fi
            fi
            press_enter
            ;;
        3)
            echo ""
            echo "Removing unused Docker images..."
            docker image prune -f
            echo ""
            echo -e "${GREEN}✓ Unused images removed${NC}"
            press_enter
            ;;
        4)
            echo ""
            echo -e "${YELLOW}This will remove:${NC}"
            echo "  - All stopped containers"
            echo "  - All unused networks"
            echo "  - All dangling images"
            echo "  - All dangling build cache"
            echo ""
            read -p "Continue? (y/n) [n]: " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                echo ""
                docker system prune -f
                echo ""
                echo -e "${GREEN}✓ Docker system pruned${NC}"
            fi
            press_enter
            ;;
        5)
            echo ""
            echo "Current Docker networks:"
            docker network ls
            echo ""
            echo -e "${YELLOW}This will remove all unused networks.${NC}"
            read -p "Continue? (y/n) [n]: " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                echo ""
                docker network prune -f
                echo ""
                echo -e "${GREEN}✓ Unused networks removed${NC}"
            fi
            press_enter
            ;;
        6)
            echo ""
            echo -e "${RED}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}${BOLD}║                    ⚠ NUCLEAR OPTION ⚠                             ║${NC}"
            echo -e "${RED}${BOLD}╠═══════════════════════════════════════════════════════════════════╣${NC}"
            echo -e "${RED}${BOLD}║  This will PERMANENTLY DELETE:                                    ║${NC}"
            echo -e "${RED}${BOLD}║    - ALL Docker containers (running and stopped)                  ║${NC}"
            echo -e "${RED}${BOLD}║    - ALL Docker images                                            ║${NC}"
            echo -e "${RED}${BOLD}║    - ALL Docker volumes (including database data!)                ║${NC}"
            echo -e "${RED}${BOLD}║    - ALL Docker networks                                          ║${NC}"
            echo -e "${RED}${BOLD}║    - ALL Docker build cache                                       ║${NC}"
            echo -e "${RED}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            read -p "Continue? (y/n) [n]: " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                read -p "Type 'NUKE DOCKER' to confirm complete purge: " confirm2
                if [ "$confirm2" = "NUKE DOCKER" ]; then
                    echo ""
                    echo "Stopping all containers..."
                    docker stop $(docker ps -aq) 2>/dev/null
                    
                    echo "Removing all containers..."
                    docker rm $(docker ps -aq) 2>/dev/null
                    
                    echo "Removing all images..."
                    docker rmi $(docker images -aq) -f 2>/dev/null
                    
                    echo "Removing all volumes..."
                    docker volume rm $(docker volume ls -q) 2>/dev/null
                    
                    echo "Removing all networks..."
                    docker network prune -f 2>/dev/null
                    
                    echo "Final cleanup..."
                    docker system prune -a -f --volumes 2>/dev/null
                    
                    echo ""
                    echo -e "${GREEN}✓ All Docker data has been removed${NC}"
                    echo -e "${YELLOW}You will need to rebuild everything from scratch.${NC}"
                else
                    echo -e "${YELLOW}Aborted${NC}"
                fi
            fi
            press_enter
            ;;
        0|"")
            return
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            sleep 1
            docker_purge_menu
            ;;
    esac
}

# =============================================================================
# UNINSTALL STACK
# =============================================================================

uninstall_stack() {
    clear
    draw_logo
    
    draw_box_top
    draw_box_line "                      UNINSTALL AEGIS STACK"
    draw_box_bottom
    echo ""
    
    echo -e "${RED}${BOLD}⚠ WARNING: This will remove the Aegis stack from your system!${NC}"
    echo ""
    echo -e "${WHITE}${BOLD}Uninstall Options${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  1) Light uninstall - Stop containers, remove Docker resources"
    echo "     (Keeps config files, can restart later)"
    echo ""
    echo "  2) Full uninstall - Remove containers + reset config files"
    echo "     (Keeps directory, removes generated configs)"
    echo ""
    echo "  3) Complete removal - Delete entire Aegis directory"
    echo "     (Removes everything including this script)"
    echo ""
    echo "  0) Cancel and go back"
    echo ""
    
    read -p "  Select option: " choice
    
    case $choice in
        1)
            echo ""
            echo -e "${YELLOW}Light Uninstall will:${NC}"
            echo "  - Stop all Aegis containers"
            echo "  - Remove containers and their volumes"
            echo "  - Keep all configuration files"
            echo ""
            read -p "Continue? (y/n) [n]: " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                echo ""
                echo "Stopping and removing Aegis containers..."
                docker compose down -v 2>/dev/null
                
                echo "Removing Aegis-related images..."
                docker images --filter "reference=*golbat*" --filter "reference=*dragonite*" \
                    --filter "reference=*reactmap*" --filter "reference=*rotom*" \
                    --filter "reference=*koji*" --filter "reference=*xilriws*" \
                    --filter "reference=*poracle*" --filter "reference=*fletchling*" \
                    -q 2>/dev/null | xargs -r docker rmi -f 2>/dev/null
                
                echo ""
                echo -e "${GREEN}✓ Light uninstall complete${NC}"
                echo -e "${CYAN}Config files preserved. Run 'docker compose up -d' to restart.${NC}"
            fi
            press_enter
            ;;
        2)
            echo ""
            echo -e "${YELLOW}Full Uninstall will:${NC}"
            echo "  - Stop and remove all Aegis containers"
            echo "  - Remove generated configuration files (.env, local.json, etc.)"
            echo "  - Remove log files"
            echo "  - Keep template/default files for fresh setup"
            echo ""
            read -p "Continue? (y/n) [n]: " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                read -p "Type 'UNINSTALL' to confirm: " confirm2
                if [ "$confirm2" = "UNINSTALL" ]; then
                    echo ""
                    echo "Stopping and removing containers..."
                    docker compose down -v 2>/dev/null
                    
                    echo "Removing generated config files..."
                    rm -f .env 2>/dev/null
                    rm -f reactmap/local.json 2>/dev/null
                    rm -f unown/dragonite_config.toml 2>/dev/null
                    rm -f unown/golbat_config.toml 2>/dev/null
                    rm -f unown/rotom_config.json 2>/dev/null
                    
                    echo "Removing log files..."
                    rm -rf unown/logs/* 2>/dev/null
                    rm -rf fletchling/*.log 2>/dev/null
                    
                    echo "Removing cache files..."
                    rm -rf unown/golbat_cache/* 2>/dev/null
                    
                    echo "Removing database files..."
                    rm -rf mysql_data/*.err mysql_data/*.pid 2>/dev/null
                    # Keep mysql_data structure but remove data files
                    find mysql_data -type f ! -name "mariadb.cnf" -delete 2>/dev/null
                    find mysql_data -type d -empty -delete 2>/dev/null
                    
                    echo "Removing metrics data..."
                    rm -rf victoriametrics/data/* 2>/dev/null
                    rm -rf vmagent/data/* 2>/dev/null
                    
                    echo "Removing Grafana data..."
                    rm -rf grafana/*.db grafana/plugins grafana/png 2>/dev/null
                    
                    echo "Removing Aegis-related Docker images..."
                    docker images --filter "reference=*golbat*" --filter "reference=*dragonite*" \
                        --filter "reference=*reactmap*" --filter "reference=*rotom*" \
                        --filter "reference=*koji*" --filter "reference=*xilriws*" \
                        --filter "reference=*poracle*" --filter "reference=*fletchling*" \
                        -q 2>/dev/null | xargs -r docker rmi -f 2>/dev/null
                    
                    echo ""
                    echo -e "${GREEN}✓ Full uninstall complete${NC}"
                    echo -e "${CYAN}Run setup.sh to reconfigure from scratch.${NC}"
                else
                    echo -e "${YELLOW}Aborted${NC}"
                fi
            fi
            press_enter
            ;;
        3)
            echo ""
            echo -e "${RED}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}${BOLD}║                  ⚠ COMPLETE REMOVAL ⚠                             ║${NC}"
            echo -e "${RED}${BOLD}╠═══════════════════════════════════════════════════════════════════╣${NC}"
            echo -e "${RED}${BOLD}║  This will PERMANENTLY DELETE:                                    ║${NC}"
            echo -e "${RED}${BOLD}║    - All Aegis containers and volumes                             ║${NC}"
            echo -e "${RED}${BOLD}║    - All configuration files                                      ║${NC}"
            echo -e "${RED}${BOLD}║    - All data (database, logs, cache)                             ║${NC}"
            echo -e "${RED}${BOLD}║    - The ENTIRE Aegis-All-In-One directory                        ║${NC}"
            echo -e "${RED}${BOLD}║    - THIS SCRIPT ITSELF                                           ║${NC}"
            echo -e "${RED}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            read -p "Continue? (y/n) [n]: " confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                read -p "Type 'DELETE AEGIS' to confirm complete removal: " confirm2
                if [ "$confirm2" = "DELETE AEGIS" ]; then
                    echo ""
                    echo "Stopping and removing all containers..."
                    docker compose down -v 2>/dev/null
                    
                    echo "Removing Aegis-related Docker images..."
                    docker images --filter "reference=*golbat*" --filter "reference=*dragonite*" \
                        --filter "reference=*reactmap*" --filter "reference=*rotom*" \
                        --filter "reference=*koji*" --filter "reference=*xilriws*" \
                        --filter "reference=*poracle*" --filter "reference=*fletchling*" \
                        --filter "reference=*mariadb*" --filter "reference=*phpmyadmin*" \
                        --filter "reference=*grafana*" --filter "reference=*victoriametrics*" \
                        -q 2>/dev/null | xargs -r docker rmi -f 2>/dev/null
                    
                    echo ""
                    echo -e "${GREEN}✓ Docker resources removed${NC}"
                    echo ""
                    echo -e "${YELLOW}Deleting Aegis directory in 5 seconds...${NC}"
                    echo -e "${YELLOW}Press Ctrl+C to abort!${NC}"
                    sleep 5
                    
                    # Store parent directory before deleting
                    local parent_dir=$(dirname "$SCRIPT_DIR")
                    
                    echo "Removing Aegis directory..."
                    cd "$parent_dir"
                    rm -rf "$SCRIPT_DIR"
                    
                    echo ""
                    echo -e "${GREEN}✓ Aegis stack completely removed${NC}"
                    echo ""
                    exit 0
                else
                    echo -e "${YELLOW}Aborted${NC}"
                fi
            fi
            press_enter
            ;;
        0|"")
            return
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            sleep 1
            uninstall_stack
            ;;
    esac
}

# =============================================================================
# RUN SCRIPT FUNCTIONS
# =============================================================================

run_script() {
    local script=$1
    local name=$2
    
    [ "$LOG_AVAILABLE" = "true" ] && log_user_action "Launching script" "$name ($script)"
    
    if [ -f "$SCRIPT_DIR/Shellder/$script" ]; then
        clear
        echo ""
        echo -e "${CYAN}Launching $name...${NC}"
        echo ""
        sleep 1
        
        # Run the script with environment variables to:
        # - Indicate it was launched from shellder.sh (SHELLDER_LAUNCHER)
        # - Pass the original user info (REAL_USER, REAL_GROUP) to prevent root-locked files
        # - Pass session ID for log correlation
        # Note: We don't use sudo here because shellder.sh is already running as root
        SHELLDER_LAUNCHER=1 REAL_USER="$REAL_USER" REAL_GROUP="$REAL_GROUP" SHELLDER_SESSION_ID="$SHELLDER_SESSION_ID" bash "$SCRIPT_DIR/Shellder/$script"
        local exit_code=$?
        
        [ "$LOG_AVAILABLE" = "true" ] && log_info "Script completed: $script" "Exit code: $exit_code"
        
        # Script completed - no need for extra prompt since scripts handle their own exit
    else
        echo ""
        [ "$LOG_AVAILABLE" = "true" ] && log_error "Script not found: Shellder/$script"
        echo -e "${RED}Script not found: Shellder/$script${NC}"
        press_enter
    fi
}

# =============================================================================
# CONFIG VALIDATION
# =============================================================================

# Check configurations and alert on discrepancies
check_config_on_launch() {
    if [ "$DB_AVAILABLE" != "true" ]; then
        return
    fi
    
    # Initialize database if needed
    if ! check_shellder_db 2>/dev/null; then
        init_shellder_db 2>/dev/null
    fi
    
    # Check if .env exists
    if [ ! -f ".env" ]; then
        return
    fi
    
    # Run config check
    local result=$(check_env_configs ".env" 2>/dev/null)
    if [ -z "$result" ]; then
        return
    fi
    
    local matched=$(echo "$result" | cut -d'|' -f1)
    local discrepancies=$(echo "$result" | cut -d'|' -f2)
    local new_configs=$(echo "$result" | cut -d'|' -f3)
    
    # Show alert if there are discrepancies
    if [ "$discrepancies" -gt 0 ] && [ "$CONFIG_ALERT_SHOWN" != "true" ]; then
        echo ""
        draw_box_top
        draw_box_line ""
        draw_box_line "  ⚠️  CONFIGURATION DISCREPANCY DETECTED"
        draw_box_line ""
        draw_box_line "  $discrepancies config value(s) differ from stored values."
        draw_box_line "  This may indicate:"
        draw_box_line "    • Config files were edited outside of Shellder"
        draw_box_line "    • A file was restored from backup"
        draw_box_line "    • Multiple installations with different settings"
        draw_box_line ""
        draw_box_line "  To view details: Database Setup (2) → Shellder Statistics (6)"
        draw_box_line ""
        draw_box_bottom
        echo ""
        CONFIG_ALERT_SHOWN=true
        
        read -p "  Press Enter to continue..." 
    fi
    
    # Silently log new configs
    if [ "$new_configs" -gt 0 ]; then
        record_event "config_stored" "shellder.sh" "Stored $new_configs new config values from .env" "" 2>/dev/null
    fi
}

# =============================================================================
# MAIN LOOP
# =============================================================================

main() {
    # Initialize logging
    if [ "$LOG_AVAILABLE" = "true" ]; then
        init_logging "shellder.sh"
        log_info "Shellder Control Panel starting" "Version: $VERSION"
    fi
    
    # Check if we're in the right directory
    if [ ! -f "docker-compose.yaml" ] && [ ! -f "docker-compose.yml" ]; then
        echo ""
        echo -e "${RED}Error: Please run this script from the Aegis AIO directory${NC}"
        echo ""
        [ "$LOG_AVAILABLE" = "true" ] && log_error "Not in Aegis AIO directory" "docker-compose.yaml not found" "Run from the Aegis AIO installation directory"
        exit 1
    fi
    
    # Check configuration on first launch
    check_config_on_launch

    while true; do
        show_status_dashboard
        show_main_menu
        
        read -p "  Select option: " choice
        
        case $choice in
            # Setup & Configuration
            1) run_script "setup.sh" "Initial Setup" ;;
            2) run_script "dbsetup.sh" "Database Setup & Management" ;;
            3) run_script "nginx-setup.sh" "Security Setup & Management" ;;
            # Monitoring & Maintenance
            4) run_script "check.sh" "System Check" ;;
            5) run_script "logs.sh" "Log Manager" ;;
            # Optional Features
            6) run_script "poracle.sh" "Poracle Setup" ;;
            7) run_script "fletchling.sh" "Fletchling Setup" ;;
            # File Management
            8) run_script "files.sh" "File System Manager" ;;
            # Web Dashboard
            9) shellder_gui_menu ;;
            # Stack Controls
            s|S) docker_start ;;
            x|X) docker_stop ;;
            t|T) docker_restart ;;
            b|B) docker_force_rebuild ;;
            c|C) docker_status ;;
            v|V) show_container_dashboard ;;
            # Service Management
            +) service_start_menu ;;
            -) service_stop_menu ;;
            \*) service_restart_menu ;;
            # Updates & Images
            i|I) docker_pull_images ;;
            p|P) git_pull ;;
            u|U) update_and_rebuild ;;
            # Maintenance & Cleanup
            d|D) docker_purge_menu ;;
            z|Z) uninstall_stack ;;
            # Other
            h|H) show_help ;;
            r|R) continue ;;
            0|q|Q)
                clear
                echo ""
                echo -e "${GREEN}Goodbye!${NC}"
                echo ""
                exit 0
                ;;
            *)
                echo ""
                echo -e "${RED}Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

# Command line arguments
case "${1:-}" in
    --help|-h)
        echo ""
        echo "Shellder Control Panel v${VERSION}"
        echo ""
        echo "Usage: $0 [option]"
        echo ""
        echo "Options:"
        echo "  (none)         Interactive menu"
        echo "  --status       Show status only"
        echo "  --start        Start all containers"
        echo "  --stop         Stop all containers"
        echo "  --restart      Restart all containers"
        echo "  --rebuild      Force rebuild all containers"
        echo "  --pull-images  Pull latest Docker images (no restart)"
        echo "  --pull         Git pull latest changes"
        echo "  --update       Pull, rebuild, and restart stack"
        echo "  --dashboard    Show detailed container dashboard"
        echo "  --help         This help message"
        echo ""
        exit 0
        ;;
    --status)
        show_status_dashboard
        exit 0
        ;;
    --start)
        docker_start
        exit 0
        ;;
    --stop)
        docker_stop
        exit 0
        ;;
    --restart)
        docker_restart
        exit 0
        ;;
    --rebuild)
        clear
        echo ""
        echo -e "${CYAN}Force rebuilding all containers...${NC}"
        echo ""
        docker compose pull
        docker compose up -d --force-recreate --build
        echo ""
        echo -e "${GREEN}✓ Force rebuild complete!${NC}"
        exit 0
        ;;
    --pull-images)
        docker_pull_images
        exit 0
        ;;
    --pull)
        git_pull
        exit 0
        ;;
    --update)
        update_and_rebuild
        exit 0
        ;;
    --dashboard)
        show_container_dashboard
        exit 0
        ;;
    *)
        main
        ;;
esac

