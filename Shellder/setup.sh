#!/bin/bash

# =============================================================================
# Shellder 2.0 - Initial Setup Script for Aegis AIO
# =============================================================================
# This script handles:
#   1. Checking/installing Docker and Docker Compose
#   2. Configuring Docker logging (log rotation to prevent disk space issues)
#   3. Checking/installing Google Chrome (specific version for compatibility)
#   4. Detecting system resources (RAM, CPU, Storage)
#   5. Optimizing MariaDB configuration for your hardware
#   6. Copying default config files
#   7. Generating/setting secure passwords and tokens
#   8. Installing MariaDB (optional)
#   9. Creating required databases
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Source Shellder database helper for config storage
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/db_helper.sh" ]; then
    source "$SCRIPT_DIR/db_helper.sh"
    DB_AVAILABLE=true
else
    DB_AVAILABLE=false
fi

# Source Shellder logging helper
SHELLDER_SCRIPT_NAME="setup.sh"
if [ -f "$SCRIPT_DIR/log_helper.sh" ]; then
    source "$SCRIPT_DIR/log_helper.sh"
    init_logging "setup.sh"
    LOG_AVAILABLE=true
else
    LOG_AVAILABLE=false
fi

# Return to main menu function
return_to_main() {
    if [ "$SHELLDER_LAUNCHER" = "1" ]; then
        echo ""
        echo -e "${CYAN}Returning to Shellder Control Panel...${NC}"
        sleep 1
    fi
    exit 0
}

echo ""
echo "======================================"
echo "  Shellder 2.0 - Aegis AIO Setup"
echo "  By The Pokemod Group"
echo "  https://pokemod.dev/"
echo "======================================"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  print_error "Please run this script as root (e.g., sudo bash Shellder/setup.sh)"
  exit 1
fi

# Get the original user who called sudo (to fix file ownership later)
# Check if REAL_USER was passed from shellder.sh (preferred), otherwise use SUDO_USER
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
  # REAL_USER was passed from shellder.sh - use it
  # REAL_GROUP should also be set, but verify
  if [ -z "$REAL_GROUP" ]; then
    REAL_GROUP=$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")
  fi
elif [ -n "$SUDO_USER" ]; then
  # Running directly with sudo - use SUDO_USER
  REAL_USER="$SUDO_USER"
  REAL_GROUP=$(id -gn "$SUDO_USER")
else
  # Fallback - try to get the actual user
  REAL_USER="$USER"
  REAL_GROUP=$(id -gn)
fi

# Ensure we have a valid user (not root or empty)
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
  # Last resort: check who owns the script directory
  DIR_OWNER=$(stat -c '%U' "$PWD" 2>/dev/null || ls -ld "$PWD" | awk '{print $3}')
  if [ -n "$DIR_OWNER" ] && [ "$DIR_OWNER" != "root" ]; then
    REAL_USER="$DIR_OWNER"
    REAL_GROUP=$(id -gn "$DIR_OWNER" 2>/dev/null || echo "$DIR_OWNER")
  fi
fi

# Track if user needs to re-login for docker group
NEEDS_RELOGIN=false

# Track all files modified by this script for ownership restoration
MODIFIED_FILES=()

# Function to track file modifications and restore ownership later
track_file() {
    local file="$1"
    # Only track if file exists and we have a real user
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        MODIFIED_FILES+=("$file")
    fi
}

# Function to restore ownership on all tracked files
restore_all_ownership() {
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        print_info "Restoring file ownership to user '$REAL_USER'..."
        
        # Restore ownership on all tracked files
        for file in "${MODIFIED_FILES[@]}"; do
            if [ -e "$file" ]; then
                chown "$REAL_USER:$REAL_GROUP" "$file" 2>/dev/null || true
            fi
        done
        
        # Explicitly fix ownership on specific config files that are commonly modified
        local files_to_fix=(
            ".env"
            "Shellder/setup.sh"
            "shellder.sh"
            "README.md"
            "docker-compose.yaml"
            "docker-compose.yml"
            "fletchling.toml"
            "reactmap/local.json"
            "reactmap/env"
            "unown/dragonite_config.toml"
            "unown/golbat_config.toml"
            "unown/rotom_config.json"
            "unown/proxies.txt"
            "mysql_data/mariadb.cnf"
            "Poracle/config/local.json"
            "Poracle/geofence/default.json"
            "init/01.sql"
            "vmagent/prometheus.yml"
            "grafana/Dragonite-Emi-v5.json"
        )
        
        for file in "${files_to_fix[@]}"; do
            if [ -e "$file" ]; then
                chown "$REAL_USER:$REAL_GROUP" "$file" 2>/dev/null || true
            fi
        done
        
        # Recursively fix ownership on directories and their contents
        local dirs_to_fix_recursive=(
            "unown"
            "reactmap"
            "Poracle"
            "init"
            "vmagent"
            "fletchling"
        )
        
        for dir in "${dirs_to_fix_recursive[@]}"; do
            if [ -d "$dir" ]; then
                chown -R "$REAL_USER:$REAL_GROUP" "$dir" 2>/dev/null || true
            fi
        done
        
        # Fix ownership on directories only (not recursive - these may have Docker-managed contents)
        local dirs_to_fix=(
            "."
            "mysql_data"
            "grafana"
            "victoriametrics"
            "victoriametrics/data"
        )
        
        for dir in "${dirs_to_fix[@]}"; do
            if [ -d "$dir" ]; then
                chown "$REAL_USER:$REAL_GROUP" "$dir" 2>/dev/null || true
            fi
        done
        
        # Fix ownership on all shell scripts in Shellder directory
        for script in Shellder/*.sh; do
            if [ -f "$script" ]; then
                chown "$REAL_USER:$REAL_GROUP" "$script" 2>/dev/null || true
            fi
        done
        # Also fix shellder.sh in root
        chown "$REAL_USER:$REAL_GROUP" shellder.sh 2>/dev/null || true
        
        # Fix ownership on all root-level config files
        for config in *.toml *.yaml *.yml *.json *.md *.txt; do
            if [ -f "$config" ]; then
                chown "$REAL_USER:$REAL_GROUP" "$config" 2>/dev/null || true
            fi
        done
        
        print_success "File ownership restored."
    fi
}

# Set up trap to restore ownership on exit (catches errors, interrupts, etc.)
cleanup_on_exit() {
    # Only run cleanup if we have a valid user
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        # Quick ownership fix on common files
        chown "$REAL_USER:$REAL_GROUP" .env shellder.sh README.md docker-compose.yaml 2>/dev/null || true
        chown "$REAL_USER:$REAL_GROUP" Shellder/*.sh *.md *.yaml *.yml *.toml *.json *.txt 2>/dev/null || true
        chown -R "$REAL_USER:$REAL_GROUP" unown reactmap Poracle 2>/dev/null || true
    fi
}
trap cleanup_on_exit EXIT

# =============================================================================
# Port Checking Functions
# =============================================================================

# Stack service ports to check
declare -A STACK_PORTS=(
    ["6001"]="ReactMap (Web UI)"
    ["6002"]="Dragonite Admin"
    ["6003"]="Rotom UI"
    ["6004"]="Koji"
    ["6005"]="phpMyAdmin"
    ["6006"]="Grafana"
    ["7070"]="Rotom Device Connection"
    ["5090"]="Xilriws"
)

# Optional ports (commented services)
declare -A OPTIONAL_PORTS=(
    ["6007"]="Poracle"
    ["9042"]="Fletchling"
)

# Function to check if a port is in use
check_port_in_use() {
    local port=$1
    if command -v ss &> /dev/null; then
        ss -tuln 2>/dev/null | grep -q ":${port} " && return 0
    elif command -v netstat &> /dev/null; then
        netstat -tuln 2>/dev/null | grep -q ":${port} " && return 0
    elif command -v lsof &> /dev/null; then
        lsof -i ":${port}" &> /dev/null && return 0
    fi
    return 1
}

# Function to get process using a port
get_port_process() {
    local port=$1
    local result=""
    
    if command -v ss &> /dev/null; then
        result=$(ss -tulnp 2>/dev/null | grep ":${port} " | awk '{print $NF}' | head -1)
    elif command -v netstat &> /dev/null; then
        result=$(netstat -tulnp 2>/dev/null | grep ":${port} " | awk '{print $NF}' | head -1)
    elif command -v lsof &> /dev/null; then
        result=$(lsof -i ":${port}" -t 2>/dev/null | head -1)
        if [ -n "$result" ]; then
            local pname=$(ps -p "$result" -o comm= 2>/dev/null)
            result="pid=$result ($pname)"
        fi
    fi
    
    echo "$result"
}

# Function to get PID from process info
extract_pid() {
    local proc_info="$1"
    # Extract PID from formats like "users:((\"docker-proxy\",pid=1234,fd=4))" or "pid=1234"
    # Using sed for portability (grep -oP not available on all systems)
    echo "$proc_info" | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1
}

# Function to check all ports and handle conflicts
check_all_ports() {
    local ports_in_use=()
    local port_details=()
    
    print_info "Checking port availability for stack services..."
    echo ""
    
    # Check required ports
    for port in "${!STACK_PORTS[@]}"; do
        if check_port_in_use "$port"; then
            ports_in_use+=("$port")
            local proc=$(get_port_process "$port")
            port_details+=("$port:${STACK_PORTS[$port]}:$proc")
        fi
    done
    
    # If no ports are in use, we're good
    if [ ${#ports_in_use[@]} -eq 0 ]; then
        print_success "All required ports are available!"
        echo ""
        echo "  ┌─────────────────────────────────────────────────────────┐"
        echo "  │              PORT AVAILABILITY CHECK                    │"
        echo "  ├─────────────────────────────────────────────────────────┤"
        for port in $(echo "${!STACK_PORTS[@]}" | tr ' ' '\n' | sort -n); do
            printf "  │  Port %-5s %-30s ${GREEN}FREE${NC}   │\n" "$port" "${STACK_PORTS[$port]}"
        done
        echo "  └─────────────────────────────────────────────────────────┘"
        echo ""
        return 0
    fi
    
    # Show port conflict report
    print_warning "Port conflicts detected!"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────────┐"
    echo "  │                    PORT AVAILABILITY CHECK                          │"
    echo "  ├─────────────────────────────────────────────────────────────────────┤"
    for port in $(echo "${!STACK_PORTS[@]}" | tr ' ' '\n' | sort -n); do
        if [[ " ${ports_in_use[*]} " =~ " ${port} " ]]; then
            local proc=$(get_port_process "$port")
            printf "  │  Port %-5s %-25s ${RED}IN USE${NC}  %-15s │\n" "$port" "${STACK_PORTS[$port]}" "$proc"
        else
            printf "  │  Port %-5s %-25s ${GREEN}FREE${NC}                    │\n" "$port" "${STACK_PORTS[$port]}"
        fi
    done
    echo "  └─────────────────────────────────────────────────────────────────────┘"
    echo ""
    
    # Offer remediation options
    echo "  The following ports are in use and need to be freed:"
    echo ""
    for detail in "${port_details[@]}"; do
        IFS=':' read -r port service proc <<< "$detail"
        echo "    • Port $port ($service)"
        if [ -n "$proc" ]; then
            echo "      Used by: $proc"
        fi
    done
    echo ""
    
    # Check if nginx is using any ports
    local nginx_on_ports=false
    for detail in "${port_details[@]}"; do
        if [[ "$detail" == *"nginx"* ]]; then
            nginx_on_ports=true
            break
        fi
    done
    
    echo "  Options:"
    echo "    1) Attempt to stop processes using these ports"
    echo "    2) Stop existing Docker containers (docker compose down)"
    echo "    3) Investigate Docker containers bound to ports"
    echo "    4) Remove/purge old Docker containers"
    echo "    5) Clean Docker networks"
    echo "    6) Full Docker cleanup (containers + networks + volumes)"
    if [ "$nginx_on_ports" = true ]; then
    echo -e "    ${YELLOW}n) Fix Nginx port conflicts (nginx detected on ports)${NC}"
    fi
    echo "    7) Show detailed process information"
    echo "    8) Continue anyway (may cause startup failures)"
    echo "    9) Exit and resolve manually"
    echo ""
    read -p "  Select option [1-9${nginx_on_ports:+, n}, default: 2]: " PORT_ACTION
    PORT_ACTION=${PORT_ACTION:-2}
    
    case $PORT_ACTION in
        1)
            echo ""
            print_info "Attempting to stop processes on conflicting ports..."
            for port in "${ports_in_use[@]}"; do
                local proc=$(get_port_process "$port")
                local pid=$(extract_pid "$proc")
                if [ -n "$pid" ]; then
                    print_info "Stopping PID $pid (port $port)..."
                    kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
                    sleep 1
                    if check_port_in_use "$port"; then
                        print_warning "Could not free port $port - may need manual intervention"
                    else
                        print_success "Port $port freed!"
                    fi
                else
                    print_warning "Could not identify process for port $port"
                fi
            done
            # Re-check and show menu again if ports still in use
            sleep 1
            local remaining=()
            for port in "${ports_in_use[@]}"; do
                if check_port_in_use "$port"; then
                    remaining+=("$port")
                fi
            done
            if [ ${#remaining[@]} -gt 0 ]; then
                print_warning "Some ports still in use. Showing options again..."
                sleep 1
                check_all_ports
                return $?
            fi
            ;;
        2)
            echo ""
            print_info "Stopping Docker containers that may be using these ports..."
            
            # Stop containers by name (common Aegis containers)
            local containers=("reactmap" "admin" "dragonite" "golbat" "rotom" "koji" "pma" "grafana" "xilriws" "database" "vmagent" "victoriametrics" "poracle" "fletchling")
            for container in "${containers[@]}"; do
                if docker ps -q -f "name=$container" 2>/dev/null | grep -q .; then
                    print_info "Stopping container: $container"
                    docker stop "$container" 2>/dev/null || true
                fi
            done
            
            # Also try docker compose down if compose file exists
            if [ -f "docker-compose.yaml" ] || [ -f "docker-compose.yml" ]; then
                print_info "Running docker compose down..."
                docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true
            fi
            
            sleep 2
            
            # Re-check ports
            local still_in_use=()
            for port in "${ports_in_use[@]}"; do
                if check_port_in_use "$port"; then
                    still_in_use+=("$port")
                fi
            done
            
            if [ ${#still_in_use[@]} -eq 0 ]; then
                print_success "All ports are now free!"
            else
                print_warning "Some ports are still in use: ${still_in_use[*]}"
                print_info "Showing options again..."
                sleep 1
                check_all_ports
                return $?
            fi
            ;;
        3)
            echo ""
            print_info "Investigating Docker containers bound to ports..."
            echo ""
            
            # Show all containers with port bindings
            echo "  ${CYAN}All Docker containers with port mappings:${NC}"
            echo "  ─────────────────────────────────────────────────────────────────"
            docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | head -20
            echo ""
            
            # Check specifically for containers using our ports
            echo "  ${CYAN}Containers potentially using Aegis ports:${NC}"
            echo "  ─────────────────────────────────────────────────────────────────"
            for port in "${ports_in_use[@]}"; do
                local container_on_port=$(docker ps -a --filter "publish=${port}" --format "{{.Names}} ({{.Status}})" 2>/dev/null)
                if [ -n "$container_on_port" ]; then
                    echo "    Port $port: $container_on_port"
                else
                    # Check if docker-proxy is using this port
                    local proxy_check=$(ss -tulnp 2>/dev/null | grep ":${port} " | grep -o 'docker-proxy' || true)
                    if [ -n "$proxy_check" ]; then
                        echo "    Port $port: docker-proxy (orphaned or from old container)"
                    fi
                fi
            done
            echo ""
            
            # Show stopped containers that might have port conflicts
            local stopped_containers=$(docker ps -a --filter "status=exited" --filter "status=created" --format "{{.Names}}" 2>/dev/null)
            if [ -n "$stopped_containers" ]; then
                echo "  ${YELLOW}Stopped/Created containers (may have reserved ports):${NC}"
                echo "  ─────────────────────────────────────────────────────────────────"
                docker ps -a --filter "status=exited" --filter "status=created" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
                echo ""
            fi
            
            read -p "  Press Enter to continue..."
            check_all_ports
            return $?
            ;;
        4)
            echo ""
            print_info "Docker Container Removal Options"
            echo ""
            echo "  1) Remove only stopped Aegis containers"
            echo "  2) Remove ALL stopped containers"
            echo "  3) Force remove ALL Aegis containers (running + stopped)"
            echo "  4) Force remove ALL containers (running + stopped)"
            echo "  0) Back to previous menu"
            echo ""
            read -p "  Select option [0-4]: " REMOVE_OPTION
            
            case $REMOVE_OPTION in
                1)
                    echo ""
                    print_info "Removing stopped Aegis containers..."
                    local aegis_containers=("reactmap" "admin" "dragonite" "golbat" "rotom" "koji" "pma" "grafana" "xilriws" "database" "vmagent" "victoriametrics" "poracle" "fletchling")
                    for container in "${aegis_containers[@]}"; do
                        if docker ps -aq -f "name=^${container}$" -f "status=exited" 2>/dev/null | grep -q .; then
                            print_info "Removing: $container"
                            docker rm "$container" 2>/dev/null || true
                        fi
                    done
                    print_success "Stopped Aegis containers removed."
                    ;;
                2)
                    echo ""
                    print_info "Removing all stopped containers..."
                    docker container prune -f
                    print_success "All stopped containers removed."
                    ;;
                3)
                    echo ""
                    print_warning "This will FORCE STOP and REMOVE all Aegis containers!"
                    read -p "  Are you sure? (y/n) [n]: " CONFIRM
                    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                        local aegis_containers=("reactmap" "admin" "dragonite" "golbat" "rotom" "koji" "pma" "grafana" "xilriws" "database" "vmagent" "victoriametrics" "poracle" "fletchling")
                        for container in "${aegis_containers[@]}"; do
                            if docker ps -aq -f "name=^${container}$" 2>/dev/null | grep -q .; then
                                print_info "Force removing: $container"
                                docker rm -f "$container" 2>/dev/null || true
                            fi
                        done
                        print_success "All Aegis containers removed."
                    fi
                    ;;
                4)
                    echo ""
                    print_warning "This will FORCE STOP and REMOVE ALL Docker containers!"
                    read -p "  Are you sure? (y/n) [n]: " CONFIRM
                    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                        print_info "Stopping all containers..."
                        docker stop $(docker ps -aq) 2>/dev/null || true
                        print_info "Removing all containers..."
                        docker rm $(docker ps -aq) 2>/dev/null || true
                        print_success "All containers removed."
                    fi
                    ;;
            esac
            
            sleep 1
            check_all_ports
            return $?
            ;;
        5)
            echo ""
            print_info "Docker Network Cleanup"
            echo ""
            
            # Show current networks
            echo "  ${CYAN}Current Docker networks:${NC}"
            echo "  ─────────────────────────────────────────────────────────────────"
            docker network ls
            echo ""
            
            echo "  1) Remove unused networks (docker network prune)"
            echo "  2) Remove specific Aegis-related networks"
            echo "  3) Remove ALL custom networks (keeps bridge, host, none)"
            echo "  0) Back to previous menu"
            echo ""
            read -p "  Select option [0-3]: " NET_OPTION
            
            case $NET_OPTION in
                1)
                    echo ""
                    print_info "Removing unused networks..."
                    docker network prune -f
                    print_success "Unused networks removed."
                    ;;
                2)
                    echo ""
                    print_info "Looking for Aegis-related networks..."
                    local aegis_nets=$(docker network ls --filter "name=aegis" --filter "name=aio" -q 2>/dev/null)
                    if [ -n "$aegis_nets" ]; then
                        docker network rm $aegis_nets 2>/dev/null || true
                        print_success "Aegis networks removed."
                    else
                        print_info "No Aegis-specific networks found."
                    fi
                    # Also try to remove the default compose network
                    docker network rm aegis-all-in-one_default 2>/dev/null || true
                    ;;
                3)
                    echo ""
                    print_warning "This will remove ALL custom Docker networks!"
                    read -p "  Are you sure? (y/n) [n]: " CONFIRM
                    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                        # Get all network IDs except bridge, host, none
                        local custom_nets=$(docker network ls --format "{{.ID}} {{.Name}}" | grep -v -E "bridge|host|none" | awk '{print $1}')
                        if [ -n "$custom_nets" ]; then
                            docker network rm $custom_nets 2>/dev/null || true
                            print_success "Custom networks removed."
                        fi
                    fi
                    ;;
            esac
            
            sleep 1
            check_all_ports
            return $?
            ;;
        n|N)
            echo ""
            print_info "Nginx Port Conflict Resolution"
            echo ""
            
            # Find which ports nginx is using
            echo "  ${CYAN}Nginx processes detected on these ports:${NC}"
            echo "  ─────────────────────────────────────────────────────────────────"
            local nginx_on_7070=false
            for port in "${ports_in_use[@]}"; do
                local proc=$(get_port_process "$port")
                if [[ "$proc" == *"nginx"* ]]; then
                    echo "    Port $port: ${STACK_PORTS[$port]}"
                    if [ "$port" = "7070" ]; then
                        nginx_on_7070=true
                    fi
                fi
            done
            echo ""
            
            # Check for stream configuration (used for port 7070 WebSocket proxy)
            local stream_config_found=false
            local stream_config_path=""
            
            if [ -f "/etc/nginx/stream.d/rotom-devices.conf" ]; then
                stream_config_found=true
                stream_config_path="/etc/nginx/stream.d/rotom-devices.conf"
                echo -e "  ${YELLOW}⚠ Found Nginx STREAM proxy for port 7070:${NC}"
                echo "    $stream_config_path"
                echo ""
                echo "  This stream proxy makes nginx listen on port 7070 and forward"
                echo "  to Docker on an internal port (usually 17070)."
                echo ""
            fi
            
            # Check nginx.conf for embedded stream block
            if grep -q "listen 7070" /etc/nginx/nginx.conf 2>/dev/null; then
                stream_config_found=true
                stream_config_path="/etc/nginx/nginx.conf"
                echo -e "  ${YELLOW}⚠ Found port 7070 listener in nginx.conf${NC}"
                echo ""
            fi
            
            # Check nginx configuration
            echo "  ${CYAN}Checking Nginx site configurations...${NC}"
            if [ -d "/etc/nginx/sites-enabled" ]; then
                local aegis_configs=$(grep -l -r "7070\|6001\|6002\|6003\|6004\|6005\|6006\|5090" /etc/nginx/sites-enabled/ 2>/dev/null || true)
                if [ -n "$aegis_configs" ]; then
                    echo "  Found Aegis-related Nginx site configs:"
                    for config in $aegis_configs; do
                        echo "    • $config"
                    done
                    echo ""
                fi
            fi
            
            echo "  Options:"
            echo "    1) Stop Nginx service completely"
            echo "    2) Restart Nginx service"
            if [ "$nginx_on_7070" = true ]; then
            echo -e "    ${YELLOW}7) Remove Nginx port 7070 stream proxy (recommended for port 7070 issue)${NC}"
            fi
            echo "    3) Disable Aegis Nginx sites (move to sites-available)"
            echo "    4) Remove ALL Aegis Nginx configurations"
            echo "    5) View Nginx configuration for Aegis ports"
            echo "    6) Reload Nginx (apply config changes)"
            echo "    0) Back to previous menu"
            echo ""
            read -p "  Select option: " NGINX_OPTION
            
            case $NGINX_OPTION in
                1)
                    echo ""
                    print_info "Stopping Nginx..."
                    systemctl stop nginx 2>/dev/null || service nginx stop 2>/dev/null || killall nginx 2>/dev/null || true
                    sleep 2
                    if ! pgrep -x nginx > /dev/null; then
                        print_success "Nginx stopped."
                    else
                        print_warning "Nginx may still be running. Try: sudo systemctl stop nginx"
                    fi
                    ;;
                2)
                    echo ""
                    print_info "Restarting Nginx..."
                    systemctl restart nginx 2>/dev/null || service nginx restart 2>/dev/null || true
                    print_success "Nginx restart command sent."
                    ;;
                7)
                    echo ""
                    print_info "Removing Nginx port 7070 stream proxy..."
                    echo ""
                    
                    # Remove stream.d config file
                    if [ -f "/etc/nginx/stream.d/rotom-devices.conf" ]; then
                        print_info "Removing /etc/nginx/stream.d/rotom-devices.conf"
                        rm -f "/etc/nginx/stream.d/rotom-devices.conf"
                    fi
                    
                    # Remove any rotom stream configs
                    if [ -d "/etc/nginx/stream.d" ]; then
                        for conf in /etc/nginx/stream.d/*rotom* /etc/nginx/stream.d/*7070*; do
                            if [ -f "$conf" ]; then
                                print_info "Removing $conf"
                                rm -f "$conf"
                            fi
                        done
                    fi
                    
                    # Check and clean nginx.conf for stream blocks with 7070
                    if grep -q "listen 7070" /etc/nginx/nginx.conf 2>/dev/null; then
                        print_info "Found port 7070 in nginx.conf - creating backup and cleaning..."
                        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d%H%M%S)
                        
                        # Remove stream block containing 7070 from nginx.conf
                        # This is a simplified removal - may need manual editing for complex configs
                        sed -i '/stream {/,/^}/{ /listen 7070/d; }' /etc/nginx/nginx.conf 2>/dev/null || true
                        
                        # Also try to remove the entire stream block if it only contained 7070 config
                        # Check if stream block is now empty or only has whitespace
                        if grep -q "stream {" /etc/nginx/nginx.conf 2>/dev/null; then
                            local stream_content=$(sed -n '/stream {/,/^}/p' /etc/nginx/nginx.conf | grep -v "stream {" | grep -v "^}" | grep -v "^[[:space:]]*$" | grep -v "^[[:space:]]*#")
                            if [ -z "$stream_content" ]; then
                                print_info "Removing empty stream block from nginx.conf"
                                sed -i '/stream {/,/^}/d' /etc/nginx/nginx.conf 2>/dev/null || true
                            fi
                        fi
                    fi
                    
                    # Remove include directive for stream.d if directory is empty
                    if [ -d "/etc/nginx/stream.d" ] && [ -z "$(ls -A /etc/nginx/stream.d 2>/dev/null)" ]; then
                        print_info "stream.d directory is empty"
                    fi
                    
                    # Test nginx config
                    echo ""
                    print_info "Testing Nginx configuration..."
                    if nginx -t 2>&1; then
                        print_info "Reloading Nginx..."
                        systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
                        print_success "Nginx port 7070 stream proxy removed and nginx reloaded!"
                        echo ""
                        print_info "Docker should now be able to bind to port 7070 directly."
                        print_info "Devices will connect directly to your server on port 7070."
                    else
                        print_error "Nginx configuration test failed!"
                        print_info "Restoring backup..."
                        local latest_backup=$(ls -t /etc/nginx/nginx.conf.backup.* 2>/dev/null | head -1)
                        if [ -n "$latest_backup" ]; then
                            cp "$latest_backup" /etc/nginx/nginx.conf
                            print_info "Backup restored. Please check nginx configuration manually."
                        fi
                    fi
                    ;;
                3)
                    echo ""
                    print_info "Disabling Aegis Nginx sites..."
                    # Common Aegis nginx config names
                    local sites=("aegis" "aegis-reactmap" "aegis-admin" "aegis-rotom" "aegis-koji" "aegis-grafana" "aegis-pma" "rotom" "reactmap")
                    for site in "${sites[@]}"; do
                        if [ -f "/etc/nginx/sites-enabled/$site" ]; then
                            print_info "Disabling: $site"
                            mv "/etc/nginx/sites-enabled/$site" "/etc/nginx/sites-available/" 2>/dev/null || true
                        fi
                    done
                    # Also check for any config listening on our ports
                    if [ -d "/etc/nginx/sites-enabled" ]; then
                        for config in /etc/nginx/sites-enabled/*; do
                            if [ -f "$config" ] && grep -q "listen.*7070\|listen.*6001\|listen.*6002\|listen.*6003\|listen.*6004\|listen.*6005\|listen.*6006" "$config" 2>/dev/null; then
                                local basename=$(basename "$config")
                                print_info "Disabling: $basename (uses Aegis ports)"
                                mv "$config" "/etc/nginx/sites-available/" 2>/dev/null || true
                            fi
                        done
                    fi
                    print_info "Reloading Nginx..."
                    systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
                    print_success "Aegis Nginx sites disabled. Configs moved to /etc/nginx/sites-available/"
                    ;;
                4)
                    echo ""
                    print_warning "This will DELETE ALL Aegis-related Nginx configurations!"
                    print_warning "Including: site configs, stream proxies, and port 7070 proxy"
                    read -p "  Are you sure? (y/n) [n]: " CONFIRM
                    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                        # Remove site configs
                        local sites=("aegis" "aegis-reactmap" "aegis-admin" "aegis-rotom" "aegis-koji" "aegis-grafana" "aegis-pma" "rotom" "reactmap")
                        for site in "${sites[@]}"; do
                            rm -f "/etc/nginx/sites-enabled/$site" 2>/dev/null || true
                            rm -f "/etc/nginx/sites-available/$site" 2>/dev/null || true
                        done
                        
                        # Remove stream configs
                        rm -f /etc/nginx/stream.d/rotom-devices.conf 2>/dev/null || true
                        rm -f /etc/nginx/stream.d/*rotom* 2>/dev/null || true
                        rm -f /etc/nginx/stream.d/*aegis* 2>/dev/null || true
                        
                        # Remove any config with Aegis ports
                        if [ -d "/etc/nginx/sites-enabled" ]; then
                            for config in /etc/nginx/sites-enabled/* /etc/nginx/sites-available/*; do
                                if [ -f "$config" ] && grep -q "listen.*7070\|listen.*6001\|listen.*6002\|listen.*6003\|listen.*6004\|listen.*6005\|listen.*6006" "$config" 2>/dev/null; then
                                    print_info "Removing: $config"
                                    rm -f "$config" 2>/dev/null || true
                                fi
                            done
                        fi
                        
                        print_info "Testing and reloading Nginx..."
                        if nginx -t 2>&1; then
                            systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
                            print_success "All Aegis Nginx configurations removed."
                        else
                            print_warning "Nginx config test failed - may need manual intervention"
                        fi
                    fi
                    ;;
                5)
                    echo ""
                    print_info "Nginx configurations using Aegis ports:"
                    echo ""
                    
                    # Check stream configs first
                    if [ -d "/etc/nginx/stream.d" ]; then
                        echo "  ${CYAN}=== Stream Configurations (TCP/WebSocket proxies) ===${NC}"
                        for config in /etc/nginx/stream.d/*; do
                            if [ -f "$config" ]; then
                                echo "  ${YELLOW}$config:${NC}"
                                cat "$config" | sed 's/^/    /'
                                echo ""
                            fi
                        done
                    fi
                    
                    # Check nginx.conf for stream blocks
                    if grep -q "stream {" /etc/nginx/nginx.conf 2>/dev/null; then
                        echo "  ${CYAN}=== Stream block in nginx.conf ===${NC}"
                        sed -n '/stream {/,/^}/p' /etc/nginx/nginx.conf | sed 's/^/    /'
                        echo ""
                    fi
                    
                    # Check site configs
                    if [ -d "/etc/nginx/sites-enabled" ]; then
                        echo "  ${CYAN}=== Site Configurations ===${NC}"
                        for config in /etc/nginx/sites-enabled/*; do
                            if [ -f "$config" ]; then
                                local matches=$(grep -n "listen.*7070\|listen.*6001\|listen.*6002\|listen.*6003\|listen.*6004\|listen.*6005\|listen.*6006\|proxy_pass.*600\|proxy_pass.*7070" "$config" 2>/dev/null || true)
                                if [ -n "$matches" ]; then
                                    echo "  ${YELLOW}$config:${NC}"
                                    echo "$matches" | sed 's/^/    /'
                                    echo ""
                                fi
                            fi
                        done
                    fi
                    read -p "  Press Enter to continue..."
                    ;;
                6)
                    echo ""
                    print_info "Testing Nginx configuration..."
                    nginx -t 2>&1
                    echo ""
                    print_info "Reloading Nginx..."
                    systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
                    print_success "Nginx reloaded."
                    ;;
            esac
            
            sleep 1
            check_all_ports
            return $?
            ;;
        6)
            echo ""
            echo -e "  ${RED}${BOLD}Full Docker Cleanup${NC}"
            echo ""
            echo "  This will remove:"
            echo "    • All Aegis containers (running and stopped)"
            echo "    • All unused Docker networks"
            echo "    • All unused Docker volumes"
            echo "    • All dangling images"
            echo ""
            print_warning "This is a destructive operation!"
            read -p "  Are you sure? (y/n) [n]: " CONFIRM
            
            if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                echo ""
                
                # Stop and remove Aegis containers
                print_info "Stopping Aegis containers..."
                docker compose down 2>/dev/null || true
                
                local aegis_containers=("reactmap" "admin" "dragonite" "golbat" "rotom" "koji" "pma" "grafana" "xilriws" "database" "vmagent" "victoriametrics" "poracle" "fletchling")
                for container in "${aegis_containers[@]}"; do
                    docker rm -f "$container" 2>/dev/null || true
                done
                print_success "Containers removed."
                
                # Remove networks
                print_info "Removing unused networks..."
                docker network prune -f 2>/dev/null || true
                print_success "Networks cleaned."
                
                # Remove volumes (with extra confirmation)
                read -p "  Also remove Docker volumes? (DATABASE DATA WILL BE LOST) (y/n) [n]: " REMOVE_VOLS
                if [ "$REMOVE_VOLS" = "y" ] || [ "$REMOVE_VOLS" = "Y" ]; then
                    print_info "Removing unused volumes..."
                    docker volume prune -f 2>/dev/null || true
                    print_success "Volumes cleaned."
                fi
                
                # Clean dangling images
                print_info "Removing dangling images..."
                docker image prune -f 2>/dev/null || true
                print_success "Images cleaned."
                
                echo ""
                print_success "Full Docker cleanup complete!"
            fi
            
            sleep 1
            check_all_ports
            return $?
            ;;
        7)
            echo ""
            print_info "Detailed process information for ports in use:"
            echo ""
            for port in "${ports_in_use[@]}"; do
                echo "  ═══ Port $port (${STACK_PORTS[$port]}) ═══"
                if command -v ss &> /dev/null; then
                    ss -tulnp 2>/dev/null | grep ":${port} " | head -3
                elif command -v netstat &> /dev/null; then
                    netstat -tulnp 2>/dev/null | grep ":${port} " | head -3
                elif command -v lsof &> /dev/null; then
                    lsof -i ":${port}" 2>/dev/null | head -5
                fi
                echo ""
            done
            read -p "  Press Enter to continue..."
            # Recursively call to show options again
            check_all_ports
            return $?
            ;;
        8)
            print_warning "Continuing with port conflicts. Services may fail to start!"
            ;;
        9)
            print_info "Exiting. Please free the following ports and re-run setup:"
            for port in "${ports_in_use[@]}"; do
                echo "    • Port $port (${STACK_PORTS[$port]})"
            done
            echo ""
            echo "  Commands that may help:"
            echo "    • sudo lsof -i :PORT      - Show what's using a port"
            echo "    • sudo kill -9 PID        - Force stop a process"
            echo "    • docker compose down     - Stop all Docker containers"
            echo "    • docker rm -f CONTAINER  - Force remove a container"
            echo "    • docker network prune    - Remove unused networks"
            echo "    • sudo systemctl stop SERVICE  - Stop a system service"
            exit 1
            ;;
        *)
            print_warning "Invalid option. Continuing anyway..."
            ;;
    esac
    
    echo ""
    return 0
}

# Required Chrome version for compatibility with scanning tools
REQUIRED_CHROME_VERSION="125.0.6422.141"
CHROME_DEB_URL="https://github.com/NDViet/google-chrome-stable/releases/download/125.0.6422.141-1/google-chrome-stable_125.0.6422.141-1_amd64.deb"

# =============================================================================
# Step 1: Check/Install Docker and Docker Compose
# =============================================================================
echo "[1/9] Checking Docker installation..."
echo ""

# Function to detect package manager
detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
    else
        PKG_MANAGER="unknown"
    fi
}

# Function to install Docker
install_docker() {
    print_info "Installing Docker..."
    
    detect_package_manager
    
    case $PKG_MANAGER in
        apt)
            # Remove old versions
            apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
            
            # Install prerequisites
            apt-get update -y
            apt-get install -y ca-certificates curl gnupg lsb-release
            
            # Add Docker's official GPG key
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || \
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg
            
            # Set up repository
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
              $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
              tee /etc/apt/sources.list.d/docker.list > /dev/null 2>/dev/null || \
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
              $(lsb_release -cs) stable" | \
              tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # Install Docker
            apt-get update -y
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        dnf|yum)
            # Remove old versions
            $PKG_MANAGER remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
            
            # Install prerequisites
            $PKG_MANAGER install -y yum-utils
            
            # Add Docker repository
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || \
            yum-config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            
            # Install Docker
            $PKG_MANAGER install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        pacman)
            pacman -Sy --noconfirm docker docker-compose
            ;;
        *)
            print_error "Unsupported package manager. Please install Docker manually."
            print_info "Visit: https://docs.docker.com/engine/install/"
            return 1
            ;;
    esac
    
    # Start and enable Docker
    systemctl start docker
    systemctl enable docker
    
    if systemctl is-active --quiet docker; then
        print_success "Docker installed and started successfully!"
        return 0
    else
        print_error "Docker installation failed. Please install manually."
        return 1
    fi
}

# Function to check if user is in docker group
check_docker_group() {
    local user=$1
    if groups "$user" 2>/dev/null | grep -q '\bdocker\b'; then
        return 0
    else
        return 1
    fi
}

# Function to add user to docker group
add_user_to_docker_group() {
    local user=$1
    print_info "Adding user '$user' to docker group..."
    
    # Create docker group if it doesn't exist
    if ! getent group docker > /dev/null 2>&1; then
        groupadd docker
    fi
    
    # Add user to docker group
    usermod -aG docker "$user"
    
    if [ $? -eq 0 ]; then
        print_success "User '$user' added to docker group."
        return 0
    else
        print_error "Failed to add user to docker group."
        return 1
    fi
}

# Check if Docker is installed
DOCKER_INSTALLED=false
DOCKER_COMPOSE_AVAILABLE=false

if command -v docker &> /dev/null; then
    DOCKER_INSTALLED=true
    DOCKER_VERSION=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
    print_success "Docker is installed (version: $DOCKER_VERSION)"
else
    print_warning "Docker is NOT installed."
fi

# Check if Docker Compose is available (either plugin or standalone)
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE_AVAILABLE=true
    COMPOSE_VERSION=$(docker compose version --short 2>/dev/null)
    print_success "Docker Compose plugin is available (version: $COMPOSE_VERSION)"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_AVAILABLE=true
    COMPOSE_VERSION=$(docker-compose --version 2>/dev/null | awk '{print $4}' | tr -d ',')
    print_success "Docker Compose standalone is available (version: $COMPOSE_VERSION)"
    print_warning "Note: Consider upgrading to Docker Compose plugin (docker compose) for better compatibility."
else
    print_warning "Docker Compose is NOT available."
fi

# Check if Docker daemon is running
DOCKER_RUNNING=false
if [ "$DOCKER_INSTALLED" = true ]; then
    if systemctl is-active --quiet docker 2>/dev/null || docker info &> /dev/null; then
        DOCKER_RUNNING=true
        print_success "Docker daemon is running."
    else
        print_warning "Docker is installed but the daemon is not running."
    fi
fi

# Check if real user can use Docker (is in docker group)
DOCKER_ACCESSIBLE=false
if [ "$DOCKER_INSTALLED" = true ] && [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    if check_docker_group "$REAL_USER"; then
        DOCKER_ACCESSIBLE=true
        print_success "User '$REAL_USER' has Docker access (in docker group)."
    else
        print_warning "User '$REAL_USER' is NOT in the docker group."
        print_warning "They won't be able to run Docker commands without sudo."
    fi
elif [ "$REAL_USER" = "root" ]; then
    DOCKER_ACCESSIBLE=true
fi

echo ""

# Display Docker status summary
echo "  ┌─────────────────────────────────────────┐"
echo "  │           DOCKER STATUS SUMMARY         │"
echo "  ├─────────────────────────────────────────┤"
if [ "$DOCKER_INSTALLED" = true ]; then
    echo -e "  │  Docker Installed:    ${GREEN}YES${NC}               │"
else
    echo -e "  │  Docker Installed:    ${RED}NO${NC}                │"
fi
if [ "$DOCKER_COMPOSE_AVAILABLE" = true ]; then
    echo -e "  │  Docker Compose:      ${GREEN}YES${NC}               │"
else
    echo -e "  │  Docker Compose:      ${RED}NO${NC}                │"
fi
if [ "$DOCKER_RUNNING" = true ]; then
    echo -e "  │  Docker Running:      ${GREEN}YES${NC}               │"
else
    echo -e "  │  Docker Running:      ${RED}NO${NC}                │"
fi
if [ "$DOCKER_ACCESSIBLE" = true ]; then
    echo -e "  │  User Access:         ${GREEN}YES${NC}               │"
else
    echo -e "  │  User Access:         ${RED}NO${NC}                │"
fi
echo "  └─────────────────────────────────────────┘"
echo ""

# Install Docker if needed
if [ "$DOCKER_INSTALLED" = false ]; then
    read -p "  Docker is required. Install Docker now? (y/n) [y]: " INSTALL_DOCKER
    INSTALL_DOCKER=${INSTALL_DOCKER:-y}
    
    if [ "$INSTALL_DOCKER" = "y" ] || [ "$INSTALL_DOCKER" = "Y" ]; then
        if install_docker; then
            DOCKER_INSTALLED=true
            DOCKER_RUNNING=true
            DOCKER_COMPOSE_AVAILABLE=true
            # Reset DOCKER_ACCESSIBLE to re-check after fresh install
            DOCKER_ACCESSIBLE=false
        else
            print_error "Docker installation failed. Cannot continue."
            print_info "Please install Docker manually: https://docs.docker.com/engine/install/"
            exit 1
        fi
    else
        print_error "Docker is required for Aegis. Cannot continue without Docker."
        exit 1
    fi
fi

# Start Docker if not running
if [ "$DOCKER_INSTALLED" = true ] && [ "$DOCKER_RUNNING" = false ]; then
    print_info "Starting Docker daemon..."
    systemctl start docker
    if systemctl is-active --quiet docker; then
        DOCKER_RUNNING=true
        print_success "Docker daemon started."
    else
        print_error "Failed to start Docker daemon."
        print_info "Try: sudo systemctl start docker"
    fi
fi

# Enable Docker to start on boot
if [ "$DOCKER_INSTALLED" = true ]; then
    if ! systemctl is-enabled --quiet docker 2>/dev/null; then
        print_info "Enabling Docker to start on boot..."
        systemctl enable docker
        print_success "Docker will start automatically on boot."
    fi
fi

# Check/Add user to docker group for proper permissions
# This check runs after potential Docker installation to ensure fresh installs are covered
if [ "$DOCKER_INSTALLED" = true ] && [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    # Re-check docker group membership (important after fresh Docker install)
    if check_docker_group "$REAL_USER"; then
        DOCKER_ACCESSIBLE=true
    else
        DOCKER_ACCESSIBLE=false
    fi
    
    if [ "$DOCKER_ACCESSIBLE" = false ]; then
        echo ""
        print_info "Adding user '$REAL_USER' to docker group for proper permissions..."
        echo ""
        
        if add_user_to_docker_group "$REAL_USER"; then
            DOCKER_ACCESSIBLE=true
            NEEDS_RELOGIN=true
            print_success "User '$REAL_USER' added to docker group!"
            echo ""
            echo -e "  ${YELLOW}╔════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "  ${YELLOW}║${NC}  ${WHITE}IMPORTANT: You must log out and back in after setup completes${NC}    ${YELLOW}║${NC}"
            echo -e "  ${YELLOW}║${NC}  ${DIM}This activates your new docker group membership${NC}                  ${YELLOW}║${NC}"
            echo -e "  ${YELLOW}║${NC}                                                                    ${YELLOW}║${NC}"
            echo -e "  ${YELLOW}║${NC}  ${WHITE}After logging back in, you can run docker without sudo:${NC}          ${YELLOW}║${NC}"
            echo -e "  ${YELLOW}║${NC}    ${CYAN}docker compose up -d${NC}                                            ${YELLOW}║${NC}"
            echo -e "  ${YELLOW}║${NC}    ${CYAN}docker ps${NC}                                                        ${YELLOW}║${NC}"
            echo -e "  ${YELLOW}╚════════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
        else
            print_warning "Could not add user to docker group automatically."
            print_info "You can add yourself manually with:"
            echo -e "    ${CYAN}sudo usermod -aG docker $REAL_USER${NC}"
            echo ""
        fi
    else
        print_success "User '$REAL_USER' is already in docker group."
    fi
elif [ "$REAL_USER" = "root" ]; then
    DOCKER_ACCESSIBLE=true
    print_info "Running as root - docker group membership not required."
fi

# Verify Docker Compose after potential installation
if [ "$DOCKER_COMPOSE_AVAILABLE" = false ] && [ "$DOCKER_INSTALLED" = true ]; then
    # Check again after Docker installation
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE_AVAILABLE=true
        print_success "Docker Compose plugin is now available."
    else
        print_warning "Docker Compose is still not available."
        print_info "You may need to install it separately."
        print_info "Visit: https://docs.docker.com/compose/install/"
    fi
fi

echo ""

# Install sqlite3 for Shellder database (config storage)
if ! command -v sqlite3 &> /dev/null; then
    print_info "Installing sqlite3 for configuration storage..."
    case "$PKG_MANAGER" in
        apt)
            apt-get install -y sqlite3 >/dev/null 2>&1 && print_success "sqlite3 installed" || print_warning "Could not install sqlite3 (non-critical)"
            ;;
        dnf|yum)
            $PKG_MANAGER install -y sqlite >/dev/null 2>&1 && print_success "sqlite3 installed" || print_warning "Could not install sqlite3 (non-critical)"
            ;;
        pacman)
            pacman -S --noconfirm sqlite >/dev/null 2>&1 && print_success "sqlite3 installed" || print_warning "Could not install sqlite3 (non-critical)"
            ;;
    esac
fi

# =============================================================================
# Step 1b: Check Port Availability for Stack Services
# =============================================================================
echo "[1b/9] Checking port availability for stack services..."
echo ""

check_all_ports

# =============================================================================
# Step 2: Configure Docker Logging (Recommended)
# =============================================================================
echo "[2/9] Configuring Docker logging..."
echo ""

# Docker can generate massive log files. Configure log rotation to prevent disk space issues.
print_info "Docker containers can generate large log files that may fill up disk space."
print_info "Configuring log rotation is recommended to prevent this issue."
echo ""

DAEMON_JSON="/etc/docker/daemon.json"
CONFIGURE_LOGGING=false
EXISTING_CONFIG=false

# Check if daemon.json already exists
if [ -f "$DAEMON_JSON" ]; then
    EXISTING_CONFIG=true
    print_warning "Existing Docker daemon configuration found at $DAEMON_JSON"
    
    # Check if logging is already configured
    if grep -q '"log-driver"' "$DAEMON_JSON" 2>/dev/null; then
        print_info "Log configuration already exists in daemon.json:"
        echo ""
        cat "$DAEMON_JSON"
        echo ""
        read -p "  Overwrite existing log configuration? (y/n) [n]: " OVERWRITE_LOGS
        OVERWRITE_LOGS=${OVERWRITE_LOGS:-n}
        if [ "$OVERWRITE_LOGS" = "y" ] || [ "$OVERWRITE_LOGS" = "Y" ]; then
            CONFIGURE_LOGGING=true
        else
            print_info "Keeping existing Docker log configuration."
        fi
    else
        read -p "  Add log rotation configuration to existing daemon.json? (y/n) [y]: " ADD_LOGS
        ADD_LOGS=${ADD_LOGS:-y}
        if [ "$ADD_LOGS" = "y" ] || [ "$ADD_LOGS" = "Y" ]; then
            CONFIGURE_LOGGING=true
        fi
    fi
else
    read -p "  Configure Docker log rotation? (Recommended) (y/n) [y]: " SETUP_LOGS
    SETUP_LOGS=${SETUP_LOGS:-y}
    if [ "$SETUP_LOGS" = "y" ] || [ "$SETUP_LOGS" = "Y" ]; then
        CONFIGURE_LOGGING=true
    fi
fi

if [ "$CONFIGURE_LOGGING" = true ]; then
    echo ""
    echo "  Docker Log Configuration Options"
    echo "  ─────────────────────────────────"
    echo ""
    
    # Log driver selection
    echo "  Select log driver:"
    echo "    1) json-file (default, recommended)"
    echo "    2) local (faster, but less features)"
    echo "    3) journald (uses systemd journal)"
    echo "    4) none (disable logging - not recommended)"
    echo ""
    read -p "  Log driver [1-4, default: 1]: " LOG_DRIVER_CHOICE
    LOG_DRIVER_CHOICE=${LOG_DRIVER_CHOICE:-1}
    
    case $LOG_DRIVER_CHOICE in
        1) LOG_DRIVER="json-file" ;;
        2) LOG_DRIVER="local" ;;
        3) LOG_DRIVER="journald" ;;
        4) LOG_DRIVER="none" ;;
        *) LOG_DRIVER="json-file" ;;
    esac
    
    print_info "Selected log driver: $LOG_DRIVER"
    echo ""
    
    # Only prompt for log-opts if using json-file or local driver
    if [ "$LOG_DRIVER" = "json-file" ] || [ "$LOG_DRIVER" = "local" ]; then
        # Max size per log file
        echo "  Maximum size per log file (e.g., 10m, 50m, 100m, 500m, 1g)"
        echo "  Smaller = more rotations, larger = fewer rotations"
        read -p "  Max log file size [default: 100m]: " LOG_MAX_SIZE
        LOG_MAX_SIZE=${LOG_MAX_SIZE:-100m}
        
        # Validate format (number followed by k, m, or g)
        if ! echo "$LOG_MAX_SIZE" | grep -qE '^[0-9]+[kmgKMG]$'; then
            print_warning "Invalid format. Using default: 100m"
            LOG_MAX_SIZE="100m"
        fi
        
        echo ""
        
        # Max number of log files to keep
        echo "  Maximum number of log files to keep per container"
        echo "  Total space per container = max-size × max-file"
        read -p "  Max log files [default: 3]: " LOG_MAX_FILE
        LOG_MAX_FILE=${LOG_MAX_FILE:-3}
        
        # Validate number
        if ! echo "$LOG_MAX_FILE" | grep -qE '^[0-9]+$'; then
            print_warning "Invalid number. Using default: 3"
            LOG_MAX_FILE="3"
        fi
        
        # Calculate and display total size
        # Extract number and unit from LOG_MAX_SIZE
        SIZE_NUM=$(echo "$LOG_MAX_SIZE" | sed 's/[^0-9]//g')
        SIZE_UNIT=$(echo "$LOG_MAX_SIZE" | sed 's/[0-9]//g' | tr '[:upper:]' '[:lower:]')
        TOTAL_SIZE=$((SIZE_NUM * LOG_MAX_FILE))
        
        echo ""
        echo "  ┌─────────────────────────────────────────────────────────┐"
        echo "  │              DOCKER LOG CONFIGURATION                   │"
        echo "  ├─────────────────────────────────────────────────────────┤"
        printf "  │  Log Driver:            %-30s │\n" "$LOG_DRIVER"
        printf "  │  Max Size per File:     %-30s │\n" "$LOG_MAX_SIZE"
        printf "  │  Max Files per Container: %-28s │\n" "$LOG_MAX_FILE"
        printf "  │  Total per Container:   %-30s │\n" "${TOTAL_SIZE}${SIZE_UNIT}"
        echo "  └─────────────────────────────────────────────────────────┘"
        echo ""
        
        # Compression option (only for json-file)
        if [ "$LOG_DRIVER" = "json-file" ]; then
            read -p "  Enable log compression? (y/n) [y]: " ENABLE_COMPRESSION
            ENABLE_COMPRESSION=${ENABLE_COMPRESSION:-y}
            if [ "$ENABLE_COMPRESSION" = "y" ] || [ "$ENABLE_COMPRESSION" = "Y" ]; then
                COMPRESS_LOGS="true"
            else
                COMPRESS_LOGS="false"
            fi
        else
            COMPRESS_LOGS="true"
        fi
        
        # Build daemon.json content
        if [ "$LOG_DRIVER" = "json-file" ]; then
            DAEMON_CONTENT=$(cat <<EOF
{
  "log-driver": "$LOG_DRIVER",
  "log-opts": {
    "max-size": "$LOG_MAX_SIZE",
    "max-file": "$LOG_MAX_FILE",
    "compress": "$COMPRESS_LOGS"
  }
}
EOF
)
        else
            # local driver doesn't support compress option
            DAEMON_CONTENT=$(cat <<EOF
{
  "log-driver": "$LOG_DRIVER",
  "log-opts": {
    "max-size": "$LOG_MAX_SIZE",
    "max-file": "$LOG_MAX_FILE"
  }
}
EOF
)
        fi
    else
        # journald or none - no log-opts needed
        echo ""
        echo "  ┌─────────────────────────────────────────────────────────┐"
        echo "  │              DOCKER LOG CONFIGURATION                   │"
        echo "  ├─────────────────────────────────────────────────────────┤"
        printf "  │  Log Driver:            %-30s │\n" "$LOG_DRIVER"
        if [ "$LOG_DRIVER" = "journald" ]; then
        echo "  │  Note: Logs managed by systemd journal                 │"
        else
        echo "  │  Warning: Logging disabled - not recommended!          │"
        fi
        echo "  └─────────────────────────────────────────────────────────┘"
        echo ""
        
        DAEMON_CONTENT=$(cat <<EOF
{
  "log-driver": "$LOG_DRIVER"
}
EOF
)
    fi
    
    # Handle existing daemon.json - merge or replace
    if [ "$EXISTING_CONFIG" = true ] && [ -f "$DAEMON_JSON" ]; then
        # Backup existing config
        BACKUP_FILE="${DAEMON_JSON}.backup.$(date +%Y%m%d%H%M%S)"
        cp "$DAEMON_JSON" "$BACKUP_FILE"
        print_info "Backed up existing config to: $BACKUP_FILE"
        
        # Check if we need to merge with existing non-logging config
        if ! grep -q '"log-driver"' "$DAEMON_JSON" 2>/dev/null; then
            # Try to merge using simple JSON manipulation
            # Remove closing brace from existing, add comma, add our config
            EXISTING_CONTENT=$(cat "$DAEMON_JSON")
            if echo "$EXISTING_CONTENT" | grep -q '{' && echo "$EXISTING_CONTENT" | grep -q '}'; then
                # Has valid JSON structure, try to merge
                # This is a simple merge - may not work for complex configs
                print_warning "Attempting to merge with existing configuration..."
                print_warning "Please verify the resulting daemon.json manually."
            fi
        fi
    fi
    
    # Write the new daemon.json
    print_info "Writing Docker daemon configuration..."
    echo "$DAEMON_CONTENT" > "$DAEMON_JSON"
    
    if [ $? -eq 0 ]; then
        # Note: daemon.json is a system file, ownership stays as root
        print_success "Docker daemon configuration written to $DAEMON_JSON"
        echo ""
        echo "  Configuration:"
        cat "$DAEMON_JSON"
        echo ""
        
        # Restart Docker to apply changes
        print_info "Restarting Docker to apply log configuration..."
        
        if systemctl restart docker 2>/dev/null; then
            # Wait a moment for Docker to fully restart
            sleep 2
            
            if systemctl is-active --quiet docker; then
                print_success "Docker restarted successfully with new log configuration!"
                DOCKER_RUNNING=true
            else
                print_error "Docker failed to start after restart."
                print_info "Check the configuration with: sudo dockerd --validate"
                print_info "View Docker logs with: sudo journalctl -xeu docker"
                
                # Offer to restore backup
                if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
                    read -p "  Restore previous configuration? (y/n) [y]: " RESTORE_BACKUP
                    RESTORE_BACKUP=${RESTORE_BACKUP:-y}
                    if [ "$RESTORE_BACKUP" = "y" ] || [ "$RESTORE_BACKUP" = "Y" ]; then
                        cp "$BACKUP_FILE" "$DAEMON_JSON"
                        systemctl restart docker
                        print_info "Previous configuration restored."
                    fi
                fi
            fi
        else
            print_warning "Could not restart Docker automatically."
            print_info "Please restart Docker manually: sudo systemctl restart docker"
        fi
    else
        print_error "Failed to write Docker daemon configuration."
        print_info "You may need to configure logging manually."
    fi
else
    print_info "Skipping Docker log configuration."
fi

echo ""

# =============================================================================
# Step 3: Check/Install Google Chrome (Specific Version)
# =============================================================================
echo "[3/9] Checking Google Chrome installation..."
echo ""

# Function to get Chrome version
get_chrome_version() {
    if command -v google-chrome &> /dev/null; then
        google-chrome --version 2>/dev/null | awk '{print $3}'
    elif command -v google-chrome-stable &> /dev/null; then
        google-chrome-stable --version 2>/dev/null | awk '{print $3}'
    elif [ -f /usr/bin/google-chrome ]; then
        /usr/bin/google-chrome --version 2>/dev/null | awk '{print $3}'
    else
        echo ""
    fi
}

# Function to install specific Chrome version
install_chrome_version() {
    print_info "Installing Google Chrome version $REQUIRED_CHROME_VERSION..."
    
    detect_package_manager
    
    if [ "$PKG_MANAGER" != "apt" ]; then
        print_warning "Chrome installation is only supported on Debian/Ubuntu systems."
        print_info "Please install Chrome $REQUIRED_CHROME_VERSION manually."
        return 1
    fi
    
    # Install dependencies
    apt-get update -y
    apt-get install -y wget fonts-liberation libasound2 libatk-bridge2.0-0 libatk1.0-0 \
        libatspi2.0-0 libcups2 libdbus-1-3 libdrm2 libgbm1 libgtk-3-0 libnspr4 \
        libnss3 libwayland-client0 libxcomposite1 libxdamage1 libxfixes3 \
        libxkbcommon0 libxrandr2 xdg-utils 2>/dev/null || true
    
    # Download Chrome .deb
    CHROME_DEB="/tmp/chrome.deb"
    print_info "Downloading Chrome from: $CHROME_DEB_URL"
    
    if wget -q -O "$CHROME_DEB" "$CHROME_DEB_URL"; then
        # Install the .deb package
        if dpkg -i "$CHROME_DEB" 2>/dev/null; then
            print_success "Chrome $REQUIRED_CHROME_VERSION installed successfully!"
            rm -f "$CHROME_DEB"
            return 0
        else
            # Fix broken dependencies
            apt-get install -f -y
            if dpkg -i "$CHROME_DEB"; then
                print_success "Chrome $REQUIRED_CHROME_VERSION installed successfully!"
                rm -f "$CHROME_DEB"
                return 0
            else
                print_error "Failed to install Chrome package."
                rm -f "$CHROME_DEB"
                return 1
            fi
        fi
    else
        print_error "Failed to download Chrome package."
        print_info "URL: $CHROME_DEB_URL"
        return 1
    fi
}

# Function to disable Chrome auto-updates
disable_chrome_updates() {
    print_info "Disabling Chrome auto-updates to maintain version compatibility..."
    
    # Method 1: Create repository override file
    cat > /etc/apt/preferences.d/google-chrome << EOF
# Prevent Google Chrome from being updated
# Required version: $REQUIRED_CHROME_VERSION for scanner compatibility
Package: google-chrome-stable
Pin: version $REQUIRED_CHROME_VERSION*
Pin-Priority: 1001
EOF
    
    # Method 2: Remove Google Chrome repo if it exists
    if [ -f /etc/apt/sources.list.d/google-chrome.list ]; then
        mv /etc/apt/sources.list.d/google-chrome.list /etc/apt/sources.list.d/google-chrome.list.disabled 2>/dev/null || true
        print_info "Disabled Google Chrome repository."
    fi
    
    # Method 3: Hold the package
    if command -v apt-mark &> /dev/null; then
        apt-mark hold google-chrome-stable 2>/dev/null || true
    fi
    
    print_success "Chrome auto-updates disabled."
    print_info "Chrome will stay at version $REQUIRED_CHROME_VERSION"
}

# Check current Chrome version
CURRENT_CHROME_VERSION=$(get_chrome_version)
CHROME_INSTALLED=false
CHROME_CORRECT_VERSION=false

if [ -n "$CURRENT_CHROME_VERSION" ]; then
    CHROME_INSTALLED=true
    print_success "Google Chrome is installed (version: $CURRENT_CHROME_VERSION)"
    
    # Compare versions (just the major.minor.build.patch)
    if [ "$CURRENT_CHROME_VERSION" = "$REQUIRED_CHROME_VERSION" ]; then
        CHROME_CORRECT_VERSION=true
        print_success "Chrome version matches required version!"
    else
        print_warning "Chrome version mismatch!"
        print_warning "  Installed: $CURRENT_CHROME_VERSION"
        print_warning "  Required:  $REQUIRED_CHROME_VERSION"
    fi
else
    print_warning "Google Chrome is NOT installed."
fi

echo ""

# Display Chrome status summary
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │              GOOGLE CHROME STATUS                       │"
echo "  ├─────────────────────────────────────────────────────────┤"
if [ "$CHROME_INSTALLED" = true ]; then
    echo -e "  │  Chrome Installed:     ${GREEN}YES${NC}                            │"
    printf "  │  Current Version:      %-30s │\n" "$CURRENT_CHROME_VERSION"
else
    echo -e "  │  Chrome Installed:     ${RED}NO${NC}                             │"
    echo "  │  Current Version:      N/A                            │"
fi
printf "  │  Required Version:     %-30s │\n" "$REQUIRED_CHROME_VERSION"
if [ "$CHROME_CORRECT_VERSION" = true ]; then
    echo -e "  │  Version Match:        ${GREEN}YES${NC}                            │"
else
    echo -e "  │  Version Match:        ${RED}NO${NC}                             │"
fi
echo "  └─────────────────────────────────────────────────────────┘"
echo ""

# Handle Chrome installation/update
if [ "$CHROME_CORRECT_VERSION" = false ]; then
    echo "  Google Chrome $REQUIRED_CHROME_VERSION is required for scanner compatibility."
    echo "  This specific version ensures ChromeDriver compatibility with scanning tools."
    echo ""
    
    if [ "$CHROME_INSTALLED" = true ]; then
        read -p "  Replace current Chrome with required version? (y/n) [y]: " INSTALL_CHROME
    else
        read -p "  Install Google Chrome $REQUIRED_CHROME_VERSION? (y/n) [y]: " INSTALL_CHROME
    fi
    INSTALL_CHROME=${INSTALL_CHROME:-y}
    
    if [ "$INSTALL_CHROME" = "y" ] || [ "$INSTALL_CHROME" = "Y" ]; then
        # Remove existing Chrome if present
        if [ "$CHROME_INSTALLED" = true ]; then
            print_info "Removing current Chrome installation..."
            apt-get remove -y google-chrome-stable 2>/dev/null || true
        fi
        
        if install_chrome_version; then
            CHROME_INSTALLED=true
            CHROME_CORRECT_VERSION=true
            disable_chrome_updates
        else
            print_warning "Chrome installation failed. You may need to install manually."
            print_info "Download URL: $CHROME_DEB_URL"
        fi
    else
        print_warning "Skipping Chrome installation."
        print_warning "Scanner tools may not work correctly without Chrome $REQUIRED_CHROME_VERSION"
    fi
else
    # Chrome is correct version, ensure updates are disabled
    print_info "Ensuring Chrome updates are disabled..."
    disable_chrome_updates
fi

echo ""

# =============================================================================
# Step 4: Detect System Resources
# =============================================================================
echo "[4/9] Detecting system resources..."
echo ""

# Detect RAM (in MB)
if [ -f /proc/meminfo ]; then
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
    TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))
else
    # Fallback for systems without /proc/meminfo
    TOTAL_RAM_MB=4096
    TOTAL_RAM_GB=4
    print_warning "Could not detect RAM, assuming 4GB"
fi

# Detect CPU cores
if command -v nproc &> /dev/null; then
    CPU_CORES=$(nproc)
elif [ -f /proc/cpuinfo ]; then
    CPU_CORES=$(grep -c processor /proc/cpuinfo)
else
    CPU_CORES=4
    print_warning "Could not detect CPU cores, assuming 4"
fi

# Display detected resources
echo "  ┌─────────────────────────────────────────┐"
echo "  │         DETECTED SYSTEM RESOURCES       │"
echo "  ├─────────────────────────────────────────┤"
printf "  │  RAM:       %-4s GB (%s MB)          │\n" "$TOTAL_RAM_GB" "$TOTAL_RAM_MB"
printf "  │  CPU Cores: %-4s                       │\n" "$CPU_CORES"
echo "  └─────────────────────────────────────────┘"
echo ""

# Ask about storage type
echo "  What type of storage does your server have?"
echo ""
echo "  1) SSD (Solid State Drive) - Most common, fast"
echo "  2) NVMe SSD - Very fast (M.2 slot)"
echo "  3) HDD (Hard Disk Drive) - Older, spinning disk"
echo "  4) Cloud/VPS (Unknown) - Use balanced settings"
echo ""
read -p "  Select storage type [1-4, default: 1]: " STORAGE_TYPE
STORAGE_TYPE=${STORAGE_TYPE:-1}

case $STORAGE_TYPE in
    1) 
        STORAGE_NAME="SSD"
        IO_CAPACITY=1000
        IO_CAPACITY_MAX=4000
        ;;
    2)
        STORAGE_NAME="NVMe SSD"
        IO_CAPACITY=4000
        IO_CAPACITY_MAX=10000
        ;;
    3)
        STORAGE_NAME="HDD"
        IO_CAPACITY=150
        IO_CAPACITY_MAX=400
        ;;
    4|*)
        STORAGE_NAME="Cloud/VPS"
        IO_CAPACITY=500
        IO_CAPACITY_MAX=2000
        ;;
esac

print_success "Storage type: $STORAGE_NAME"
echo ""

# =============================================================================
# Step 5: Calculate Optimal MariaDB Settings
# =============================================================================
echo "[5/9] Calculating optimal MariaDB settings..."
echo ""

# Calculate InnoDB Buffer Pool Size
# Rule: 25-40% of RAM when sharing with other services (Golbat, etc.)
# We'll use 30% as a safe default
BUFFER_POOL_MB=$((TOTAL_RAM_MB * 30 / 100))

# Round to nearest GB for cleaner values, minimum 512M
if [ $BUFFER_POOL_MB -lt 512 ]; then
    BUFFER_POOL_SIZE="512M"
    BUFFER_POOL_GB=0
elif [ $BUFFER_POOL_MB -lt 1024 ]; then
    BUFFER_POOL_SIZE="512M"
    BUFFER_POOL_GB=0
elif [ $BUFFER_POOL_MB -lt 1536 ]; then
    BUFFER_POOL_SIZE="1G"
    BUFFER_POOL_GB=1
elif [ $BUFFER_POOL_MB -lt 2560 ]; then
    BUFFER_POOL_SIZE="2G"
    BUFFER_POOL_GB=2
elif [ $BUFFER_POOL_MB -lt 3584 ]; then
    BUFFER_POOL_SIZE="3G"
    BUFFER_POOL_GB=3
elif [ $BUFFER_POOL_MB -lt 4608 ]; then
    BUFFER_POOL_SIZE="4G"
    BUFFER_POOL_GB=4
elif [ $BUFFER_POOL_MB -lt 6144 ]; then
    BUFFER_POOL_SIZE="5G"
    BUFFER_POOL_GB=5
elif [ $BUFFER_POOL_MB -lt 7168 ]; then
    BUFFER_POOL_SIZE="6G"
    BUFFER_POOL_GB=6
elif [ $BUFFER_POOL_MB -lt 8192 ]; then
    BUFFER_POOL_SIZE="7G"
    BUFFER_POOL_GB=7
elif [ $BUFFER_POOL_MB -lt 10240 ]; then
    BUFFER_POOL_SIZE="8G"
    BUFFER_POOL_GB=8
elif [ $BUFFER_POOL_MB -lt 12288 ]; then
    BUFFER_POOL_SIZE="10G"
    BUFFER_POOL_GB=10
elif [ $BUFFER_POOL_MB -lt 16384 ]; then
    BUFFER_POOL_SIZE="12G"
    BUFFER_POOL_GB=12
else
    BUFFER_POOL_SIZE="16G"
    BUFFER_POOL_GB=16
fi

# Calculate Buffer Pool Instances (1 per GB, max 8)
if [ $BUFFER_POOL_GB -le 1 ]; then
    BUFFER_POOL_INSTANCES=1
elif [ $BUFFER_POOL_GB -ge 8 ]; then
    BUFFER_POOL_INSTANCES=8
else
    BUFFER_POOL_INSTANCES=$BUFFER_POOL_GB
fi

# Calculate I/O Threads (CPU cores / 2, minimum 2, maximum 8)
IO_THREADS=$((CPU_CORES / 2))
[ $IO_THREADS -lt 2 ] && IO_THREADS=2
[ $IO_THREADS -gt 8 ] && IO_THREADS=8

# Calculate max connections (based on RAM, more RAM = more connections possible)
if [ $TOTAL_RAM_GB -le 2 ]; then
    MAX_CONNECTIONS=100
elif [ $TOTAL_RAM_GB -le 4 ]; then
    MAX_CONNECTIONS=200
elif [ $TOTAL_RAM_GB -le 8 ]; then
    MAX_CONNECTIONS=300
elif [ $TOTAL_RAM_GB -le 16 ]; then
    MAX_CONNECTIONS=500
else
    MAX_CONNECTIONS=750
fi

# Calculate tmp_table_size based on RAM
if [ $TOTAL_RAM_GB -le 2 ]; then
    TMP_TABLE_SIZE="64M"
elif [ $TOTAL_RAM_GB -le 4 ]; then
    TMP_TABLE_SIZE="128M"
elif [ $TOTAL_RAM_GB -le 8 ]; then
    TMP_TABLE_SIZE="256M"
else
    TMP_TABLE_SIZE="512M"
fi

# Calculate log file size (larger for bigger systems)
if [ $TOTAL_RAM_GB -le 4 ]; then
    LOG_FILE_SIZE="256M"
elif [ $TOTAL_RAM_GB -le 8 ]; then
    LOG_FILE_SIZE="512M"
elif [ $TOTAL_RAM_GB -le 16 ]; then
    LOG_FILE_SIZE="768M"
else
    LOG_FILE_SIZE="1G"
fi

# Display calculated settings
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │           CALCULATED MARIADB SETTINGS                   │"
echo "  ├─────────────────────────────────────────────────────────┤"
printf "  │  innodb_buffer_pool_size:      %-8s                │\n" "$BUFFER_POOL_SIZE"
printf "  │  innodb_buffer_pool_instances: %-8s                │\n" "$BUFFER_POOL_INSTANCES"
printf "  │  innodb_read_io_threads:       %-8s                │\n" "$IO_THREADS"
printf "  │  innodb_write_io_threads:      %-8s                │\n" "$IO_THREADS"
printf "  │  innodb_purge_threads:         %-8s                │\n" "$IO_THREADS"
printf "  │  innodb_io_capacity:           %-8s                │\n" "$IO_CAPACITY"
printf "  │  innodb_io_capacity_max:       %-8s                │\n" "$IO_CAPACITY_MAX"
printf "  │  max_connections:              %-8s                │\n" "$MAX_CONNECTIONS"
printf "  │  tmp_table_size:               %-8s                │\n" "$TMP_TABLE_SIZE"
printf "  │  innodb_log_file_size:         %-8s                │\n" "$LOG_FILE_SIZE"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""

# Ask for confirmation
read -p "  Apply these settings to MariaDB config? (y/n) [y]: " APPLY_DB_SETTINGS
APPLY_DB_SETTINGS=${APPLY_DB_SETTINGS:-y}

if [ "$APPLY_DB_SETTINGS" = "y" ] || [ "$APPLY_DB_SETTINGS" = "Y" ]; then
    # Update mariadb.cnf with calculated values
    MARIADB_CNF="mysql_data/mariadb.cnf"
    
    if [ -f "$MARIADB_CNF" ]; then
        print_info "Applying optimized settings to $MARIADB_CNF..."
        
        # Replace the settings using sed
        sed -i "s/^innodb_buffer_pool_size = .*/innodb_buffer_pool_size = $BUFFER_POOL_SIZE/" "$MARIADB_CNF"
        sed -i "s/^innodb_buffer_pool_instances = .*/innodb_buffer_pool_instances = $BUFFER_POOL_INSTANCES/" "$MARIADB_CNF"
        sed -i "s/^innodb_read_io_threads = .*/innodb_read_io_threads = $IO_THREADS/" "$MARIADB_CNF"
        sed -i "s/^innodb_write_io_threads = .*/innodb_write_io_threads = $IO_THREADS/" "$MARIADB_CNF"
        sed -i "s/^innodb_purge_threads = .*/innodb_purge_threads = $IO_THREADS/" "$MARIADB_CNF"
        sed -i "s/^innodb_io_capacity = .*/innodb_io_capacity = $IO_CAPACITY/" "$MARIADB_CNF"
        sed -i "s/^innodb_io_capacity_max = .*/innodb_io_capacity_max = $IO_CAPACITY_MAX/" "$MARIADB_CNF"
        sed -i "s/^max_connections = .*/max_connections = $MAX_CONNECTIONS/" "$MARIADB_CNF"
        sed -i "s/^tmp_table_size = .*/tmp_table_size = $TMP_TABLE_SIZE/" "$MARIADB_CNF"
        sed -i "s/^max_heap_table_size = .*/max_heap_table_size = $TMP_TABLE_SIZE/" "$MARIADB_CNF"
        sed -i "s/^innodb_log_file_size = .*/innodb_log_file_size = $LOG_FILE_SIZE/" "$MARIADB_CNF"
        
        # Add a comment at the top noting when it was configured
        CONFIG_DATE=$(date '+%Y-%m-%d %H:%M:%S')
        sed -i "1a # Auto-configured on $CONFIG_DATE for: ${TOTAL_RAM_GB}GB RAM, ${CPU_CORES} CPU cores, $STORAGE_NAME storage" "$MARIADB_CNF"
        
        # Track for ownership restoration
        track_file "$MARIADB_CNF"
        
        print_success "MariaDB settings optimized for your hardware!"
    else
        print_warning "mariadb.cnf not found at $MARIADB_CNF - skipping optimization"
    fi
else
    print_info "Skipping MariaDB optimization. Using default settings."
fi

echo ""

# =============================================================================
# Step 6: Create required directories with proper permissions
# =============================================================================
echo "[6/9] Creating directories and copying config files..."

# Get user's UID/GID for directory permissions
# Get PUID/PGID from .env if exists, otherwise use current user's IDs
# This ensures containers can write to mounted volumes
if [ -f ".env" ]; then
    source .env
fi
CONTAINER_UID="${PUID:-$(id -u "$REAL_USER" 2>/dev/null || echo "1000")}"
CONTAINER_GID="${PGID:-$(id -g "$REAL_USER" 2>/dev/null || echo "1000")}"

print_info "Creating data directories with proper permissions..."
print_info "Using PUID:PGID = $CONTAINER_UID:$CONTAINER_GID for container volumes"

# Function to fix directory permissions
fix_directory_permissions() {
    local dir="$1"
    mkdir -p "$dir"
    # Use sudo if available and needed (directories may be root-owned)
    if command -v sudo &>/dev/null; then
        sudo chown -R "$CONTAINER_UID:$CONTAINER_GID" "$dir" 2>/dev/null || chown -R "$CONTAINER_UID:$CONTAINER_GID" "$dir" 2>/dev/null || true
        sudo chmod -R 775 "$dir" 2>/dev/null || chmod -R 775 "$dir" 2>/dev/null || true
    else
        chown -R "$CONTAINER_UID:$CONTAINER_GID" "$dir" 2>/dev/null || true
        chmod -R 775 "$dir" 2>/dev/null || true
    fi
}

# Grafana directory - container runs as PUID:PGID
fix_directory_permissions "grafana"

# VictoriaMetrics directories
fix_directory_permissions "victoriametrics/data"

# vmagent directory
fix_directory_permissions "vmagent/data"

# MySQL data directory (special - MariaDB handles its own permissions)
mkdir -p mysql_data

# Unown directories (logs, cache, jobs)
fix_directory_permissions "unown/logs"
fix_directory_permissions "unown/golbat_cache"
fix_directory_permissions "unown/rotom_jobs"

# Shellder data directory
fix_directory_permissions "Shellder/data"
fix_directory_permissions "Shellder/logs"

# Verify permissions were set correctly
perm_issues=0
for dir in grafana victoriametrics/data vmagent/data unown/logs Shellder/data; do
    if [ -d "$dir" ]; then
        owner_uid=$(stat -c '%u' "$dir" 2>/dev/null || echo "unknown")
        if [ "$owner_uid" != "$CONTAINER_UID" ]; then
            print_warning "$dir ownership mismatch (is $owner_uid, should be $CONTAINER_UID)"
            ((perm_issues++))
        fi
    fi
done

if [ $perm_issues -gt 0 ]; then
    print_warning "$perm_issues directories may have permission issues"
    print_info "Run: sudo chown -R $CONTAINER_UID:$CONTAINER_GID grafana victoriametrics vmagent unown Shellder/data Shellder/logs"
else
    print_success "Directories created with PUID:PGID ownership ($CONTAINER_UID:$CONTAINER_GID)"
fi

# Force copy with -f to overwrite any existing files
cp -f env-default .env && track_file ".env"
cp -f reactmap/local-default.json reactmap/local.json && track_file "reactmap/local.json"
cp -f unown/dragonite_config-default.toml unown/dragonite_config.toml && track_file "unown/dragonite_config.toml"
cp -f unown/golbat_config-default.toml unown/golbat_config.toml && track_file "unown/golbat_config.toml"
cp -f unown/rotom_config-default.json unown/rotom_config.json && track_file "unown/rotom_config.json"

print_success "Config files copied."
echo ""

# =============================================================================
# Step 7: Generate/prompt for secrets and passwords
# =============================================================================
echo "[7/9] Configuring secrets and passwords..."
echo "      (Press enter to auto-generate random values)"
echo ""

# Function to generate random string
generate_random() {
    local length=$1
    local charset=$2
    openssl rand -base64 48 | tr -dc "$charset" | fold -w "$length" | head -n 1
}

# Database credentials
read -p "  DB_USER [auto-generate]: " DB_USER
[ -z "$DB_USER" ] && DB_USER=$(generate_random 16 'a-zA-Z0-9')

read -p "  DB_PASSWORD [auto-generate]: " DB_PASSWORD
[ -z "$DB_PASSWORD" ] && DB_PASSWORD=$(generate_random 32 'a-zA-Z0-9')

read -p "  MYSQL_ROOT_PASSWORD [auto-generate]: " MYSQL_ROOT_PASSWORD
[ -z "$MYSQL_ROOT_PASSWORD" ] && MYSQL_ROOT_PASSWORD=$(generate_random 32 'a-zA-Z0-9')

# Service secrets
read -p "  KOJI_BEARER [auto-generate]: " KOJI_BEARER
[ -z "$KOJI_BEARER" ] && KOJI_BEARER=$(generate_random 32 'a-zA-Z0-9')

read -p "  GOLBAT_RAW_SECRET [auto-generate]: " GOLBAT_RAW_SECRET
[ -z "$GOLBAT_RAW_SECRET" ] && GOLBAT_RAW_SECRET=$(generate_random 32 'a-zA-Z0-9')

read -p "  GOLBAT_API_SECRET [auto-generate]: " GOLBAT_API_SECRET
[ -z "$GOLBAT_API_SECRET" ] && GOLBAT_API_SECRET=$(generate_random 32 'a-zA-Z0-9')

read -p "  SESSION_SECRET [auto-generate]: " SESSION_SECRET
[ -z "$SESSION_SECRET" ] && SESSION_SECRET=$(generate_random 40 'a-zA-Z0-9')

read -p "  REACTMAP_SECRET [auto-generate]: " REACTMAP_SECRET
[ -z "$REACTMAP_SECRET" ] && REACTMAP_SECRET=$(generate_random 40 'a-zA-Z0-9')

read -p "  ROTOM_AUTH_BEARER [auto-generate]: " ROTOM_AUTH_BEARER
[ -z "$ROTOM_AUTH_BEARER" ] && ROTOM_AUTH_BEARER=$(generate_random 32 'a-zA-Z0-9')

read -p "  DRAGONITE_PASSWORD [auto-generate]: " DRAGONITE_PASSWORD
[ -z "$DRAGONITE_PASSWORD" ] && DRAGONITE_PASSWORD=$(generate_random 32 'a-zA-Z0-9')

read -p "  DRAGONITE_API_SECRET [auto-generate]: " DRAGONITE_API_SECRET
[ -z "$DRAGONITE_API_SECRET" ] && DRAGONITE_API_SECRET=$(generate_random 32 'a-zA-Z0-9')

read -p "  PORACLE_API_SECRET [auto-generate]: " PORACLE_API_SECRET
[ -z "$PORACLE_API_SECRET" ] && PORACLE_API_SECRET=$(generate_random 32 'a-zA-Z0-9')

echo ""
print_info "Applying secrets to config files..."

# Replace defaults in config files
# IMPORTANT: Replace password BEFORE username since "dbuser" appears inside "SuperSecuredbuserPassword"

# DB password (must be done before DB user)
sed -i "s/SuperSecuredbuserPassword/${DB_PASSWORD}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json init/01.sql
sed -i "s/CHANGE_ME/${DB_PASSWORD}/g" Poracle/config/local.json

# DB user
sed -i "s/dbuser/${DB_USER}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json Poracle/config/local.json init/01.sql

# MySQL root password
sed -i "s/V3ryS3cUr3MYSQL_ROOT_P4ssw0rd/${MYSQL_ROOT_PASSWORD}/g" .env

# Update PUID/PGID to match current user (important for Grafana, etc.)
sed -i "s/^PUID=.*/PUID=${CONTAINER_UID}/" .env
sed -i "s/^PGID=.*/PGID=${CONTAINER_GID}/" .env

# Koji bearer token
sed -i "s/SuperSecureKojiSecret/${KOJI_BEARER}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# Golbat secrets
sed -i "s/SuperSecureGolbatRawSecret/${GOLBAT_RAW_SECRET}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json
sed -i "s/SuperSecureGolbatApiSecret/${GOLBAT_API_SECRET}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# ReactMap secrets
sed -i 's/98ki^e72~!@#(85o3kXLI*#c9wu5l!ZUGA/'"${SESSION_SECRET}"'/g' reactmap/local.json
sed -i 's/98ki^e72~!@#(85o3kXLI*#c9wu5l!Zx10venikyoa0/'"${REACTMAP_SECRET}"'/g' reactmap/local.json

# Rotom device secret
sed -i "s/SuperSecretAuthBearerForAegisDevices/${ROTOM_AUTH_BEARER}/g" unown/rotom_config.json

# Dragonite secrets
sed -i "s/SuperSecureDragoniteAdminPassword/${DRAGONITE_PASSWORD}/g" .env
sed -i "s/SuperSecureDragoniteApiSecret/${DRAGONITE_API_SECRET}/g" .env

# Poracle API secret (used by ReactMap to communicate with Poracle)
sed -i "s/SuperSecurePoracleApiSecret/${PORACLE_API_SECRET}/g" reactmap/local.json

# Track Poracle config file and init SQL
track_file "Poracle/config/local.json"
track_file "init/01.sql"

# NOTE: Config values will be stored AFTER database validation completes
# This ensures only working credentials are saved to the Shellder database

# Restore file ownership to the original user (not root)
restore_all_ownership

print_success "Secrets applied to all config files."
echo ""

# =============================================================================
# Step 8: MariaDB installation (optional)
# =============================================================================
echo "[8/9] Database setup..."

if ! command -v mysql &> /dev/null; then
  read -p "      MariaDB not found. Install it now? (y/n): " INSTALL_CHOICE
  if [ "$INSTALL_CHOICE" = "y" ] || [ "$INSTALL_CHOICE" = "Y" ]; then
    print_info "Installing MariaDB..."
    detect_package_manager
    case $PKG_MANAGER in
        apt)
    apt update -y
            apt install -y mariadb-server
            ;;
        dnf|yum)
            $PKG_MANAGER install -y mariadb-server
            systemctl start mariadb
            systemctl enable mariadb
            ;;
        pacman)
            pacman -Sy --noconfirm mariadb
            mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
            systemctl start mariadb
            systemctl enable mariadb
            ;;
        *)
            print_error "Unsupported package manager. Please install MariaDB manually."
            SKIP_DB_SETUP=true
            ;;
    esac
    
    if [ "$SKIP_DB_SETUP" != "true" ]; then
    # Set root password on fresh install
        mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD'; FLUSH PRIVILEGES;" 2>/dev/null
    if [ $? -eq 0 ]; then
          print_success "MariaDB installed and root password set."
    else
          print_warning "Could not set root password. You may need to configure MariaDB manually."
        fi
    fi
  else
    print_info "Skipping MariaDB installation."
    print_info "Docker's MariaDB container will be used instead."
    SKIP_DB_SETUP=true
  fi
else
  print_success "MariaDB is already installed."
fi

# =============================================================================
# Step 9: Create databases
# =============================================================================
if [ "$SKIP_DB_SETUP" != "true" ]; then
  echo ""
  echo "[9/9] Creating databases..."

  read -p "      DB root username (default: root): " ROOT_USER
  [ -z "$ROOT_USER" ] && ROOT_USER="root"

  # Databases to create
  DBS=("dragonite" "golbat" "reactmap" "koji" "poracle")

  # Build SQL
  SQL=""
  for db in "${DBS[@]}"; do
    SQL+="CREATE DATABASE IF NOT EXISTS \`$db\`; "
  done

  # Create the application DB user with the credentials from config
  SQL+="CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD'; "
  SQL+="GRANT ALL PRIVILEGES ON *.* TO '$DB_USER'@'%' WITH GRANT OPTION; "
  SQL+="FLUSH PRIVILEGES; "

  # Execute SQL
  echo "$SQL" | mysql -u"$ROOT_USER" -p"$MYSQL_ROOT_PASSWORD" -h localhost 2>/dev/null

  if [ $? -eq 0 ]; then
    print_success "Databases created: ${DBS[*]}"
    print_success "DB user '$DB_USER' created with full privileges."
  else
    print_warning "Could not create databases. Docker's MariaDB will handle this on first run."
  fi
else
  echo ""
  echo "[9/9] Setting up database user for Docker MariaDB..."
  print_info "Database will be configured when containers start."
  
  # Check if containers are already running
  if docker ps --filter "name=database" --format "{{.Names}}" 2>/dev/null | grep -q "database"; then
    print_info "Database container is running. Configuring user now..."
    
    # Wait a moment for DB to be ready
    sleep 2
    
    # Detect MySQL client command (MariaDB 12+ uses 'mariadb' instead of 'mysql')
    MYSQL_CMD="mariadb"
    if ! docker exec database which mariadb &>/dev/null; then
      MYSQL_CMD="mysql"
    fi
    
    # Check if user already exists
    USER_EXISTS=$(docker exec database $MYSQL_CMD -u root -p"$MYSQL_ROOT_PASSWORD" -N -e "SELECT COUNT(*) FROM mysql.user WHERE User='$DB_USER'" 2>/dev/null)
    
    if [ "${USER_EXISTS:-0}" -gt 0 ]; then
      print_info "User '$DB_USER' already exists in database."
      
      # Try to authenticate with the provided password
      if docker exec database $MYSQL_CMD -u "$DB_USER" -p"$DB_PASSWORD" -e "SELECT 1" 2>/dev/null; then
        print_success "Password matches. User '$DB_USER' is ready."
      else
        print_warning "Password mismatch! The existing user has a different password."
        echo ""
        echo "  Options:"
        echo "    1) Update password in database to match config"
        echo "    2) Keep existing password (you'll need to update config files manually)"
        echo "    3) Skip - I'll fix this later"
        echo ""
        read -p "  Choice [1]: " pw_choice
        pw_choice=${pw_choice:-1}
        
        case $pw_choice in
          1)
            SQL="ALTER USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD'; FLUSH PRIVILEGES;"
            if docker exec database $MYSQL_CMD -u root -p"$MYSQL_ROOT_PASSWORD" -e "$SQL" 2>/dev/null; then
              print_success "Password updated for user '$DB_USER'."
            else
              print_error "Failed to update password. Run 'Shellder/dbsetup.sh' to fix manually."
            fi
            ;;
          2)
            print_warning "Config files have different password than database."
            print_warning "Update .env, reactmap/local.json, and unown/*.toml files manually."
            ;;
          *)
            print_info "Skipped. Run 'Shellder/dbsetup.sh' later to fix database user."
            ;;
        esac
      fi
      
      # Ensure grants are correct
      SQL="GRANT ALL PRIVILEGES ON *.* TO '$DB_USER'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;"
      docker exec database $MYSQL_CMD -u root -p"$MYSQL_ROOT_PASSWORD" -e "$SQL" 2>/dev/null
      
    else
      # User doesn't exist - create it
      print_info "Creating database user '$DB_USER'..."
      SQL="CREATE USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD'; "
      SQL+="GRANT ALL PRIVILEGES ON *.* TO '$DB_USER'@'%' WITH GRANT OPTION; "
      SQL+="FLUSH PRIVILEGES;"
      
      if docker exec database $MYSQL_CMD -u root -p"$MYSQL_ROOT_PASSWORD" -e "$SQL" 2>/dev/null; then
        print_success "DB user '$DB_USER' created with full privileges."
      else
        print_error "Could not create user. Run 'Shellder/dbsetup.sh' after setup completes."
      fi
    fi
    
    # Create databases if they don't exist
    DBS=("dragonite" "golbat" "reactmap" "koji" "poracle")
    for db in "${DBS[@]}"; do
      docker exec database $MYSQL_CMD -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS \`$db\`" 2>/dev/null
    done
    print_success "Databases verified: ${DBS[*]}"
    
    # Database credentials verified - now safe to store in Shellder database
    DB_CREDENTIALS_VERIFIED=true
    
  else
    print_info "Database container not running."
    print_info "After running 'docker compose up -d', the user will be created from init/01.sql"
    print_warning "If database already exists, run 'Shellder/dbsetup.sh' to create the user."
    DB_CREDENTIALS_VERIFIED=false
  fi
fi

# =============================================================================
# Store Verified Configuration Values
# =============================================================================
# Only store configs in Shellder database after they've been validated
# This ensures data integrity - only working credentials are saved

if [ "$DB_AVAILABLE" = "true" ]; then
    print_info "Storing validated configuration values..."
    
    # Initialize database if needed
    if ! check_shellder_db 2>/dev/null; then
        init_shellder_db 2>/dev/null
    fi
    
    stored_count=0
    skipped_count=0
    
    # Store database credentials only if verified
    if [ "$DB_CREDENTIALS_VERIFIED" = "true" ]; then
        # These credentials worked - safe to store
        store_config_value "MYSQL_USER" "$DB_USER" ".env" "Database username (verified)" 0
        store_config_value "MYSQL_PASSWORD" "$DB_PASSWORD" ".env" "Database password (verified)" 1
        store_config_value "MYSQL_ROOT_PASSWORD" "$MYSQL_ROOT_PASSWORD" ".env" "Root password (verified)" 1
        ((stored_count+=3))
        print_success "Database credentials stored (verified working)"
    else
        print_warning "Database credentials NOT stored (could not verify)"
        ((skipped_count+=3))
    fi
    
    # Store non-database configs (these don't require service validation)
    # But check they meet minimum requirements (not empty, not too short)
    
    # API tokens - validate minimum length for security
    for config_pair in \
        "KOJI_SECRET|$KOJI_BEARER|Koji API bearer token" \
        "GOLBAT_RAW_SECRET|$GOLBAT_RAW_SECRET|Golbat raw data secret" \
        "GOLBAT_API_SECRET|$GOLBAT_API_SECRET|Golbat API secret" \
        "DRAGONITE_PASSWORD|$DRAGONITE_PASSWORD|Dragonite admin password" \
        "DRAGONITE_API_SECRET|$DRAGONITE_API_SECRET|Dragonite API secret" \
        "ROTOM_AUTH_BEARER|$ROTOM_AUTH_BEARER|Rotom device auth token" \
        "PORACLE_API_SECRET|$PORACLE_API_SECRET|Poracle API secret"
    do
        IFS='|' read -r key value desc <<< "$config_pair"
        
        # Skip if value is empty or too short (less than 8 chars)
        if [ -z "$value" ] || [ ${#value} -lt 8 ]; then
            print_warning "Skipped $key (empty or too short)"
            ((skipped_count++)) || true
            continue
        fi
        
        # Skip if it's a default value
        if is_default_value "$key" "$value"; then
            print_warning "Skipped $key (default/template value)"
            ((skipped_count++)) || true
            continue
        fi
        
        store_config_value "$key" "$value" ".env" "$desc" 1
        ((stored_count++)) || true
    done
    
    # Store PUID/PGID (validate they're numbers)
    if [[ "$CONTAINER_UID" =~ ^[0-9]+$ ]]; then
        store_config_value "PUID" "$CONTAINER_UID" ".env" "Docker container user ID" 0
        ((stored_count++)) || true
    else
        print_warning "Skipped PUID (invalid: $CONTAINER_UID)"
        ((skipped_count++)) || true
    fi
    
    if [[ "$CONTAINER_GID" =~ ^[0-9]+$ ]]; then
        store_config_value "PGID" "$CONTAINER_GID" ".env" "Docker container group ID" 0
        ((stored_count++)) || true
    else
        print_warning "Skipped PGID (invalid: $CONTAINER_GID)"
        ((skipped_count++)) || true
    fi
    
    # Record setup event
    record_event "initial_setup" "setup.sh" "Setup completed: $stored_count configs stored, $skipped_count skipped" ""
    
    if [ $stored_count -gt 0 ]; then
        print_success "$stored_count configuration values stored for future reference"
    fi
    if [ $skipped_count -gt 0 ]; then
        print_warning "$skipped_count values skipped (could not validate)"
    fi
fi

# =============================================================================
# Final Ownership Restoration
# =============================================================================
# Ensure all files touched by this script are owned by the real user, not root
restore_all_ownership

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "======================================"
print_success "Setup Complete!"
echo "======================================"
echo ""
echo "  System Configuration Applied:"
echo "  ├── RAM: ${TOTAL_RAM_GB}GB detected"
echo "  ├── CPU: ${CPU_CORES} cores detected"
echo "  ├── Storage: ${STORAGE_NAME}"
echo "  ├── MariaDB buffer pool: ${BUFFER_POOL_SIZE}"
if [ "$DOCKER_INSTALLED" = true ]; then
echo "  ├── Docker: Installed and configured"
else
echo "  ├── Docker: Not installed"
fi
if [ "$CHROME_CORRECT_VERSION" = true ]; then
echo "  └── Chrome: $REQUIRED_CHROME_VERSION (updates disabled)"
else
echo "  └── Chrome: Not installed or wrong version"
fi
echo ""
echo "  Generated Credentials (save these!):"
echo "  ├── DB User: $DB_USER"
echo "  ├── DB Password: $DB_PASSWORD"
echo "  ├── MySQL Root Password: $MYSQL_ROOT_PASSWORD"
echo "  └── Rotom Auth Bearer: $ROTOM_AUTH_BEARER"
echo ""

if [ "$NEEDS_RELOGIN" = true ]; then
    echo ""
    print_warning "═══════════════════════════════════════════════════════════════"
    print_warning "  IMPORTANT: Log out and log back in for Docker access!"
    print_warning "  User '$REAL_USER' was added to the docker group."
    print_warning "  Group changes require a new login session to take effect."
    print_warning "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  After logging back in, run:"
    echo "    docker compose up -d --force-recreate --build"
    echo ""
else
    echo "  Next steps:"
echo "  1. Review config files for any manual changes needed"
echo "  2. Run: docker compose up -d --force-recreate --build"
    echo "  3. Access services at http://localhost:6001-6007"
    echo ""
fi

print_warning "IMPORTANT: Save the credentials above! They won't be shown again."
echo ""

# Return to main menu or exit
if [ "$SHELLDER_LAUNCHER" = "1" ]; then
    echo ""
    read -p "Press Enter to return to main menu..."
    return_to_main
fi
