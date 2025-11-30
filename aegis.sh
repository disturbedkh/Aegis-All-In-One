#!/bin/bash

# =============================================================================
# Aegis All-in-One 2.0 - Main Control Panel
# =============================================================================
# This is the main entry point for managing your Aegis mapping stack.
# It provides:
#   - System status overview
#   - Quick access to all management scripts
#   - Update checking
#   - Help and documentation
# =============================================================================

VERSION="2.0.0"

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

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

draw_logo() {
    echo -e "${CYAN}"
    echo '    ___              _         ___   ________  '
    echo '   /   | ___  ____ _(_)____   /   | /  _/ __ \ '
    echo '  / /| |/ _ \/ __ `/ / ___/  / /| | / // / / / '
    echo ' / ___ /  __/ /_/ / (__  )  / ___ |_/ // /_/ /  '
    echo '/_/  |_\___/\__, /_/____/  /_/  |_/___/\____/   '
    echo '           /____/                               '
    echo -e "${NC}"
    echo -e "${DIM}           Aegis All-in-One v${VERSION}${NC}"
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
    if [ -f "$SCRIPT_DIR/$script" ]; then
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
        local running=$(docker ps --filter "name=database\|golbat\|dragonite\|rotom\|reactmap\|koji\|admin\|grafana\|pma\|xilriws\|poracle\|fletchling" --format "{{.Names}}" 2>/dev/null | wc -l)
        local total=$(docker ps -a --filter "name=database\|golbat\|dragonite\|rotom\|reactmap\|koji\|admin\|grafana\|pma\|xilriws\|poracle\|fletchling" --format "{{.Names}}" 2>/dev/null | wc -l)
        echo "${running}/${total}"
    else
        echo "N/A"
    fi
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

    # Containers
    local containers=$(count_containers)
    if [ "$containers" != "N/A" ]; then
        local running=$(echo $containers | cut -d/ -f1)
        local total=$(echo $containers | cut -d/ -f2)
        if [ "$running" -eq "$total" ] && [ "$total" -gt 0 ]; then
            print_status "Containers:" "$containers running" "$GREEN"
        elif [ "$running" -gt 0 ]; then
            print_status "Containers:" "$containers running" "$YELLOW"
        else
            print_status "Containers:" "None running" "$RED"
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
        if [ -f "$SCRIPT_DIR/$script" ]; then
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

    echo ""
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
    echo "    2) Database Management    - DB setup, maintenance, user management"
    echo "    3) Security Setup         - Nginx, SSL, firewall, authentication"
    echo ""
    echo -e "  ${CYAN}Monitoring & Maintenance${NC}"
    echo "    4) System Check           - Validate configs, check health"
    echo "    5) Log Manager            - View, analyze, and manage logs"
    echo ""
    echo -e "  ${CYAN}Optional Features${NC}"
    echo "    6) Poracle Setup          - Discord/Telegram notifications"
    echo "    7) Fletchling Setup       - Pokemon nest detection"
    echo ""
    echo -e "  ${CYAN}Stack Controls${NC}"
    echo "    s) Start Stack            - Start all containers"
    echo "    x) Stop Stack             - Stop all containers"
    echo "    t) Restart Stack          - Restart all containers"
    echo "    c) Container Status       - View container status"
    echo ""
    echo -e "  ${CYAN}Updates${NC}"
    echo "    p) Pull Latest            - Git pull latest changes"
    echo "    u) Update & Rebuild       - Pull, rebuild, and restart stack"
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
    
    echo -e "${CYAN}2) Database Management (dbsetup.sh)${NC}"
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
    
    echo -e "${CYAN}3) Security Setup (nginx-setup.sh)${NC}"
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
    echo "  x) Stop Stack     - docker compose down"
    echo "  t) Restart Stack  - docker compose restart"
    echo "  c) Status         - docker compose ps"
    echo ""

    echo -e "${WHITE}${BOLD}Updates${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  p) Pull Latest      - Git pull latest changes only"
    echo "  u) Update & Rebuild - Pull changes, rebuild containers, restart stack"
    echo ""

    echo -e "${WHITE}${BOLD}Quick Tips${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  • First time? Run option 1 (Initial Setup) first"
    echo "  • Having issues? Run option 4 (System Check)"
    echo "  • Logs filling up? Run option 5 (Log Manager)"
    echo "  • Going public? Run option 3 (Security Setup)"
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
    
    # Check for local changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        echo -e "${YELLOW}You have local changes.${NC}"
        echo ""
        git status --short
        echo ""
        read -p "Stash changes before pulling? (y/n) [y]: " stash
        stash=${stash:-y}
        if [ "$stash" = "y" ] || [ "$stash" = "Y" ]; then
            echo ""
            git stash
            echo ""
        else
            echo -e "${RED}Aborting pull to preserve local changes.${NC}"
            press_enter
            return
        fi
    fi

    echo "Pulling latest changes..."
    echo ""
    git pull origin $branch
    
    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✓ Pull complete!${NC}"
        
        # Check if we stashed
        if git stash list | grep -q "stash@{0}"; then
            echo ""
            read -p "Restore stashed changes? (y/n) [y]: " restore
            restore=${restore:-y}
            if [ "$restore" = "y" ] || [ "$restore" = "Y" ]; then
                git stash pop
            fi
        fi
    else
        echo ""
        echo -e "${RED}Pull failed. Check for conflicts.${NC}"
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
    echo "  1. Pull latest changes from git"
    echo "  2. Stop running containers"
    echo "  3. Rebuild containers with new images"
    echo "  4. Start the stack"
    echo ""
    
    read -p "Continue? (y/n) [n]: " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        return
    fi

    local branch=$(git branch --show-current 2>/dev/null)
    
    # Step 1: Pull
    echo ""
    echo -e "${CYAN}Step 1/4: Pulling latest changes...${NC}"
    
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        echo -e "${YELLOW}Stashing local changes...${NC}"
        git stash
    fi
    
    git pull origin $branch
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Pull failed. Aborting.${NC}"
        press_enter
        return
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

docker_start() {
    clear
    echo ""
    echo "Starting all containers..."
    echo ""
    
    if [ -f "docker-compose.yaml" ] || [ -f "docker-compose.yml" ]; then
        docker compose up -d
        echo ""
        echo -e "${GREEN}✓ Containers started${NC}"
    else
        echo -e "${RED}docker-compose.yaml not found${NC}"
    fi
    
    press_enter
}

docker_stop() {
    clear
    echo ""
    echo "Stopping all containers..."
    echo ""
    
    if [ -f "docker-compose.yaml" ] || [ -f "docker-compose.yml" ]; then
        docker compose down
        echo ""
        echo -e "${GREEN}✓ Containers stopped${NC}"
    else
        echo -e "${RED}docker-compose.yaml not found${NC}"
    fi
    
    press_enter
}

docker_restart() {
    clear
    echo ""
    echo "Restarting all containers..."
    echo ""
    
    if [ -f "docker-compose.yaml" ] || [ -f "docker-compose.yml" ]; then
        docker compose restart
        echo ""
        echo -e "${GREEN}✓ Containers restarted${NC}"
    else
        echo -e "${RED}docker-compose.yaml not found${NC}"
    fi
    
    press_enter
}

docker_status() {
    clear
    echo ""
    echo "Container Status:"
    echo ""
    
    if [ -f "docker-compose.yaml" ] || [ -f "docker-compose.yml" ]; then
        docker compose ps
    else
        echo -e "${RED}docker-compose.yaml not found${NC}"
    fi
    
    press_enter
}

# =============================================================================
# RUN SCRIPT FUNCTIONS
# =============================================================================

run_script() {
    local script=$1
    local name=$2
    
    if [ -f "$SCRIPT_DIR/$script" ]; then
        clear
        echo ""
        echo -e "${CYAN}Launching $name...${NC}"
        echo ""
        sleep 1
        
        # Run the script with environment variable to indicate it was launched from aegis.sh
        sudo AEGIS_LAUNCHER=1 bash "$SCRIPT_DIR/$script"
        
        # Script completed - no need for extra prompt since scripts handle their own exit
    else
        echo ""
        echo -e "${RED}Script not found: $script${NC}"
        press_enter
    fi
}

# =============================================================================
# MAIN LOOP
# =============================================================================

main() {
    # Check if we're in the right directory
    if [ ! -f "docker-compose.yaml" ] && [ ! -f "docker-compose.yml" ]; then
        echo ""
        echo -e "${RED}Error: Please run this script from the Aegis-All-In-One directory${NC}"
        echo ""
        exit 1
    fi

    while true; do
        show_status_dashboard
        show_main_menu
        
        read -p "  Select option: " choice
        
        case $choice in
            # Setup & Configuration
            1) run_script "setup.sh" "Initial Setup" ;;
            2) run_script "dbsetup.sh" "Database Management" ;;
            3) run_script "nginx-setup.sh" "Security Setup" ;;
            # Monitoring & Maintenance
            4) run_script "check.sh" "System Check" ;;
            5) run_script "logs.sh" "Log Manager" ;;
            # Optional Features
            6) run_script "poracle.sh" "Poracle Setup" ;;
            7) run_script "fletchling.sh" "Fletchling Setup" ;;
            # Stack Controls
            s|S) docker_start ;;
            x|X) docker_stop ;;
            t|T) docker_restart ;;
            c|C) docker_status ;;
            # Updates
            p|P) git_pull ;;
            u|U) update_and_rebuild ;;
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
        echo "Aegis All-in-One Control Panel v${VERSION}"
        echo ""
        echo "Usage: $0 [option]"
        echo ""
        echo "Options:"
        echo "  (none)      Interactive menu"
        echo "  --status    Show status only"
        echo "  --start     Start all containers"
        echo "  --stop      Stop all containers"
        echo "  --restart   Restart all containers"
        echo "  --pull      Git pull latest changes"
        echo "  --update    Pull, rebuild, and restart stack"
        echo "  --help      This help message"
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
    --pull)
        git_pull
        exit 0
        ;;
    --update)
        update_and_rebuild
        exit 0
        ;;
    *)
        main
        ;;
esac

