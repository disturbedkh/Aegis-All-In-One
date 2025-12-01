#!/bin/bash

# =============================================================================
# Shellder - MariaDB Database Setup & Maintenance (for Aegis AIO services)
# =============================================================================
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  This script manages your MARIADB/MYSQL databases for Aegis AIO        │
# │                                                                         │
# │  Databases managed: dragonite, golbat, reactmap, koji, poracle          │
# │  Contains: Pokemon data, accounts, gyms, stops, raids, quests, etc.    │
# │                                                                         │
# │  NOTE: This is different from db_helper.sh which manages Shellder's    │
# │        own internal SQLite database (for stats and config tracking).   │
# └─────────────────────────────────────────────────────────────────────────┘
#
# This script has two modes:
#
#   SETUP MODE (First-time installation):
#     - MariaDB installation (if needed)
#     - System resource detection and MariaDB tuning
#     - Database creation (dragonite, golbat, reactmap, koji, poracle)
#     - User creation with proper permissions
#
#   MAINTENANCE MODE (Full MariaDB Management System):
#     Server & Monitoring:
#       - Server status dashboard (version, uptime, memory, queries)
#       - Active connections / process list with kill capability
#       - Performance tuning & recommendations
#     
#     Database Management:
#       - Database browser with query console
#       - Table browsing, structure, indexes
#       - Custom SQL query execution
#       - User & permission management
#       - Backup & restore (single or all databases)
#     
#     Aegis Data Maintenance:
#       - Account cleanup (banned, invalid, auth-banned)
#       - Map data cleanup (stale pokestops, gyms, spawnpoints)
#       - Nest management
#       - Table optimization (analyze, repair, optimize)
#     
#     Shellder Internal:
#       - Shellder's own SQLite database for stats/config tracking
#
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Print functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Box drawing characters
draw_box_top() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════╗${NC}"
}
draw_box_bottom() {
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════╝${NC}"
}
draw_box_divider() {
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════╣${NC}"
}
draw_box_line() {
    printf "${CYAN}║${NC} %-66s ${CYAN}║${NC}\n" "$1"
}
draw_box_line_colored() {
    # $1 = label, $2 = value, $3 = color
    printf "${CYAN}║${NC}  %-30s ${3}%-34s${NC} ${CYAN}║${NC}\n" "$1" "$2"
}

# Global variables
MYSQL_CMD=""
DBS=("dragonite" "golbat" "reactmap" "koji" "poracle")

# Source Shellder database helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/db_helper.sh" ]; then
    source "$SCRIPT_DIR/db_helper.sh"
fi

# Source Shellder logging helper
SHELLDER_SCRIPT_NAME="dbsetup.sh"
if [ -f "$SCRIPT_DIR/log_helper.sh" ]; then
    source "$SCRIPT_DIR/log_helper.sh"
    init_logging "dbsetup.sh"
    LOG_AVAILABLE=true
else
    LOG_AVAILABLE=false
fi

# Get the original user who called sudo (to prevent files being locked to root)
# Check if REAL_USER was passed from shellder.sh (preferred), otherwise use SUDO_USER
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    # REAL_USER was passed from shellder.sh - use it
    if [ -z "$REAL_GROUP" ]; then
        REAL_GROUP=$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")
    fi
elif [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    REAL_GROUP=$(id -gn "$SUDO_USER")
else
    REAL_USER="$USER"
    REAL_GROUP=$(id -gn)
fi

# Ensure we have a valid user
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    DIR_OWNER=$(stat -c '%U' "$PWD" 2>/dev/null || ls -ld "$PWD" | awk '{print $3}')
    if [ -n "$DIR_OWNER" ] && [ "$DIR_OWNER" != "root" ]; then
        REAL_USER="$DIR_OWNER"
        REAL_GROUP=$(id -gn "$DIR_OWNER" 2>/dev/null || echo "$DIR_OWNER")
    fi
fi

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run this script as root (e.g., sudo bash Shellder/dbsetup.sh)"
        [ "$LOG_AVAILABLE" = "true" ] && log_error "Script requires root privileges - current EUID: $EUID"
        echo ""
        echo "  Press Enter to return..."
        read -r
        exit 1
    fi
}

# Restore file ownership to original user
restore_ownership() {
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        chown "$REAL_USER:$REAL_GROUP" mysql_data/mariadb.cnf 2>/dev/null || true
        chown "$REAL_USER:$REAL_GROUP" .env 2>/dev/null || true
        chown "$REAL_USER:$REAL_GROUP" Shellder/*.sh *.yaml *.yml *.md 2>/dev/null || true
        chown -R "$REAL_USER:$REAL_GROUP" mysql_data 2>/dev/null || true
    fi
}

# Set up trap to restore ownership on exit
trap restore_ownership EXIT

load_env() {
    ENV_LOADED=false
    
    if [ ! -f ".env" ]; then
        print_warn ".env file not found - running in manual configuration mode"
        [ "$LOG_AVAILABLE" = "true" ] && log_warn "No .env file found - entering manual configuration mode"
        echo ""
        echo "  You can still use this script to:"
        echo "    • Install MariaDB"
        echo "    • Create databases and users manually"
        echo "    • Configure credentials interactively"
        echo ""
        
        # Set empty defaults - will prompt when needed
        MYSQL_ROOT_PASSWORD=""
        MYSQL_USER=""
        MYSQL_PASSWORD=""
        MYSQL_DATABASE=""
        
        sleep 2
        return 0
    fi

    # Source .env (skip UID/GID which are readonly bash variables)
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        [[ "$key" == "UID" ]] && continue
        [[ "$key" == "GID" ]] && continue
        # Remove quotes from value
        value="${value%\"}"
        value="${value#\"}"
        export "$key=$value"
    done < .env
    
    ENV_LOADED=true
}

# Prompt for MariaDB credentials if not set
prompt_db_credentials() {
    local need_prompt=false
    
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        need_prompt=true
    fi
    
    if [ "$need_prompt" = "true" ]; then
        echo ""
        echo -e "  ${WHITE}${BOLD}MariaDB Credentials Required${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo ""
        
        if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
            read -sp "  Enter MariaDB root password: " MYSQL_ROOT_PASSWORD
            echo ""
        fi
        
        if [ -z "$MYSQL_USER" ]; then
            read -p "  Enter database username [pokemon]: " MYSQL_USER
            MYSQL_USER="${MYSQL_USER:-pokemon}"
        fi
        
        if [ -z "$MYSQL_PASSWORD" ]; then
            read -sp "  Enter database user password: " MYSQL_PASSWORD
            echo ""
        fi
        
        if [ -z "$MYSQL_DATABASE" ]; then
            MYSQL_DATABASE="dragonite"
        fi
        
        echo ""
    fi
}

check_mariadb_installed() {
    # Check for mariadb command first (MariaDB 12+), then mysql
    if command -v mariadb &> /dev/null; then
        return 0
    elif command -v mysql &> /dev/null; then
        return 0
    else
        return 1
    fi
}

check_mariadb_running() {
    if systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysql 2>/dev/null; then
        return 0
    elif pgrep -x mysqld > /dev/null 2>&1 || pgrep -x mariadbd > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

setup_mysql_cmd() {
    # Detect which MySQL client command to use
    # MariaDB 12+ uses 'mariadb' command, older versions use 'mysql'
    local mysql_client="mysql"
    if command -v mariadb &> /dev/null; then
        mysql_client="mariadb"
    fi
    
    if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
        MYSQL_CMD="$mysql_client -u root -p${MYSQL_ROOT_PASSWORD}"
    else
        MYSQL_CMD="$mysql_client -u root"
    fi
}

test_db_connection() {
    $MYSQL_CMD -e "SELECT 1" &>/dev/null
    return $?
}

run_query() {
    # $1 = database, $2 = query
    if [ -n "$1" ]; then
        $MYSQL_CMD -D "$1" -N -e "$2" 2>/dev/null
    else
        $MYSQL_CMD -N -e "$2" 2>/dev/null
    fi
}

db_exists() {
    result=$(run_query "" "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '$1'")
    [ -n "$result" ]
}

table_exists() {
    # $1 = database, $2 = table
    result=$(run_query "" "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = '$1' AND TABLE_NAME = '$2'")
    [ -n "$result" ]
}

format_size() {
    local size=$1
    if [ -z "$size" ] || [ "$size" = "NULL" ]; then
        echo "0 B"
    elif [ "$size" -ge 1073741824 ]; then
        echo "$(echo "scale=2; $size / 1073741824" | bc) GB"
    elif [ "$size" -ge 1048576 ]; then
        echo "$(echo "scale=2; $size / 1048576" | bc) MB"
    elif [ "$size" -ge 1024 ]; then
        echo "$(echo "scale=2; $size / 1024" | bc) KB"
    else
        echo "$size B"
    fi
}

format_number() {
    printf "%'d" "$1" 2>/dev/null || echo "$1"
}

press_enter() {
    echo ""
    read -p "Press Enter to continue..."
}

# =============================================================================
# STATUS DASHBOARD
# =============================================================================

show_status_dashboard() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              AEGIS DATABASE STATUS DASHBOARD"
    draw_box_bottom
    echo ""

    # MariaDB Status
    echo -e "${WHITE}${BOLD}MariaDB Server Status${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    
    if check_mariadb_installed; then
        echo -e "  Installation:    ${GREEN}Installed${NC}"
    else
        echo -e "  Installation:    ${RED}Not Installed${NC}"
        echo ""
        return 1
    fi

    if check_mariadb_running; then
        echo -e "  Service:         ${GREEN}Running${NC}"
    else
        echo -e "  Service:         ${RED}Stopped${NC}"
        echo ""
        return 1
    fi

    if test_db_connection; then
        echo -e "  Connection:      ${GREEN}Connected${NC}"
        local version=$(run_query "" "SELECT VERSION()")
        echo -e "  Version:         ${CYAN}$version${NC}"
    else
        echo -e "  Connection:      ${RED}Failed${NC}"
        echo ""
        return 1
    fi
    echo ""

    # Database Status
    echo -e "${WHITE}${BOLD}Databases${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    printf "  ${DIM}%-15s %-12s %-15s${NC}\n" "DATABASE" "STATUS" "SIZE"
    
    for db in "${DBS[@]}"; do
        if db_exists "$db"; then
            size_bytes=$(run_query "" "SELECT SUM(data_length + index_length) FROM information_schema.tables WHERE table_schema = '$db'")
            size=$(format_size "${size_bytes:-0}")
            printf "  %-15s ${GREEN}%-12s${NC} %-15s\n" "$db" "Found" "$size"
        else
            printf "  %-15s ${RED}%-12s${NC} %-15s\n" "$db" "Missing" "-"
        fi
    done
    echo ""

    # Account Statistics (from dragonite database)
    if db_exists "dragonite" && table_exists "dragonite" "account"; then
        echo -e "${WHITE}${BOLD}Account Statistics${NC}"
        echo -e "${DIM}────────────────────────────────────────${NC}"
        
        local total=$(run_query "dragonite" "SELECT COUNT(*) FROM account" 2>/dev/null || echo "0")
        local good=$(run_query "dragonite" "SELECT COUNT(*) FROM account WHERE banned = 0 AND invalid = 0 AND auth_banned = 0" 2>/dev/null || echo "0")
        local banned=$(run_query "dragonite" "SELECT COUNT(*) FROM account WHERE banned = 1" 2>/dev/null || echo "0")
        local invalid=$(run_query "dragonite" "SELECT COUNT(*) FROM account WHERE invalid = 1" 2>/dev/null || echo "0")
        local auth_banned=$(run_query "dragonite" "SELECT COUNT(*) FROM account WHERE auth_banned = 1" 2>/dev/null || echo "0")
        local warn=$(run_query "dragonite" "SELECT COUNT(*) FROM account WHERE warn = 1" 2>/dev/null || echo "0")
        local suspended=$(run_query "dragonite" "SELECT COUNT(*) FROM account WHERE suspended = 1" 2>/dev/null || echo "0")
        
        echo -e "  Total Accounts:     $(format_number ${total:-0})"
        echo -e "  Good Accounts:      ${GREEN}$(format_number ${good:-0})${NC}"
        echo -e "  Banned:             ${RED}$(format_number ${banned:-0})${NC}"
        echo -e "  Invalid:            ${YELLOW}$(format_number ${invalid:-0})${NC}"
        echo -e "  Auth Banned:        ${RED}$(format_number ${auth_banned:-0})${NC}"
        echo -e "  Warned:             ${YELLOW}$(format_number ${warn:-0})${NC}"
        echo -e "  Suspended:          ${RED}$(format_number ${suspended:-0})${NC}"
        echo ""
    fi

    # Map Data Statistics (from golbat database)
    if db_exists "golbat"; then
        echo -e "${WHITE}${BOLD}Map Data Statistics${NC}"
        echo -e "${DIM}────────────────────────────────────────${NC}"
        
        if table_exists "golbat" "pokestop"; then
            local pokestops=$(run_query "golbat" "SELECT COUNT(*) FROM pokestop" 2>/dev/null || echo "0")
            echo -e "  Pokestops:          $(format_number ${pokestops:-0})"
        fi
        if table_exists "golbat" "gym"; then
            local gyms=$(run_query "golbat" "SELECT COUNT(*) FROM gym" 2>/dev/null || echo "0")
            echo -e "  Gyms:               $(format_number ${gyms:-0})"
        fi
        if table_exists "golbat" "spawnpoint"; then
            local spawnpoints=$(run_query "golbat" "SELECT COUNT(*) FROM spawnpoint" 2>/dev/null || echo "0")
            echo -e "  Spawnpoints:        $(format_number ${spawnpoints:-0})"
        fi
        if table_exists "golbat" "pokemon"; then
            local pokemon=$(run_query "golbat" "SELECT COUNT(*) FROM pokemon" 2>/dev/null || echo "0")
            echo -e "  Active Pokemon:     $(format_number ${pokemon:-0})"
        fi
        if table_exists "golbat" "nest"; then
            local nests=$(run_query "golbat" "SELECT COUNT(*) FROM nest" 2>/dev/null || echo "0")
            local unknown_nests=$(run_query "golbat" "SELECT COUNT(*) FROM nest WHERE name IS NULL OR name = '' OR name = 'Unknown'" 2>/dev/null || echo "0")
            echo -e "  Nests:              $(format_number ${nests:-0}) (${unknown_nests:-0} unknown)"
        fi
        echo ""
    fi

    # User Permissions
    echo -e "${WHITE}${BOLD}Database Users${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    
    # Check users from configs
    local db_user="${MYSQL_USER:-dbuser}"
    local user_count=$(run_query "" "SELECT COUNT(*) FROM mysql.user WHERE User = '$db_user'")
    
    if [ "${user_count:-0}" -gt 0 ]; then
        local grants=$(run_query "" "SHOW GRANTS FOR '$db_user'@'%'" 2>/dev/null | head -1)
        echo -e "  $db_user:            ${GREEN}Exists${NC}"
        if echo "$grants" | grep -q "ALL PRIVILEGES"; then
            echo -e "  Permissions:        ${GREEN}Full Access${NC}"
        else
            echo -e "  Permissions:        ${YELLOW}Limited${NC}"
        fi
    else
        echo -e "  $db_user:            ${RED}Not Found${NC}"
    fi
    echo ""

    # Quick health check
    local missing_dbs=0
    for db in "${DBS[@]}"; do
        if ! db_exists "$db"; then
            ((missing_dbs++))
        fi
    done
    
    if [ $missing_dbs -gt 0 ] || [ "${user_count:-0}" -eq 0 ]; then
        echo -e "${WHITE}${BOLD}Issues Detected${NC}"
        echo -e "${DIM}────────────────────────────────────────${NC}"
        if [ $missing_dbs -gt 0 ]; then
            echo -e "  ${RED}!${NC} $missing_dbs missing database(s)"
        fi
        if [ "${user_count:-0}" -eq 0 ]; then
            echo -e "  ${RED}!${NC} DB user '$db_user' not found"
        fi
        echo -e "  ${CYAN}→${NC} Use option 5 (Database & User Management) to fix"
        echo ""
    fi

    return 0
}

# =============================================================================
# SETUP MODE FUNCTIONS
# =============================================================================

install_mariadb() {
    print_step "Installing MariaDB..."
    apt update -y
    apt install mariadb-server -y
    
    if [ $? -eq 0 ]; then
        # Set root password
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD'; FLUSH PRIVILEGES;"
    if [ $? -eq 0 ]; then
            print_success "MariaDB installed and root password set"
            return 0
        else
            print_error "Failed to set root password"
            return 1
        fi
    else
        print_error "Failed to install MariaDB"
        return 1
    fi
}

tune_mariadb() {
    echo ""
    print_step "Detecting system resources..."
    echo ""

    # Detect RAM
    if [ -f /proc/meminfo ]; then
        TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
        TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))
    else
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
    draw_box_top
    draw_box_line "           DETECTED SYSTEM RESOURCES"
    draw_box_divider
    draw_box_line_colored "RAM:" "${TOTAL_RAM_GB} GB (${TOTAL_RAM_MB} MB)" "$CYAN"
    draw_box_line_colored "CPU Cores:" "$CPU_CORES" "$CYAN"
    draw_box_bottom
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
        1) STORAGE_NAME="SSD"; IO_CAPACITY=1000; IO_CAPACITY_MAX=4000 ;;
        2) STORAGE_NAME="NVMe SSD"; IO_CAPACITY=4000; IO_CAPACITY_MAX=10000 ;;
        3) STORAGE_NAME="HDD"; IO_CAPACITY=150; IO_CAPACITY_MAX=400 ;;
        4|*) STORAGE_NAME="Cloud/VPS"; IO_CAPACITY=500; IO_CAPACITY_MAX=2000 ;;
    esac

    print_success "Storage type: $STORAGE_NAME"
    echo ""

    # Calculate optimal settings
    print_info "Calculating optimal MariaDB settings..."

    # Buffer pool (30% of RAM)
    BUFFER_POOL_MB=$((TOTAL_RAM_MB * 30 / 100))
    if [ $BUFFER_POOL_MB -lt 512 ]; then BUFFER_POOL_SIZE="512M"; BUFFER_POOL_GB=0
    elif [ $BUFFER_POOL_MB -lt 1024 ]; then BUFFER_POOL_SIZE="512M"; BUFFER_POOL_GB=0
    elif [ $BUFFER_POOL_MB -lt 1536 ]; then BUFFER_POOL_SIZE="1G"; BUFFER_POOL_GB=1
    elif [ $BUFFER_POOL_MB -lt 2560 ]; then BUFFER_POOL_SIZE="2G"; BUFFER_POOL_GB=2
    elif [ $BUFFER_POOL_MB -lt 3584 ]; then BUFFER_POOL_SIZE="3G"; BUFFER_POOL_GB=3
    elif [ $BUFFER_POOL_MB -lt 4608 ]; then BUFFER_POOL_SIZE="4G"; BUFFER_POOL_GB=4
    elif [ $BUFFER_POOL_MB -lt 6144 ]; then BUFFER_POOL_SIZE="5G"; BUFFER_POOL_GB=5
    elif [ $BUFFER_POOL_MB -lt 7168 ]; then BUFFER_POOL_SIZE="6G"; BUFFER_POOL_GB=6
    elif [ $BUFFER_POOL_MB -lt 8192 ]; then BUFFER_POOL_SIZE="7G"; BUFFER_POOL_GB=7
    elif [ $BUFFER_POOL_MB -lt 10240 ]; then BUFFER_POOL_SIZE="8G"; BUFFER_POOL_GB=8
    elif [ $BUFFER_POOL_MB -lt 12288 ]; then BUFFER_POOL_SIZE="10G"; BUFFER_POOL_GB=10
    elif [ $BUFFER_POOL_MB -lt 16384 ]; then BUFFER_POOL_SIZE="12G"; BUFFER_POOL_GB=12
    else BUFFER_POOL_SIZE="16G"; BUFFER_POOL_GB=16
    fi

    # Buffer pool instances
    [ $BUFFER_POOL_GB -le 1 ] && BUFFER_POOL_INSTANCES=1 || BUFFER_POOL_INSTANCES=$BUFFER_POOL_GB
    [ $BUFFER_POOL_INSTANCES -gt 8 ] && BUFFER_POOL_INSTANCES=8

    # I/O threads
    IO_THREADS=$((CPU_CORES / 2))
    [ $IO_THREADS -lt 2 ] && IO_THREADS=2
    [ $IO_THREADS -gt 8 ] && IO_THREADS=8

    # Max connections
    if [ $TOTAL_RAM_GB -le 2 ]; then MAX_CONNECTIONS=100
    elif [ $TOTAL_RAM_GB -le 4 ]; then MAX_CONNECTIONS=200
    elif [ $TOTAL_RAM_GB -le 8 ]; then MAX_CONNECTIONS=300
    elif [ $TOTAL_RAM_GB -le 16 ]; then MAX_CONNECTIONS=500
    else MAX_CONNECTIONS=750
    fi

    # Temp table size
    if [ $TOTAL_RAM_GB -le 2 ]; then TMP_TABLE_SIZE="64M"
    elif [ $TOTAL_RAM_GB -le 4 ]; then TMP_TABLE_SIZE="128M"
    elif [ $TOTAL_RAM_GB -le 8 ]; then TMP_TABLE_SIZE="256M"
    else TMP_TABLE_SIZE="512M"
    fi

    # Log file size
    if [ $TOTAL_RAM_GB -le 4 ]; then LOG_FILE_SIZE="256M"
    elif [ $TOTAL_RAM_GB -le 8 ]; then LOG_FILE_SIZE="512M"
    elif [ $TOTAL_RAM_GB -le 16 ]; then LOG_FILE_SIZE="768M"
    else LOG_FILE_SIZE="1G"
    fi

    echo ""
    draw_box_top
    draw_box_line "           CALCULATED MARIADB SETTINGS"
    draw_box_divider
    draw_box_line_colored "innodb_buffer_pool_size:" "$BUFFER_POOL_SIZE" "$GREEN"
    draw_box_line_colored "innodb_buffer_pool_instances:" "$BUFFER_POOL_INSTANCES" "$GREEN"
    draw_box_line_colored "innodb_read_io_threads:" "$IO_THREADS" "$GREEN"
    draw_box_line_colored "innodb_write_io_threads:" "$IO_THREADS" "$GREEN"
    draw_box_line_colored "innodb_io_capacity:" "$IO_CAPACITY" "$GREEN"
    draw_box_line_colored "innodb_io_capacity_max:" "$IO_CAPACITY_MAX" "$GREEN"
    draw_box_line_colored "max_connections:" "$MAX_CONNECTIONS" "$GREEN"
    draw_box_line_colored "tmp_table_size:" "$TMP_TABLE_SIZE" "$GREEN"
    draw_box_line_colored "innodb_log_file_size:" "$LOG_FILE_SIZE" "$GREEN"
    draw_box_bottom
    echo ""

    read -p "  Apply these settings to MariaDB config? (y/n) [y]: " APPLY_DB_SETTINGS
    APPLY_DB_SETTINGS=${APPLY_DB_SETTINGS:-y}

    if [ "$APPLY_DB_SETTINGS" = "y" ] || [ "$APPLY_DB_SETTINGS" = "Y" ]; then
        MARIADB_CNF="mysql_data/mariadb.cnf"
        
        if [ -f "$MARIADB_CNF" ]; then
            print_info "Applying optimized settings to $MARIADB_CNF..."
            
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
            
            CONFIG_DATE=$(date '+%Y-%m-%d %H:%M:%S')
            sed -i "1a # Auto-configured on $CONFIG_DATE for: ${TOTAL_RAM_GB}GB RAM, ${CPU_CORES} CPU cores, $STORAGE_NAME storage" "$MARIADB_CNF"
            
            print_success "MariaDB settings optimized!"
            print_warning "Restart MariaDB/Docker for changes to take effect."
        else
            print_warning "mariadb.cnf not found at $MARIADB_CNF - skipping optimization"
        fi
    fi
}

create_databases() {
    print_step "Creating databases..."
    echo ""

    for db in "${DBS[@]}"; do
        result=$(run_query "" "CREATE DATABASE IF NOT EXISTS \`$db\`" 2>&1)
        if [ $? -eq 0 ]; then
            print_success "Database '$db' ready"
        else
            print_error "Failed to create '$db': $result"
        fi
    done
}

create_user() {
    echo ""
    read -p "Enter DB username to create (or press enter to skip): " NEW_USER
    
    if [ -z "$NEW_USER" ]; then
        print_info "Skipping user creation."
        return
    fi

    read -p "Enter password for $NEW_USER (or press enter for random): " NEW_PASS
    if [ -z "$NEW_PASS" ]; then
        NEW_PASS=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
        print_warning "Generated password: $NEW_PASS"
    fi

    SQL="CREATE USER IF NOT EXISTS '$NEW_USER'@'%' IDENTIFIED BY '$NEW_PASS'; "
    SQL+="GRANT ALL PRIVILEGES ON *.* TO '$NEW_USER'@'%' WITH GRANT OPTION; "
    SQL+="FLUSH PRIVILEGES;"

    if run_query "" "$SQL"; then
        print_success "User '$NEW_USER' created with full privileges"
        print_info "Update your config files with this username/password if needed."
    else
        print_error "Failed to create user"
    fi
}

show_setup_complete() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              SETUP COMPLETE"
    draw_box_bottom
    echo ""
    
    echo -e "${WHITE}${BOLD}Services Status${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    
    if check_mariadb_running; then
        echo -e "  MariaDB:         ${GREEN}● Online${NC}"
    else
        echo -e "  MariaDB:         ${RED}● Offline${NC}"
    fi
    echo ""

    echo -e "${WHITE}${BOLD}Databases Created${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    for db in "${DBS[@]}"; do
        if db_exists "$db"; then
            echo -e "  $db:             ${GREEN}● Ready${NC}"
        else
            echo -e "  $db:             ${RED}● Failed${NC}"
        fi
    done
    echo ""

    echo -e "${WHITE}${BOLD}Next Steps${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    echo "  1. Run: docker compose up -d --force-recreate --build"
    echo "  2. Wait for services to initialize"
    echo "  3. Access your services via web browser"
    echo ""
    
    if [ "$SHELLDER_LAUNCHER" = "1" ]; then
        echo ""
        read -p "  Press Enter to return to main menu..."
        return_to_main
    else
        press_enter
    fi
}
    echo "  1. Run: docker compose up -d --force-recreate --build"
    echo "  2. Wait for services to initialize"
    echo "  3. Access your services via web browser"
    echo ""
}

run_setup_mode() {
    [ "$LOG_AVAILABLE" = "true" ] && log_info "Entering MariaDB Setup Mode"
    
    clear
    echo ""
    draw_box_top
    draw_box_line "         AEGIS DATABASE SETUP"
    draw_box_line ""
    draw_box_line "  This will:"
    draw_box_line "    • Install MariaDB (if needed)"
    draw_box_line "    • Tune MariaDB for your hardware"
    draw_box_line "    • Create required databases"
    draw_box_line "    • Create database users"
    draw_box_bottom
    echo ""

    # Prompt for credentials if not loaded from .env
    if [ "$ENV_LOADED" != "true" ] || [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        echo -e "  ${YELLOW}No .env file found - entering manual configuration mode${NC}"
        [ "$LOG_AVAILABLE" = "true" ] && log_warn "No .env file - using manual configuration"
        echo ""
        prompt_db_credentials
    fi

    # Check/install MariaDB
    if ! check_mariadb_installed; then
        read -p "  MariaDB is not installed. Install now? (y/n) [y]: " INSTALL_CHOICE
        INSTALL_CHOICE=${INSTALL_CHOICE:-y}
        if [ "$INSTALL_CHOICE" = "y" ] || [ "$INSTALL_CHOICE" = "Y" ]; then
            [ "$LOG_AVAILABLE" = "true" ] && log_info "Starting MariaDB installation"
            if ! install_mariadb; then
                print_error "MariaDB installation failed"
                [ "$LOG_AVAILABLE" = "true" ] && log_error "MariaDB installation failed"
                echo ""
                echo "  Please check the error messages above and try again."
                echo "  You may need to install MariaDB manually:"
                echo "    sudo apt install mariadb-server"
                echo ""
                press_enter
                return
            fi
            [ "$LOG_AVAILABLE" = "true" ] && log_info "MariaDB installation completed"
        else
            print_warn "Installation skipped. Please install MariaDB manually."
            [ "$LOG_AVAILABLE" = "true" ] && log_warn "User skipped MariaDB installation"
            echo ""
            echo "  To install MariaDB:"
            echo "    sudo apt install mariadb-server"
            echo ""
            press_enter
            return
        fi
    else
        print_success "MariaDB is installed"
    fi

    # Check if running
    if ! check_mariadb_running; then
        print_info "Starting MariaDB..."
        if ! systemctl start mariadb 2>/dev/null && ! systemctl start mysql 2>/dev/null; then
            print_error "Failed to start MariaDB"
            [ "$LOG_AVAILABLE" = "true" ] && log_error "Failed to start MariaDB service"
            echo ""
            echo "  Try starting manually:"
            echo "    sudo systemctl start mariadb"
            echo "    sudo systemctl status mariadb"
            echo ""
            press_enter
            return
        fi
        sleep 2
    fi
    print_success "MariaDB is running"

    # Setup MySQL command
    setup_mysql_cmd

    # Test connection - with retry option
    if ! test_db_connection; then
        print_error "Cannot connect to MariaDB"
        [ "$LOG_AVAILABLE" = "true" ] && log_error "MariaDB connection failed during setup"
        echo ""
        echo "  Possible causes:"
        echo "    • Root password is incorrect"
        echo "    • MariaDB authentication is not configured"
        echo "    • MariaDB is not accepting connections"
        echo ""
        
        # Offer to try different password
        read -p "  Would you like to enter a different root password? (y/n) [y]: " retry
        retry=${retry:-y}
        if [ "$retry" = "y" ]; then
            read -sp "  Enter MariaDB root password: " MYSQL_ROOT_PASSWORD
            echo ""
            setup_mysql_cmd
            if ! test_db_connection; then
                print_error "Still cannot connect with provided password"
                [ "$LOG_AVAILABLE" = "true" ] && log_error "MariaDB connection failed after password retry"
                echo ""
                echo "  If this is a fresh MariaDB install, try:"
                echo "    sudo mysql_secure_installation"
                echo ""
                press_enter
                return
            fi
        else
            [ "$LOG_AVAILABLE" = "true" ] && log_warn "User declined to retry MariaDB password"
            press_enter
            return
        fi
    fi
    print_success "Connected to MariaDB"
    [ "$LOG_AVAILABLE" = "true" ] && log_info "MariaDB connection successful"

    # Tuning
    echo ""
    read -p "  Would you like to tune MariaDB for your hardware? (y/n) [y]: " DO_TUNING
    DO_TUNING=${DO_TUNING:-y}
    if [ "$DO_TUNING" = "y" ] || [ "$DO_TUNING" = "Y" ]; then
        tune_mariadb
    fi

    # Create databases
    echo ""
    create_databases

    # Create user
    create_user

    # Show completion
    show_setup_complete
}

# =============================================================================
# MAINTENANCE MODE FUNCTIONS
# =============================================================================

# Account Cleanup Menu
account_cleanup_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "         ACCOUNT CLEANUP"
        draw_box_bottom
        echo ""

        if ! db_exists "dragonite" || ! table_exists "dragonite" "account"; then
            print_error "Dragonite database or account table not found"
            press_enter
            return
        fi

        # Show current counts
        local banned=$(run_query "dragonite" "SELECT COUNT(*) FROM account WHERE banned = 1" || echo "0")
        local invalid=$(run_query "dragonite" "SELECT COUNT(*) FROM account WHERE invalid = 1" || echo "0")
        local auth_banned=$(run_query "dragonite" "SELECT COUNT(*) FROM account WHERE auth_banned = 1" || echo "0")
        local warned=$(run_query "dragonite" "SELECT COUNT(*) FROM account WHERE warn = 1" || echo "0")
        local suspended=$(run_query "dragonite" "SELECT COUNT(*) FROM account WHERE suspended = 1" || echo "0")

        echo "  Current Problem Accounts:"
        echo -e "    Banned:       ${RED}${banned:-0}${NC}"
        echo -e "    Invalid:      ${YELLOW}${invalid:-0}${NC}"
        echo -e "    Auth Banned:  ${RED}${auth_banned:-0}${NC}"
        echo -e "    Warned:       ${YELLOW}${warned:-0}${NC}"
        echo -e "    Suspended:    ${RED}${suspended:-0}${NC}"
        echo ""
        echo "  Options:"
        echo "    1) Remove banned accounts"
        echo "    2) Remove invalid accounts"
        echo "    3) Remove auth-banned accounts"
        echo "    4) Remove warned accounts"
        echo "    5) Remove suspended accounts"
        echo "    6) Remove ALL problem accounts"
        echo "    7) Reset account flags (unban/clear warnings)"
        echo "    0) Back to main menu"
        echo ""
        read -p "  Select option: " choice

        case $choice in
            1)
                read -p "  Delete ${banned:-0} banned accounts? (y/n) [n]: " confirm
                if [ "$confirm" = "y" ]; then
                    run_query "dragonite" "DELETE FROM account WHERE banned = 1"
                    print_success "Removed banned accounts"
                fi
                press_enter
                ;;
            2)
                read -p "  Delete ${invalid:-0} invalid accounts? (y/n) [n]: " confirm
                if [ "$confirm" = "y" ]; then
                    run_query "dragonite" "DELETE FROM account WHERE invalid = 1"
                    print_success "Removed invalid accounts"
                fi
                press_enter
                ;;
            3)
                read -p "  Delete ${auth_banned:-0} auth-banned accounts? (y/n) [n]: " confirm
                if [ "$confirm" = "y" ]; then
                    run_query "dragonite" "DELETE FROM account WHERE auth_banned = 1"
                    print_success "Removed auth-banned accounts"
                fi
                press_enter
                ;;
            4)
                read -p "  Delete ${warned:-0} warned accounts? (y/n) [n]: " confirm
                if [ "$confirm" = "y" ]; then
                    run_query "dragonite" "DELETE FROM account WHERE warn = 1"
                    print_success "Removed warned accounts"
                fi
                press_enter
                ;;
            5)
                read -p "  Delete ${suspended:-0} suspended accounts? (y/n) [n]: " confirm
                if [ "$confirm" = "y" ]; then
                    run_query "dragonite" "DELETE FROM account WHERE suspended = 1"
                    print_success "Removed suspended accounts"
                fi
                press_enter
                ;;
            6)
                local total_problem=$((${banned:-0} + ${invalid:-0} + ${auth_banned:-0} + ${suspended:-0}))
                read -p "  Delete ALL ${total_problem} problem accounts? (y/n) [n]: " confirm
                if [ "$confirm" = "y" ]; then
                    run_query "dragonite" "DELETE FROM account WHERE banned = 1 OR invalid = 1 OR auth_banned = 1 OR suspended = 1"
                    print_success "Removed all problem accounts"
                fi
                press_enter
                ;;
            7)
                echo ""
                echo "  Reset Options:"
                echo "    a) Clear all warnings (warn = 0)"
                echo "    b) Unban all accounts (banned = 0)"
                echo "    c) Clear invalid flag (invalid = 0)"
                echo "    d) Reset ALL flags"
                read -p "  Select: " reset_choice
                case $reset_choice in
                    a) run_query "dragonite" "UPDATE account SET warn = 0"; print_success "Warnings cleared" ;;
                    b) run_query "dragonite" "UPDATE account SET banned = 0"; print_success "Accounts unbanned" ;;
                    c) run_query "dragonite" "UPDATE account SET invalid = 0"; print_success "Invalid flags cleared" ;;
                    d) run_query "dragonite" "UPDATE account SET banned = 0, invalid = 0, warn = 0, suspended = 0, auth_banned = 0"; print_success "All flags reset" ;;
                esac
                press_enter
                ;;
            0) return ;;
        esac
    done
}

# Map Data Cleanup Menu
map_data_cleanup_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "         MAP DATA CLEANUP"
        draw_box_bottom
        echo ""

        if ! db_exists "golbat"; then
            print_error "Golbat database not found"
            press_enter
            return
        fi

        # Show current counts
        local pokestops=$(run_query "golbat" "SELECT COUNT(*) FROM pokestop" 2>/dev/null || echo "0")
        local gyms=$(run_query "golbat" "SELECT COUNT(*) FROM gym" 2>/dev/null || echo "0")
        local spawnpoints=$(run_query "golbat" "SELECT COUNT(*) FROM spawnpoint" 2>/dev/null || echo "0")
        local pokemon=$(run_query "golbat" "SELECT COUNT(*) FROM pokemon" 2>/dev/null || echo "0")

        echo "  Current Data:"
        echo -e "    Pokestops:    ${CYAN}$(format_number ${pokestops:-0})${NC}"
        echo -e "    Gyms:         ${CYAN}$(format_number ${gyms:-0})${NC}"
        echo -e "    Spawnpoints:  ${CYAN}$(format_number ${spawnpoints:-0})${NC}"
        echo -e "    Pokemon:      ${CYAN}$(format_number ${pokemon:-0})${NC}"
        echo ""
        echo "  Options:"
        echo "    1) Remove stale pokestops (not seen in 24h)"
        echo "    2) Remove stale gyms (not seen in 24h)"
        echo "    3) Remove stale spawnpoints (not seen in 24h)"
        echo "    4) Remove ALL stale data (24h)"
        echo "    5) Truncate spawnpoints table (complete reset)"
        echo "    6) Purge expired Pokemon"
        echo "    7) Custom stale threshold"
        echo "    0) Back to main menu"
        echo ""
        read -p "  Select option: " choice

        case $choice in
            1)
                if table_exists "golbat" "pokestop"; then
                    local stale=$(run_query "golbat" "SELECT COUNT(*) FROM pokestop WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL 24 HOUR)" || echo "0")
                    read -p "  Remove ${stale:-0} stale pokestops? (y/n) [n]: " confirm
                    if [ "$confirm" = "y" ]; then
                        run_query "golbat" "DELETE FROM pokestop WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL 24 HOUR)"
                        print_success "Removed stale pokestops"
                    fi
                fi
                press_enter
                ;;
            2)
                if table_exists "golbat" "gym"; then
                    local stale=$(run_query "golbat" "SELECT COUNT(*) FROM gym WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL 24 HOUR)" || echo "0")
                    read -p "  Remove ${stale:-0} stale gyms? (y/n) [n]: " confirm
                    if [ "$confirm" = "y" ]; then
                        run_query "golbat" "DELETE FROM gym WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL 24 HOUR)"
                        print_success "Removed stale gyms"
                    fi
                fi
                press_enter
                ;;
            3)
                if table_exists "golbat" "spawnpoint"; then
                    local stale=$(run_query "golbat" "SELECT COUNT(*) FROM spawnpoint WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL 24 HOUR)" || echo "0")
                    read -p "  Remove ${stale:-0} stale spawnpoints? (y/n) [n]: " confirm
                    if [ "$confirm" = "y" ]; then
                        run_query "golbat" "DELETE FROM spawnpoint WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL 24 HOUR)"
                        print_success "Removed stale spawnpoints"
                    fi
                fi
                press_enter
                ;;
            4)
                read -p "  Remove ALL data not seen in 24 hours? (y/n) [n]: " confirm
                if [ "$confirm" = "y" ]; then
                    run_query "golbat" "DELETE FROM pokestop WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL 24 HOUR)" 2>/dev/null
                    run_query "golbat" "DELETE FROM gym WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL 24 HOUR)" 2>/dev/null
                    run_query "golbat" "DELETE FROM spawnpoint WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL 24 HOUR)" 2>/dev/null
                    print_success "Removed all stale data"
                fi
                press_enter
                ;;
            5)
                print_warning "This will DELETE ALL spawnpoints!"
                read -p "  Type 'CONFIRM' to proceed: " confirm
                if [ "$confirm" = "CONFIRM" ]; then
                    run_query "golbat" "TRUNCATE TABLE spawnpoint"
                    print_success "Spawnpoints table truncated"
                fi
                press_enter
                ;;
            6)
                if table_exists "golbat" "pokemon"; then
                    local expired=$(run_query "golbat" "SELECT COUNT(*) FROM pokemon WHERE expire_timestamp < UNIX_TIMESTAMP(NOW())" || echo "0")
                    read -p "  Purge ${expired:-0} expired Pokemon? (y/n) [n]: " confirm
                    if [ "$confirm" = "y" ]; then
                        run_query "golbat" "DELETE FROM pokemon WHERE expire_timestamp < UNIX_TIMESTAMP(NOW())"
                        print_success "Purged expired Pokemon"
                    fi
                fi
                press_enter
                ;;
            7)
                read -p "  Enter hours threshold (e.g., 48, 72, 168): " hours
                if [[ "$hours" =~ ^[0-9]+$ ]]; then
                    local stale_stops=$(run_query "golbat" "SELECT COUNT(*) FROM pokestop WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL $hours HOUR)" 2>/dev/null || echo "0")
                    local stale_gyms=$(run_query "golbat" "SELECT COUNT(*) FROM gym WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL $hours HOUR)" 2>/dev/null || echo "0")
                    local stale_spawns=$(run_query "golbat" "SELECT COUNT(*) FROM spawnpoint WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL $hours HOUR)" 2>/dev/null || echo "0")
                    echo ""
                    echo "  Data older than ${hours} hours:"
                    echo "    Pokestops:    ${stale_stops:-0}"
                    echo "    Gyms:         ${stale_gyms:-0}"
                    echo "    Spawnpoints:  ${stale_spawns:-0}"
                    read -p "  Remove this data? (y/n) [n]: " confirm
                    if [ "$confirm" = "y" ]; then
                        run_query "golbat" "DELETE FROM pokestop WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL $hours HOUR)" 2>/dev/null
                        run_query "golbat" "DELETE FROM gym WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL $hours HOUR)" 2>/dev/null
                        run_query "golbat" "DELETE FROM spawnpoint WHERE updated < UNIX_TIMESTAMP(NOW() - INTERVAL $hours HOUR)" 2>/dev/null
                        print_success "Removed data older than ${hours} hours"
                    fi
                fi
                press_enter
                ;;
            0) return ;;
        esac
    done
}

# Nest Management Menu
nest_management_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "         NEST MANAGEMENT"
        draw_box_bottom
        echo ""

        if ! db_exists "golbat" || ! table_exists "golbat" "nest"; then
            print_error "Golbat database or nest table not found"
            press_enter
            return
        fi

        local total=$(run_query "golbat" "SELECT COUNT(*) FROM nest" || echo "0")
        local unknown=$(run_query "golbat" "SELECT COUNT(*) FROM nest WHERE name IS NULL OR name = '' OR name = 'Unknown'" || echo "0")
        local named=$(run_query "golbat" "SELECT COUNT(*) FROM nest WHERE name IS NOT NULL AND name != '' AND name != 'Unknown'" || echo "0")

        echo "  Nest Statistics:"
        echo -e "    Total Nests:    ${CYAN}$(format_number ${total:-0})${NC}"
        echo -e "    Named:          ${GREEN}$(format_number ${named:-0})${NC}"
        echo -e "    Unknown:        ${YELLOW}$(format_number ${unknown:-0})${NC}"
        echo ""
        echo "  Options:"
        echo "    1) List unknown nests"
        echo "    2) Label unknown nests with area name"
        echo "    3) Label unknown nests with coordinates"
        echo "    4) Delete all unknown nests"
        echo "    5) Truncate nest table (reset all)"
        echo "    0) Back to main menu"
        echo ""
        read -p "  Select option: " choice

        case $choice in
            1)
                echo ""
                echo "  Unknown Nests (first 20):"
                run_query "golbat" "SELECT nest_id, lat, lon FROM nest WHERE name IS NULL OR name = '' OR name = 'Unknown' LIMIT 20" | while read line; do
                    echo "    $line"
                done
                press_enter
                ;;
            2)
                read -p "  Enter area name prefix (e.g., 'Downtown'): " prefix
                if [ -n "$prefix" ]; then
                    run_query "golbat" "UPDATE nest SET name = CONCAT('$prefix', ' Nest #', nest_id) WHERE name IS NULL OR name = '' OR name = 'Unknown'"
                    print_success "Labeled unknown nests with '$prefix Nest #ID'"
                fi
                press_enter
                ;;
            3)
                run_query "golbat" "UPDATE nest SET name = CONCAT('Nest @ ', ROUND(lat, 4), ', ', ROUND(lon, 4)) WHERE name IS NULL OR name = '' OR name = 'Unknown'"
                print_success "Labeled unknown nests with coordinates"
                press_enter
                ;;
            4)
                read -p "  Delete ${unknown:-0} unknown nests? (y/n) [n]: " confirm
                if [ "$confirm" = "y" ]; then
                    run_query "golbat" "DELETE FROM nest WHERE name IS NULL OR name = '' OR name = 'Unknown'"
                    print_success "Deleted unknown nests"
                fi
                press_enter
                ;;
            5)
                print_warning "This will DELETE ALL nests!"
                read -p "  Type 'CONFIRM' to proceed: " confirm
                if [ "$confirm" = "CONFIRM" ]; then
                    run_query "golbat" "TRUNCATE TABLE nest"
                    print_success "Nest table truncated"
                fi
                press_enter
                ;;
            0) return ;;
        esac
    done
}

# General Maintenance Menu
general_maintenance_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "         GENERAL DATABASE MAINTENANCE"
        draw_box_bottom
        echo ""
        echo "  Options:"
        echo "    1) Optimize all tables (reclaim space)"
        echo "    2) Analyze tables (update statistics)"
        echo "    3) Check tables for errors"
        echo "    4) Repair tables"
        echo "    5) Show table sizes"
        echo "    6) Purge old statistics data"
        echo "    7) Purge old quest data"
        echo "    8) Purge old incident data"
        echo "    9) Flush query cache"
        echo "    0) Back to main menu"
        echo ""
        read -p "  Select option: " choice

        case $choice in
            1)
                read -p "  Select database to optimize (or 'all'): " db_choice
                echo ""
                print_info "Optimizing tables (this may take a while)..."
                if [ "$db_choice" = "all" ]; then
                    for db in "${DBS[@]}"; do
                        if db_exists "$db"; then
                            tables=$(run_query "$db" "SHOW TABLES")
                            for table in $tables; do
                                run_query "$db" "OPTIMIZE TABLE \`$table\`" >/dev/null
                                echo -e "  ${GREEN}✓${NC} $db.$table"
                            done
                        fi
                    done
                elif db_exists "$db_choice"; then
                    tables=$(run_query "$db_choice" "SHOW TABLES")
                    for table in $tables; do
                        run_query "$db_choice" "OPTIMIZE TABLE \`$table\`" >/dev/null
                        echo -e "  ${GREEN}✓${NC} $db_choice.$table"
                    done
                fi
                print_success "Optimization complete"
                press_enter
                ;;
            2)
                read -p "  Select database to analyze (or 'all'): " db_choice
                echo ""
                print_info "Analyzing tables..."
                if [ "$db_choice" = "all" ]; then
                    for db in "${DBS[@]}"; do
                        if db_exists "$db"; then
                            tables=$(run_query "$db" "SHOW TABLES")
                            for table in $tables; do
                                run_query "$db" "ANALYZE TABLE \`$table\`" >/dev/null
                                echo -e "  ${GREEN}✓${NC} $db.$table"
                            done
                        fi
                    done
                elif db_exists "$db_choice"; then
                    tables=$(run_query "$db_choice" "SHOW TABLES")
                    for table in $tables; do
                        run_query "$db_choice" "ANALYZE TABLE \`$table\`" >/dev/null
                        echo -e "  ${GREEN}✓${NC} $db_choice.$table"
                    done
                fi
                print_success "Analysis complete"
                press_enter
                ;;
            3)
                read -p "  Select database to check (or 'all'): " db_choice
                echo ""
                print_info "Checking tables..."
                if [ "$db_choice" = "all" ]; then
                    for db in "${DBS[@]}"; do
                        if db_exists "$db"; then
                            tables=$(run_query "$db" "SHOW TABLES")
                            for table in $tables; do
                                result=$(run_query "$db" "CHECK TABLE \`$table\`" | grep -E "status|Msg_text" | tail -1)
                                if echo "$result" | grep -q "OK"; then
                                    echo -e "  ${GREEN}✓${NC} $db.$table"
                                else
                                    echo -e "  ${RED}✗${NC} $db.$table - $result"
                                fi
                            done
                        fi
                    done
                elif db_exists "$db_choice"; then
                    tables=$(run_query "$db_choice" "SHOW TABLES")
                    for table in $tables; do
                        result=$(run_query "$db_choice" "CHECK TABLE \`$table\`" | grep -E "status|Msg_text" | tail -1)
                        if echo "$result" | grep -q "OK"; then
                            echo -e "  ${GREEN}✓${NC} $db_choice.$table"
                        else
                            echo -e "  ${RED}✗${NC} $db_choice.$table - $result"
                        fi
                    done
                fi
                press_enter
                ;;
            4)
                read -p "  Select database to repair (or 'all'): " db_choice
                echo ""
                print_warning "Repairing tables..."
                if [ "$db_choice" = "all" ]; then
                    for db in "${DBS[@]}"; do
                        if db_exists "$db"; then
                            tables=$(run_query "$db" "SHOW TABLES")
                            for table in $tables; do
                                run_query "$db" "REPAIR TABLE \`$table\`" >/dev/null 2>&1
                                echo -e "  ${GREEN}✓${NC} $db.$table"
                            done
                        fi
                    done
                elif db_exists "$db_choice"; then
                    tables=$(run_query "$db_choice" "SHOW TABLES")
                    for table in $tables; do
                        run_query "$db_choice" "REPAIR TABLE \`$table\`" >/dev/null 2>&1
                        echo -e "  ${GREEN}✓${NC} $db_choice.$table"
                    done
                fi
                print_success "Repair complete"
                press_enter
                ;;
            5)
                echo ""
                echo -e "  ${WHITE}${BOLD}Table Sizes by Database${NC}"
                echo -e "  ${DIM}────────────────────────────────────────${NC}"
                for db in "${DBS[@]}"; do
                    if db_exists "$db"; then
                        echo ""
                        echo -e "  ${CYAN}$db${NC}"
                        run_query "$db" "SELECT TABLE_NAME, ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) as 'Size (MB)', TABLE_ROWS as 'Rows' FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$db' ORDER BY (DATA_LENGTH + INDEX_LENGTH) DESC LIMIT 10" | while read name size rows; do
                            printf "    %-25s %10s MB  %12s rows\n" "$name" "$size" "$rows"
                        done
                    fi
                done
                press_enter
                ;;
            6)
                if db_exists "golbat"; then
                    read -p "  Keep stats for how many days? [30]: " days
                    days=${days:-30}
                    echo ""
                    for table in pokemon_stats pokemon_shiny_stats pokemon_iv_stats pokemon_hundo_stats pokemon_stats_archive; do
                        if table_exists "golbat" "$table"; then
                            run_query "golbat" "DELETE FROM $table WHERE date < DATE_SUB(CURDATE(), INTERVAL $days DAY)" 2>/dev/null
                            echo -e "  ${GREEN}✓${NC} Cleaned $table"
                        fi
                    done
                    print_success "Old statistics purged"
                fi
                press_enter
                ;;
            7)
                if db_exists "golbat" && table_exists "golbat" "quest"; then
                    local old_quests=$(run_query "golbat" "SELECT COUNT(*) FROM quest WHERE quest_timestamp < UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 1 DAY))" || echo "0")
                    read -p "  Purge ${old_quests:-0} old quests? (y/n) [n]: " confirm
                    if [ "$confirm" = "y" ]; then
                        run_query "golbat" "DELETE FROM quest WHERE quest_timestamp < UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 1 DAY))"
                        print_success "Old quests purged"
                    fi
                fi
                press_enter
                ;;
            8)
                if db_exists "golbat" && table_exists "golbat" "incident"; then
                    local old_incidents=$(run_query "golbat" "SELECT COUNT(*) FROM incident WHERE expiration < UNIX_TIMESTAMP(NOW())" || echo "0")
                    read -p "  Purge ${old_incidents:-0} expired incidents? (y/n) [n]: " confirm
                    if [ "$confirm" = "y" ]; then
                        run_query "golbat" "DELETE FROM incident WHERE expiration < UNIX_TIMESTAMP(NOW())"
                        print_success "Expired incidents purged"
                    fi
                fi
                press_enter
                ;;
            9)
                run_query "" "FLUSH QUERY CACHE" 2>/dev/null
                run_query "" "RESET QUERY CACHE" 2>/dev/null
                print_success "Query cache flushed"
                press_enter
                ;;
            0) return ;;
        esac
    done
}

# =============================================================================
# DATABASE & USER MANAGEMENT
# =============================================================================

# Helper to extract value from TOML
get_toml_value() {
    local file=$1
    local key=$2
    grep -E "^${key}\s*=" "$file" 2>/dev/null | sed 's/.*=\s*"\?\([^"]*\)"\?.*/\1/' | tr -d '"' | tr -d "'" | head -1
}

# Helper to extract value from JSON
get_json_value() {
    local file=$1
    local key=$2
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | grep -v "\"_${key}" | head -1 | sed 's/.*:\s*"\([^"]*\)".*/\1/'
}

# Get all usernames from config files
get_config_users() {
    local users=()
    
    # From .env
    if [ -n "$MYSQL_USER" ]; then
        users+=("$MYSQL_USER")
    fi
    
    # From dragonite config
    if [ -f "unown/dragonite_config.toml" ]; then
        local user=$(get_toml_value "unown/dragonite_config.toml" "user")
        if [ -n "$user" ] && [[ ! " ${users[*]} " =~ " ${user} " ]]; then
            users+=("$user")
        fi
    fi
    
    # From golbat config
    if [ -f "unown/golbat_config.toml" ]; then
        local user=$(get_toml_value "unown/golbat_config.toml" "user")
        if [ -n "$user" ] && [[ ! " ${users[*]} " =~ " ${user} " ]]; then
            users+=("$user")
        fi
    fi
    
    # From reactmap config
    if [ -f "reactmap/local.json" ]; then
        local user=$(get_json_value "reactmap/local.json" "username")
        if [ -n "$user" ] && [[ ! " ${users[*]} " =~ " ${user} " ]]; then
            users+=("$user")
        fi
    fi
    
    echo "${users[@]}"
}

# Check if user exists in database
user_exists() {
    local username=$1
    local count=$(run_query "" "SELECT COUNT(*) FROM mysql.user WHERE User = '$username'")
    [ "${count:-0}" -gt 0 ]
}

# Check if user has full privileges
user_has_full_privileges() {
    local username=$1
    local grants=$(run_query "" "SHOW GRANTS FOR '$username'@'%'" 2>/dev/null | head -1)
    echo "$grants" | grep -q "ALL PRIVILEGES"
}

# Database & User Management Menu
db_user_management_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "         DATABASE & USER MANAGEMENT"
        draw_box_bottom
        echo ""

        # Check databases
        echo -e "${WHITE}${BOLD}Required Databases${NC}"
        echo -e "${DIM}────────────────────────────────────────${NC}"
        
        local missing_dbs=()
        for db in "${DBS[@]}"; do
            if db_exists "$db"; then
                echo -e "  ${GREEN}✓${NC} $db"
            else
                echo -e "  ${RED}✗${NC} $db (missing)"
                missing_dbs+=("$db")
            fi
        done
        echo ""

        # Check users from configs
        echo -e "${WHITE}${BOLD}Users from Config Files${NC}"
        echo -e "${DIM}────────────────────────────────────────${NC}"
        
        local config_users=($(get_config_users))
        local missing_users=()
        local needs_privileges=()
        
        for user in "${config_users[@]}"; do
            if user_exists "$user"; then
                if user_has_full_privileges "$user"; then
                    echo -e "  ${GREEN}✓${NC} $user (exists, full privileges)"
                else
                    echo -e "  ${YELLOW}!${NC} $user (exists, limited privileges)"
                    needs_privileges+=("$user")
                fi
            else
                echo -e "  ${RED}✗${NC} $user (missing)"
                missing_users+=("$user")
            fi
        done
        echo ""

        # Show all DB users
        echo -e "${WHITE}${BOLD}All Database Users${NC}"
        echo -e "${DIM}────────────────────────────────────────${NC}"
        run_query "" "SELECT User, Host FROM mysql.user WHERE User NOT IN ('root', 'mysql', 'mariadb.sys', 'debian-sys-maint')" 2>/dev/null | while read user host; do
            echo "  $user@$host"
        done
        echo ""

        # Menu options
        echo "  Options:"
        echo "    1) Create missing databases"
        echo "    2) Create missing users"
        echo "    3) Grant full privileges to users"
        echo "    4) Fix ALL issues (create DBs, users, grant privileges)"
        echo "    5) Create new user manually"
        echo "    6) Delete a user"
        echo "    7) Show user grants"
        echo "    0) Back to main menu"
        echo ""
        read -p "  Select option: " choice

        case $choice in
            1)
                if [ ${#missing_dbs[@]} -eq 0 ]; then
                    print_info "All required databases already exist"
                else
                    echo ""
                    for db in "${missing_dbs[@]}"; do
                        run_query "" "CREATE DATABASE IF NOT EXISTS \`$db\`"
                        if [ $? -eq 0 ]; then
                            print_success "Created database: $db"
                        else
                            print_error "Failed to create: $db"
                        fi
                    done
                fi
                press_enter
                ;;
            2)
                if [ ${#missing_users[@]} -eq 0 ]; then
                    print_info "All config users already exist"
                else
                    echo ""
                    local db_pass="${MYSQL_PASSWORD:-}"
                    for user in "${missing_users[@]}"; do
                        if [ -n "$db_pass" ]; then
                            run_query "" "CREATE USER IF NOT EXISTS '$user'@'%' IDENTIFIED BY '$db_pass'"
                            run_query "" "GRANT ALL PRIVILEGES ON *.* TO '$user'@'%' WITH GRANT OPTION"
                            run_query "" "FLUSH PRIVILEGES"
                            if [ $? -eq 0 ]; then
                                print_success "Created user: $user (using MYSQL_PASSWORD from .env)"
                            else
                                print_error "Failed to create: $user"
                            fi
                        else
                            print_warning "MYSQL_PASSWORD not set in .env, skipping $user"
                        fi
                    done
                fi
                press_enter
                ;;
            3)
                echo ""
                local all_config_users=($(get_config_users))
                for user in "${all_config_users[@]}"; do
                    if user_exists "$user"; then
                        run_query "" "GRANT ALL PRIVILEGES ON *.* TO '$user'@'%' WITH GRANT OPTION"
                        run_query "" "FLUSH PRIVILEGES"
                        print_success "Granted full privileges to: $user"
                    fi
                done
                press_enter
                ;;
            4)
                echo ""
                print_info "Fixing all database and user issues..."
                echo ""
                
                # Create missing databases
for db in "${DBS[@]}"; do
                    if ! db_exists "$db"; then
                        run_query "" "CREATE DATABASE IF NOT EXISTS \`$db\`"
                        print_success "Created database: $db"
                    fi
                done
                
                # Create missing users and grant privileges
                local db_pass="${MYSQL_PASSWORD:-}"
                local all_users=($(get_config_users))
                
                for user in "${all_users[@]}"; do
                    if ! user_exists "$user"; then
                        if [ -n "$db_pass" ]; then
                            run_query "" "CREATE USER IF NOT EXISTS '$user'@'%' IDENTIFIED BY '$db_pass'"
                            print_success "Created user: $user"
                        fi
                    fi
                    
                    if user_exists "$user"; then
                        run_query "" "GRANT ALL PRIVILEGES ON *.* TO '$user'@'%' WITH GRANT OPTION"
                        print_success "Granted privileges to: $user"
                    fi
                done
                
                run_query "" "FLUSH PRIVILEGES"
                echo ""
                print_success "All issues fixed!"
                press_enter
                ;;
            5)
                echo ""
                read -p "  Enter username to create: " new_user
                if [ -n "$new_user" ]; then
                    read -p "  Enter password (or press enter for random): " new_pass
                    if [ -z "$new_pass" ]; then
                        new_pass=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
                        print_warning "Generated password: $new_pass"
                    fi
                    
                    run_query "" "CREATE USER IF NOT EXISTS '$new_user'@'%' IDENTIFIED BY '$new_pass'"
                    run_query "" "GRANT ALL PRIVILEGES ON *.* TO '$new_user'@'%' WITH GRANT OPTION"
                    run_query "" "FLUSH PRIVILEGES"

if [ $? -eq 0 ]; then
                        print_success "Created user: $new_user with full privileges"
                    else
                        print_error "Failed to create user"
                    fi
                fi
                press_enter
                ;;
            6)
                echo ""
                read -p "  Enter username to delete: " del_user
                if [ -n "$del_user" ]; then
                    if [ "$del_user" = "root" ]; then
                        print_error "Cannot delete root user!"
                    else
                        read -p "  Are you sure you want to delete '$del_user'? (y/n) [n]: " confirm
                        if [ "$confirm" = "y" ]; then
                            run_query "" "DROP USER IF EXISTS '$del_user'@'%'"
                            run_query "" "DROP USER IF EXISTS '$del_user'@'localhost'"
                            run_query "" "FLUSH PRIVILEGES"
                            print_success "Deleted user: $del_user"
                        fi
                    fi
                fi
                press_enter
                ;;
            7)
                echo ""
                read -p "  Enter username to show grants for: " show_user
                if [ -n "$show_user" ]; then
                    echo ""
                    echo "  Grants for '$show_user':"
                    run_query "" "SHOW GRANTS FOR '$show_user'@'%'" 2>/dev/null | while read grant; do
                        echo "    $grant"
                    done
                fi
                press_enter
                ;;
            0) return ;;
        esac
    done
}

# =============================================================================
# SHELLDER STATISTICS DATABASE MENU
# =============================================================================

shellder_db_menu() {
    # Check if sqlite3 is available
    if ! command -v sqlite3 &> /dev/null; then
        print_error "sqlite3 is not installed. Install it with: apt install sqlite3"
        press_enter
        return
    fi
    
    # Initialize database if needed
    if ! check_shellder_db 2>/dev/null; then
        print_info "Initializing Shellder statistics database..."
        init_shellder_db
    fi
    
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "    SHELLDER INTERNAL DATABASE (SQLite - Not MariaDB)"
        draw_box_bottom
        echo ""
        echo -e "  ${DIM}This is Shellder's own database for tracking stats & configs.${NC}"
        echo -e "  ${DIM}It is separate from your MariaDB game databases above.${NC}"
        echo ""
        
        # Show database info
        local db_size=$(get_db_size)
        echo -e "  ${WHITE}Database:${NC} $SHELLDER_DB"
        echo -e "  ${WHITE}Size:${NC} $db_size"
        echo ""
        
        # Show discrepancy count
        local disc_count=$(get_discrepancy_count 2>/dev/null || echo "0")
        local config_count=$(get_config_count 2>/dev/null || echo "0")
        
        echo -e "  ${WHITE}Stored Configs:${NC} $config_count"
        if [ "$disc_count" -gt 0 ]; then
            echo -e "  ${RED}Config Discrepancies:${NC} $disc_count ${YELLOW}(requires attention)${NC}"
        else
            echo -e "  ${GREEN}Config Status:${NC} All values match"
        fi
        echo ""
        
        echo "  ${WHITE}${BOLD}View Statistics${NC}"
        echo "  ${DIM}────────────────────────────────────────${NC}"
        echo "    1) All-Time Proxy Stats (Xilriws)"
        echo "    2) All-Time Error Stats"
        echo "    3) All-Time Container Stats"
        echo "    4) Log Summaries (last 7 days)"
        echo "    5) Recent System Events"
        echo "    6) Full Database Statistics"
        echo ""
        echo "  ${WHITE}${BOLD}Configuration Management${NC}"
        echo "  ${DIM}────────────────────────────────────────${NC}"
        echo "    c) View Stored Config Values"
        echo "    d) View Config Discrepancies"
        echo "    v) Validate Configs Now"
        echo "    f) Fix/Update Stored Config"
        echo ""
        echo "  ${WHITE}${BOLD}Maintenance${NC}"
        echo "  ${DIM}────────────────────────────────────────${NC}"
        echo "    7) Optimize Database (Vacuum)"
        echo "    8) Clear Old Records (30+ days)"
        echo "    9) Backup Database"
        echo "    e) Export Table to CSV"
        echo "    r) Reset All Statistics"
        echo "    i) Check Database Integrity"
        echo ""
        echo "    0) Back"
        echo ""
        read -p "  Select option: " choice
        
        case $choice in
            1)
                clear
                echo ""
                draw_box_top
                draw_box_line "         ALL-TIME PROXY STATISTICS"
                draw_box_bottom
                echo ""
                
                local summary=$(get_proxy_stats_summary)
                if [ -n "$summary" ]; then
                    IFS='|' read -r total_proxies total_req total_success total_failed total_timeout success_rate <<< "$summary"
                    echo -e "  ${WHITE}Summary:${NC}"
                    echo -e "    Total Proxies:    ${CYAN}$total_proxies${NC}"
                    echo -e "    Total Requests:   ${CYAN}$total_req${NC}"
                    echo -e "    Successful:       ${GREEN}$total_success${NC}"
                    echo -e "    Failed:           ${RED}$total_failed${NC}"
                    echo -e "    Timeouts:         ${YELLOW}$total_timeout${NC}"
                    echo -e "    Success Rate:     ${CYAN}${success_rate}%${NC}"
                    echo ""
                fi
                
                echo -e "  ${WHITE}Individual Proxy Stats:${NC}"
                echo ""
                get_proxy_stats_all_time
                echo ""
                press_enter
                ;;
            2)
                clear
                echo ""
                draw_box_top
                draw_box_line "         ALL-TIME ERROR STATISTICS"
                draw_box_bottom
                echo ""
                
                echo -e "  ${WHITE}Error Summary by Service:${NC}"
                echo ""
                get_error_summary
                echo ""
                echo -e "  ${WHITE}Top 50 Errors (All Time):${NC}"
                echo ""
                get_error_stats_all_time
                echo ""
                press_enter
                ;;
            3)
                clear
                echo ""
                draw_box_top
                draw_box_line "         ALL-TIME CONTAINER STATISTICS"
                draw_box_bottom
                echo ""
                get_container_stats_all_time
                echo ""
                press_enter
                ;;
            4)
                clear
                echo ""
                draw_box_top
                draw_box_line "         LOG SUMMARIES (LAST 7 DAYS)"
                draw_box_bottom
                echo ""
                get_log_summaries "" 7
                echo ""
                press_enter
                ;;
            5)
                clear
                echo ""
                draw_box_top
                draw_box_line "         RECENT SYSTEM EVENTS"
                draw_box_bottom
                echo ""
                get_recent_events 30
                echo ""
                press_enter
                ;;
            6)
                clear
                echo ""
                draw_box_top
                draw_box_line "         DATABASE STATISTICS"
                draw_box_bottom
                echo ""
                get_db_stats
                echo ""
                press_enter
                ;;
            c|C)
                clear
                echo ""
                draw_box_top
                draw_box_line "         STORED CONFIGURATION VALUES"
                draw_box_bottom
                echo ""
                echo -e "  ${DIM}Values marked ******** are secrets (hidden for security)${NC}"
                echo ""
                get_all_config_values
                echo ""
                press_enter
                ;;
            d|D)
                clear
                echo ""
                draw_box_top
                draw_box_line "         CONFIGURATION DISCREPANCIES"
                draw_box_bottom
                echo ""
                local disc_count=$(get_discrepancy_count 2>/dev/null || echo "0")
                if [ "$disc_count" -eq 0 ]; then
                    echo -e "  ${GREEN}No discrepancies found!${NC}"
                    echo ""
                    echo "  All configuration values in your files match the stored values."
                else
                    echo -e "  ${RED}Found $disc_count discrepancy(ies):${NC}"
                    echo ""
                    get_config_discrepancies
                fi
                echo ""
                press_enter
                ;;
            v|V)
                clear
                echo ""
                draw_box_top
                draw_box_line "         VALIDATE CONFIGURATIONS"
                draw_box_bottom
                echo ""
                print_info "Checking .env file against stored values..."
                echo ""
                
                if [ -f ".env" ]; then
                    local result=$(check_env_configs ".env")
                    local matched=$(echo "$result" | cut -d'|' -f1)
                    local discrepancies=$(echo "$result" | cut -d'|' -f2)
                    local new_configs=$(echo "$result" | cut -d'|' -f3)
                    
                    echo -e "  ${WHITE}Results:${NC}"
                    echo -e "    Matched values:      ${GREEN}$matched${NC}"
                    echo -e "    Discrepancies:       ${RED}$discrepancies${NC}"
                    echo -e "    New values stored:   ${CYAN}$new_configs${NC}"
                    echo ""
                    
                    if [ "$discrepancies" -gt 0 ]; then
                        echo -e "  ${YELLOW}⚠ Some values differ from what was previously stored.${NC}"
                        echo "  Use 'View Config Discrepancies' (d) to see details."
                        echo "  Use 'Fix/Update Stored Config' (f) to update stored values."
                    else
                        echo -e "  ${GREEN}✓ All configurations match!${NC}"
                    fi
                else
                    print_error ".env file not found"
                fi
                echo ""
                press_enter
                ;;
            f|F)
                echo ""
                echo "  ${WHITE}Fix/Update Stored Configuration${NC}"
                echo "  ${DIM}────────────────────────────────────────${NC}"
                echo ""
                echo "  Options:"
                echo "    1) Accept current file values as correct (update database)"
                echo "    2) View a stored value"
                echo "    3) Clear all discrepancies (mark as resolved)"
                echo "    4) Delete a stored config key"
                echo ""
                read -p "  Select option [1-4]: " fix_choice
                
                case $fix_choice in
                    1)
                        echo ""
                        print_info "Validating and updating stored values from .env file..."
                        echo ""
                        
                        if [ ! -f ".env" ]; then
                            print_error ".env file not found"
                            press_enter
                            continue
                        fi
                        
                        # Load env values
                        local stored_count=0
                        local skipped_count=0
                        local failed_count=0
                        
                        # First, load all values
                        declare -A env_values
                        while IFS='=' read -r key value; do
                            [[ "$key" =~ ^#.*$ ]] && continue
                            [[ -z "$key" ]] && continue
                            [[ "$key" == "UID" || "$key" == "GID" ]] && continue
                            value="${value%\"}"
                            value="${value#\"}"
                            [ -z "$value" ] && continue
                            env_values["$key"]="$value"
                        done < ".env"
                        
                        # Validate database credentials before storing
                        local db_validated=false
                        if [ -n "${env_values[MYSQL_ROOT_PASSWORD]}" ]; then
                            echo -n "  Validating MYSQL_ROOT_PASSWORD... "
                            if validate_mariadb_root "${env_values[MYSQL_ROOT_PASSWORD]}"; then
                                echo -e "${GREEN}OK${NC}"
                                update_stored_config "MYSQL_ROOT_PASSWORD" "${env_values[MYSQL_ROOT_PASSWORD]}" ".env"
                                ((stored_count++))
                                db_validated=true
                            else
                                echo -e "${RED}FAILED${NC}"
                                print_error "Cannot connect to MariaDB with this password - NOT storing"
                                ((failed_count++))
                            fi
                        fi
                        
                        if [ -n "${env_values[MYSQL_USER]}" ] && [ -n "${env_values[MYSQL_PASSWORD]}" ]; then
                            echo -n "  Validating MYSQL_USER/PASSWORD... "
                            if validate_mariadb_credentials "${env_values[MYSQL_USER]}" "${env_values[MYSQL_PASSWORD]}"; then
                                echo -e "${GREEN}OK${NC}"
                                update_stored_config "MYSQL_USER" "${env_values[MYSQL_USER]}" ".env"
                                update_stored_config "MYSQL_PASSWORD" "${env_values[MYSQL_PASSWORD]}" ".env"
                                ((stored_count+=2))
                            else
                                echo -e "${RED}FAILED${NC}"
                                print_error "Cannot authenticate with these DB credentials - NOT storing"
                                ((failed_count+=2))
                            fi
                        fi
                        
                        # Store other values (can't validate but check they're not defaults)
                        for key in "${!env_values[@]}"; do
                            # Skip ones we already handled
                            [[ "$key" == "MYSQL_ROOT_PASSWORD" ]] && continue
                            [[ "$key" == "MYSQL_USER" ]] && continue
                            [[ "$key" == "MYSQL_PASSWORD" ]] && continue
                            
                            local value="${env_values[$key]}"
                            
                            if is_default_value "$key" "$value"; then
                                echo -e "  ${YELLOW}Skipped${NC} $key (default value)"
                                ((skipped_count++))
                                continue
                            fi
                            
                            # Validate PUID/PGID are numbers
                            if [[ "$key" == "PUID" || "$key" == "PGID" ]]; then
                                if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                                    echo -e "  ${RED}Invalid${NC} $key (not a number)"
                                    ((failed_count++))
                                    continue
                                fi
                            fi
                            
                            # Validate secrets are long enough
                            if [[ "$key" =~ SECRET|PASSWORD|TOKEN|BEARER ]]; then
                                if [ ${#value} -lt 8 ]; then
                                    echo -e "  ${RED}Invalid${NC} $key (too short)"
                                    ((failed_count++))
                                    continue
                                fi
                            fi
                            
                            update_stored_config "$key" "$value" ".env"
                            ((stored_count++))
                        done
                        
                        echo ""
                        print_success "$stored_count values stored"
                        [ $skipped_count -gt 0 ] && print_warning "$skipped_count values skipped (defaults)"
                        [ $failed_count -gt 0 ] && print_error "$failed_count values rejected (validation failed)"
                        ;;
                    2)
                        echo ""
                        read -p "  Enter config key to view: " view_key
                        if [ -n "$view_key" ]; then
                            local stored=$(get_config_display "$view_key")
                            if [ -n "$stored" ]; then
                                echo -e "  ${WHITE}$view_key${NC} = ${CYAN}$stored${NC}"
                            else
                                echo -e "  ${YELLOW}Key not found in database${NC}"
                            fi
                        fi
                        ;;
                    3)
                        echo ""
                        read -p "  Clear all discrepancies? (y/n) [n]: " confirm
                        if [ "$confirm" = "y" ]; then
                            clear_config_discrepancies
                            print_success "All discrepancies cleared"
                        fi
                        ;;
                    4)
                        echo ""
                        read -p "  Enter config key to delete: " del_key
                        if [ -n "$del_key" ]; then
                            read -p "  Delete '$del_key'? (y/n) [n]: " confirm
                            if [ "$confirm" = "y" ]; then
                                delete_config_value "$del_key"
                                print_success "Config key deleted"
                            fi
                        fi
                        ;;
                esac
                press_enter
                ;;
            7)
                echo ""
                print_info "Optimizing database..."
                if vacuum_db; then
                    print_success "Database optimized successfully"
                else
                    print_error "Failed to optimize database"
                fi
                press_enter
                ;;
            8)
                echo ""
                read -p "  Clear records older than how many days? [30]: " days
                days="${days:-30}"
                echo ""
                print_info "Clearing records older than $days days..."
                clear_old_records "$days"
                print_success "Old records cleared"
                press_enter
                ;;
            9)
                echo ""
                print_info "Creating backup..."
                local backup_path=$(backup_db)
                if [ -n "$backup_path" ] && [ -f "$backup_path" ]; then
                    print_success "Backup created: $backup_path"
                else
                    print_error "Failed to create backup"
                fi
                press_enter
                ;;
            e|E)
                echo ""
                echo "  Available tables:"
                echo "    1) proxy_stats"
                echo "    2) error_stats"
                echo "    3) container_stats"
                echo "    4) log_summaries"
                echo "    5) system_events"
                echo ""
                read -p "  Select table to export [1-5]: " table_choice
                
                local table=""
                case $table_choice in
                    1) table="proxy_stats" ;;
                    2) table="error_stats" ;;
                    3) table="container_stats" ;;
                    4) table="log_summaries" ;;
                    5) table="system_events" ;;
                esac
                
                if [ -n "$table" ]; then
                    local csv_path=$(export_table_csv "$table")
                    print_success "Exported to: $csv_path"
                fi
                press_enter
                ;;
            r|R)
                echo ""
                echo -e "  ${RED}${BOLD}WARNING: This will delete ALL statistics!${NC}"
                read -p "  Type 'RESET' to confirm: " confirm
                if [ "$confirm" = "RESET" ]; then
                    reset_all_stats
                    print_success "All statistics have been reset"
                else
                    print_info "Reset cancelled"
                fi
                press_enter
                ;;
            i|I)
                echo ""
                print_info "Checking database integrity..."
                local integrity=$(check_db_integrity)
                if [ "$integrity" = "ok" ]; then
                    print_success "Database integrity: OK"
                else
                    print_error "Database integrity issue: $integrity"
                fi
                press_enter
                ;;
            0) return ;;
        esac
    done
}

# =============================================================================
# ENHANCED MARIADB MANAGEMENT FUNCTIONS
# =============================================================================

# Show server status
show_server_status() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              MARIADB SERVER STATUS"
    draw_box_bottom
    echo ""
    
    echo -e "  ${WHITE}${BOLD}Server Information${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    
    local version=$(run_query "" "SELECT VERSION()" | tail -1)
    local uptime=$(run_query "" "SHOW STATUS LIKE 'Uptime'" | awk '{print $2}')
    local uptime_days=$((uptime / 86400))
    local uptime_hours=$(( (uptime % 86400) / 3600 ))
    
    echo -e "    Version:        ${CYAN}$version${NC}"
    echo -e "    Uptime:         ${CYAN}${uptime_days}d ${uptime_hours}h${NC}"
    
    local threads=$(run_query "" "SHOW STATUS LIKE 'Threads_connected'" | awk '{print $2}')
    local max_conn=$(run_query "" "SHOW VARIABLES LIKE 'max_connections'" | awk '{print $2}')
    echo -e "    Connections:    ${CYAN}$threads / $max_conn${NC}"
    echo ""
    
    echo -e "  ${WHITE}${BOLD}Memory Usage${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    local buffer_pool=$(run_query "" "SHOW VARIABLES LIKE 'innodb_buffer_pool_size'" | awk '{print $2}')
    local buffer_pool_mb=$((buffer_pool / 1024 / 1024))
    echo -e "    InnoDB Buffer Pool:  ${CYAN}${buffer_pool_mb}MB${NC}"
    
    local key_buffer=$(run_query "" "SHOW VARIABLES LIKE 'key_buffer_size'" | awk '{print $2}')
    local key_buffer_mb=$((key_buffer / 1024 / 1024))
    echo -e "    Key Buffer:          ${CYAN}${key_buffer_mb}MB${NC}"
    echo ""
    
    echo -e "  ${WHITE}${BOLD}Query Statistics${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    local questions=$(run_query "" "SHOW STATUS LIKE 'Questions'" | awk '{print $2}')
    local slow_queries=$(run_query "" "SHOW STATUS LIKE 'Slow_queries'" | awk '{print $2}')
    local qps=$((questions / (uptime + 1)))
    echo -e "    Total Queries:   ${CYAN}$questions${NC}"
    echo -e "    Queries/sec:     ${CYAN}$qps${NC}"
    echo -e "    Slow Queries:    ${YELLOW}$slow_queries${NC}"
    echo ""
    
    press_enter
}

# Show active connections/processes
show_process_list() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              ACTIVE CONNECTIONS"
    draw_box_bottom
    echo ""
    
    run_query "" "SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE FROM information_schema.PROCESSLIST ORDER BY TIME DESC"
    echo ""
    
    echo "  Options:"
    echo "    k) Kill a connection by ID"
    echo "    0) Back"
    echo ""
    read -p "  Select: " choice
    
    case "$choice" in
        k|K)
            read -p "  Enter process ID to kill: " pid
            if [ -n "$pid" ]; then
                run_query "" "KILL $pid" 2>/dev/null
                print_success "Process $pid killed"
            fi
            press_enter
            ;;
    esac
}

# Database browser
database_browser() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "              DATABASE BROWSER"
        draw_box_bottom
        echo ""
        
        echo -e "  ${WHITE}Available Databases:${NC}"
        echo ""
        local i=1
        local dbs=()
        while IFS= read -r db; do
            [ -n "$db" ] && [ "$db" != "Database" ] && {
                dbs+=("$db")
                local size=$(run_query "" "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) FROM information_schema.tables WHERE table_schema = '$db'" | tail -1)
                echo "    $i) $db ${DIM}(${size:-0}MB)${NC}"
                ((i++))
            }
        done < <(run_query "" "SHOW DATABASES")
        
        echo ""
        echo "    0) Back"
        echo ""
        read -p "  Select database: " choice
        
        [ "$choice" = "0" ] && return
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#dbs[@]} ]; then
            browse_database "${dbs[$((choice-1))]}"
        fi
    done
}

# Browse tables in a database
browse_database() {
    local db="$1"
    
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "              DATABASE: $db"
        draw_box_bottom
        echo ""
        
        echo -e "  ${WHITE}Tables:${NC}"
        echo ""
        local i=1
        local tables=()
        while IFS= read -r table; do
            [ -n "$table" ] && [ "$table" != "Tables_in_$db" ] && {
                tables+=("$table")
                local rows=$(run_query "$db" "SELECT COUNT(*) FROM \`$table\`" 2>/dev/null | tail -1)
                echo "    $i) $table ${DIM}($rows rows)${NC}"
                ((i++))
            }
        done < <(run_query "$db" "SHOW TABLES")
        
        echo ""
        echo "    q) Run custom query"
        echo "    0) Back"
        echo ""
        read -p "  Select table: " choice
        
        case "$choice" in
            0) return ;;
            q|Q) run_custom_query "$db" ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#tables[@]} ]; then
                    browse_table "$db" "${tables[$((choice-1))]}"
                fi
                ;;
        esac
    done
}

# Browse a specific table
browse_table() {
    local db="$1"
    local table="$2"
    
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "              TABLE: $db.$table"
        draw_box_bottom
        echo ""
        
        # Show table info
        local rows=$(run_query "$db" "SELECT COUNT(*) FROM \`$table\`" | tail -1)
        local size=$(run_query "" "SELECT ROUND((data_length + index_length) / 1024 / 1024, 2) FROM information_schema.tables WHERE table_schema = '$db' AND table_name = '$table'" | tail -1)
        
        echo -e "  Rows: ${CYAN}$rows${NC}    Size: ${CYAN}${size}MB${NC}"
        echo ""
        
        echo "  Options:"
        echo "    1) View structure (columns)"
        echo "    2) View indexes"
        echo "    3) View sample data (first 20 rows)"
        echo "    4) Count rows"
        echo "    5) Run custom query on this table"
        echo "    6) Truncate table (DANGEROUS)"
        echo "    7) Optimize table"
        echo "    0) Back"
        echo ""
        read -p "  Select: " choice
        
        case "$choice" in
            1)
                echo ""
                run_query "$db" "DESCRIBE \`$table\`"
                press_enter
                ;;
            2)
                echo ""
                run_query "$db" "SHOW INDEX FROM \`$table\`"
                press_enter
                ;;
            3)
                echo ""
                run_query "$db" "SELECT * FROM \`$table\` LIMIT 20"
                press_enter
                ;;
            4)
                echo ""
                local count=$(run_query "$db" "SELECT COUNT(*) FROM \`$table\`" | tail -1)
                echo -e "  Row count: ${CYAN}$count${NC}"
                press_enter
                ;;
            5)
                run_custom_query "$db" "$table"
                ;;
            6)
                echo ""
                echo -e "  ${RED}WARNING: This will delete ALL data in $table!${NC}"
                read -p "  Type 'TRUNCATE' to confirm: " confirm
                if [ "$confirm" = "TRUNCATE" ]; then
                    run_query "$db" "TRUNCATE TABLE \`$table\`"
                    print_success "Table truncated"
                fi
                press_enter
                ;;
            7)
                echo ""
                print_info "Optimizing $table..."
                run_query "$db" "OPTIMIZE TABLE \`$table\`"
                print_success "Table optimized"
                press_enter
                ;;
            0) return ;;
        esac
    done
}

# Run custom SQL query
run_custom_query() {
    local db="$1"
    local table="$2"
    
    clear
    echo ""
    draw_box_top
    draw_box_line "              SQL QUERY CONSOLE"
    draw_box_bottom
    echo ""
    
    if [ -n "$db" ]; then
        echo -e "  Database: ${CYAN}$db${NC}"
    fi
    if [ -n "$table" ]; then
        echo -e "  Table: ${CYAN}$table${NC}"
    fi
    echo ""
    echo -e "  ${DIM}Enter SQL query (end with semicolon, or 'q' to quit):${NC}"
    echo ""
    
    while true; do
        read -p "  SQL> " query
        
        [ "$query" = "q" ] || [ "$query" = "Q" ] && return
        [ -z "$query" ] && continue
        
        echo ""
        if [ -n "$db" ]; then
            run_query "$db" "$query"
        else
            run_query "" "$query"
        fi
        echo ""
    done
}

# Performance tuning menu
performance_tuning_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "              PERFORMANCE TUNING"
        draw_box_bottom
        echo ""
        
        echo "  Options:"
        echo "    1) View current server variables"
        echo "    2) Buffer pool analysis"
        echo "    3) Query cache status"
        echo "    4) Slow query analysis"
        echo "    5) Connection pool status"
        echo "    6) InnoDB status"
        echo "    7) Recommended settings for this server"
        echo "    0) Back"
        echo ""
        read -p "  Select: " choice
        
        case "$choice" in
            1)
                clear
                echo ""
                echo "  Key Server Variables:"
                echo ""
                run_query "" "SHOW VARIABLES WHERE Variable_name IN ('max_connections', 'innodb_buffer_pool_size', 'innodb_log_file_size', 'innodb_flush_log_at_trx_commit', 'query_cache_size', 'query_cache_type', 'key_buffer_size', 'tmp_table_size', 'max_heap_table_size', 'thread_cache_size', 'table_open_cache')"
                press_enter
                ;;
            2)
                clear
                echo ""
                echo "  InnoDB Buffer Pool Status:"
                echo ""
                run_query "" "SHOW STATUS WHERE Variable_name LIKE 'Innodb_buffer_pool%'"
                echo ""
                local reads=$(run_query "" "SHOW STATUS LIKE 'Innodb_buffer_pool_reads'" | awk '{print $2}')
                local requests=$(run_query "" "SHOW STATUS LIKE 'Innodb_buffer_pool_read_requests'" | awk '{print $2}')
                if [ "$requests" -gt 0 ]; then
                    local hit_rate=$(echo "scale=2; (1 - $reads / $requests) * 100" | bc 2>/dev/null || echo "N/A")
                    echo -e "  Buffer Pool Hit Rate: ${CYAN}${hit_rate}%${NC}"
                fi
                press_enter
                ;;
            3)
                clear
                echo ""
                echo "  Query Cache Status:"
                echo ""
                run_query "" "SHOW STATUS LIKE 'Qcache%'"
                press_enter
                ;;
            4)
                clear
                echo ""
                echo "  Slow Query Status:"
                echo ""
                run_query "" "SHOW VARIABLES LIKE 'slow_query%'"
                run_query "" "SHOW VARIABLES LIKE 'long_query_time'"
                echo ""
                local slow=$(run_query "" "SHOW STATUS LIKE 'Slow_queries'" | awk '{print $2}')
                echo -e "  Total Slow Queries: ${YELLOW}$slow${NC}"
                press_enter
                ;;
            5)
                clear
                echo ""
                echo "  Connection Status:"
                echo ""
                run_query "" "SHOW STATUS LIKE 'Threads%'"
                run_query "" "SHOW STATUS LIKE 'Connections'"
                run_query "" "SHOW STATUS LIKE 'Max_used_connections'"
                press_enter
                ;;
            6)
                clear
                echo ""
                echo "  InnoDB Engine Status:"
                echo ""
                run_query "" "SHOW ENGINE INNODB STATUS" 2>/dev/null | head -100
                echo ""
                echo -e "  ${DIM}(Showing first 100 lines)${NC}"
                press_enter
                ;;
            7)
                show_tuning_recommendations
                ;;
            0) return ;;
        esac
    done
}

# Show tuning recommendations
show_tuning_recommendations() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              TUNING RECOMMENDATIONS"
    draw_box_bottom
    echo ""
    
    # Get system info
    local total_ram=$(free -b 2>/dev/null | awk '/Mem:/ {print $2}')
    local total_ram_gb=$((total_ram / 1024 / 1024 / 1024))
    
    echo -e "  ${WHITE}System:${NC} ${total_ram_gb}GB RAM detected"
    echo ""
    
    # Calculate recommendations
    local recommended_buffer=$((total_ram * 70 / 100))
    local recommended_buffer_gb=$((recommended_buffer / 1024 / 1024 / 1024))
    
    echo -e "  ${WHITE}Recommended Settings:${NC}"
    echo ""
    echo "  # For ${total_ram_gb}GB RAM server:"
    echo ""
    echo "  [mysqld]"
    echo "  innodb_buffer_pool_size = ${recommended_buffer_gb}G"
    echo "  innodb_log_file_size = 512M"
    echo "  innodb_flush_log_at_trx_commit = 2"
    echo "  max_connections = 500"
    echo "  thread_cache_size = 50"
    echo "  table_open_cache = 4000"
    echo "  tmp_table_size = 256M"
    echo "  max_heap_table_size = 256M"
    echo ""
    
    echo -e "  ${DIM}These settings are in: mysql_data/mariadb.cnf${NC}"
    
    press_enter
}

# Backup management
backup_management_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "              DATABASE BACKUP MANAGEMENT"
        draw_box_bottom
        echo ""
        
        echo "  Options:"
        echo "    1) Backup single database"
        echo "    2) Backup all Aegis databases"
        echo "    3) View existing backups"
        echo "    4) Restore from backup"
        echo "    5) Delete old backups"
        echo "    0) Back"
        echo ""
        read -p "  Select: " choice
        
        case "$choice" in
            1)
                echo ""
                echo "  Available databases:"
                local i=1
                for db in "${DBS[@]}"; do
                    if db_exists "$db"; then
                        echo "    $i) $db"
                    else
                        echo "    $i) $db ${DIM}(not exists)${NC}"
                    fi
                    ((i++))
                done
                echo ""
                read -p "  Select database [1-${#DBS[@]}]: " db_choice
                
                if [[ "$db_choice" =~ ^[0-9]+$ ]] && [ "$db_choice" -ge 1 ] && [ "$db_choice" -le ${#DBS[@]} ]; then
                    local db="${DBS[$((db_choice-1))]}"
                    backup_single_database "$db"
                fi
                ;;
            2)
                backup_all_databases
                ;;
            3)
                show_existing_backups
                ;;
            4)
                restore_from_backup
                ;;
            5)
                delete_old_backups
                ;;
            0) return ;;
        esac
    done
}

# Backup single database
backup_single_database() {
    local db="$1"
    local backup_dir="backups/database"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/${db}_${timestamp}.sql"
    
    mkdir -p "$backup_dir"
    
    echo ""
    print_info "Backing up $db..."
    
    if command -v mysqldump &>/dev/null; then
        mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" "$db" > "$backup_file" 2>/dev/null
    elif command -v mariadb-dump &>/dev/null; then
        mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" "$db" > "$backup_file" 2>/dev/null
    else
        # Try via Docker
        docker exec database mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" "$db" > "$backup_file" 2>/dev/null
    fi
    
    if [ -f "$backup_file" ] && [ -s "$backup_file" ]; then
        local size=$(du -h "$backup_file" | cut -f1)
        print_success "Backup created: $backup_file ($size)"
        
        # Fix ownership
        [ -n "$REAL_USER" ] && chown -R "$REAL_USER:$REAL_GROUP" "$backup_dir" 2>/dev/null
    else
        print_error "Backup failed"
        rm -f "$backup_file"
    fi
    
    press_enter
}

# Backup all databases
backup_all_databases() {
    local backup_dir="backups/database"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    mkdir -p "$backup_dir"
    
    echo ""
    for db in "${DBS[@]}"; do
        if db_exists "$db"; then
            print_info "Backing up $db..."
            local backup_file="$backup_dir/${db}_${timestamp}.sql"
            
            if command -v mysqldump &>/dev/null; then
                mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" "$db" > "$backup_file" 2>/dev/null
            elif command -v mariadb-dump &>/dev/null; then
                mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" "$db" > "$backup_file" 2>/dev/null
            else
                docker exec database mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" "$db" > "$backup_file" 2>/dev/null
            fi
            
            if [ -f "$backup_file" ] && [ -s "$backup_file" ]; then
                print_success "$db backed up"
            else
                print_error "$db backup failed"
                rm -f "$backup_file"
            fi
        fi
    done
    
    [ -n "$REAL_USER" ] && chown -R "$REAL_USER:$REAL_GROUP" "$backup_dir" 2>/dev/null
    
    press_enter
}

# Show existing backups
show_existing_backups() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              EXISTING BACKUPS"
    draw_box_bottom
    echo ""
    
    local backup_dir="backups/database"
    
    if [ ! -d "$backup_dir" ]; then
        echo -e "  ${YELLOW}No backups found${NC}"
        press_enter
        return
    fi
    
    echo -e "  ${WHITE}Database Backups:${NC}"
    echo ""
    
    ls -lh "$backup_dir"/*.sql 2>/dev/null | while read -r line; do
        echo "    $line"
    done
    
    if [ -z "$(ls "$backup_dir"/*.sql 2>/dev/null)" ]; then
        echo -e "  ${YELLOW}No SQL backups found${NC}"
    fi
    
    press_enter
}

# Restore from backup
restore_from_backup() {
    local backup_dir="backups/database"
    
    if [ ! -d "$backup_dir" ]; then
        print_error "No backup directory found"
        press_enter
        return
    fi
    
    clear
    echo ""
    draw_box_top
    draw_box_line "              RESTORE FROM BACKUP"
    draw_box_bottom
    echo ""
    
    echo -e "  ${WHITE}Available backups:${NC}"
    echo ""
    
    local i=1
    local files=()
    for file in "$backup_dir"/*.sql; do
        [ -f "$file" ] || continue
        files+=("$file")
        local name=$(basename "$file")
        local size=$(du -h "$file" | cut -f1)
        echo "    $i) $name ($size)"
        ((i++))
    done
    
    if [ ${#files[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}No backups found${NC}"
        press_enter
        return
    fi
    
    echo ""
    echo "    0) Cancel"
    echo ""
    read -p "  Select backup to restore: " choice
    
    [ "$choice" = "0" ] && return
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#files[@]} ]; then
        local file="${files[$((choice-1))]}"
        local name=$(basename "$file")
        local db=$(echo "$name" | sed 's/_[0-9]*_[0-9]*.sql$//')
        
        echo ""
        echo -e "  ${YELLOW}WARNING: This will overwrite data in database '$db'${NC}"
        read -p "  Continue? (y/n) [n]: " confirm
        
        if [ "$confirm" = "y" ]; then
            print_info "Restoring $db from $name..."
            
            if command -v mysql &>/dev/null; then
                mysql -u root -p"$MYSQL_ROOT_PASSWORD" "$db" < "$file" 2>/dev/null
            else
                docker exec -i database mysql -u root -p"$MYSQL_ROOT_PASSWORD" "$db" < "$file" 2>/dev/null
            fi
            
            print_success "Database restored"
        fi
    fi
    
    press_enter
}

# Delete old backups
delete_old_backups() {
    local backup_dir="backups/database"
    
    echo ""
    read -p "  Delete backups older than how many days? [7]: " days
    days="${days:-7}"
    
    print_info "Finding backups older than $days days..."
    
    local count=$(find "$backup_dir" -name "*.sql" -mtime +$days 2>/dev/null | wc -l)
    
    if [ "$count" -eq 0 ]; then
        echo -e "  ${GREEN}No old backups found${NC}"
    else
        echo "  Found $count backup(s) to delete"
        read -p "  Delete them? (y/n) [n]: " confirm
        
        if [ "$confirm" = "y" ]; then
            find "$backup_dir" -name "*.sql" -mtime +$days -delete 2>/dev/null
            print_success "Deleted $count old backup(s)"
        fi
    fi
    
    press_enter
}

# Replication status (for future use)
show_replication_status() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              REPLICATION STATUS"
    draw_box_bottom
    echo ""
    
    local slave_status=$(run_query "" "SHOW SLAVE STATUS\G" 2>/dev/null)
    
    if [ -z "$slave_status" ] || [[ "$slave_status" == *"Empty"* ]]; then
        echo -e "  ${DIM}Replication is not configured${NC}"
    else
        echo "$slave_status"
    fi
    
    press_enter
}

# Main Maintenance Menu - Enhanced
run_maintenance_mode() {
    [ "$LOG_AVAILABLE" = "true" ] && log_info "Entering MariaDB Maintenance Mode"
    
    # Prompt for credentials if not loaded from .env
    if [ "$ENV_LOADED" != "true" ] || [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        prompt_db_credentials
    fi
    
    # Check connection first
    setup_mysql_cmd
    if ! test_db_connection; then
        print_error "Cannot connect to MariaDB"
        [ "$LOG_AVAILABLE" = "true" ] && log_error "MariaDB connection failed - cannot enter maintenance mode"
        echo ""
        echo "  Possible causes:"
        echo "    • Wrong root password"
        echo "    • MariaDB not running (try: docker compose up -d database)"
        echo "    • MariaDB not installed (use Setup Mode first)"
        echo ""
        echo "  Would you like to enter different credentials? (y/n)"
        read -p "  " retry
        if [ "$retry" = "y" ]; then
            MYSQL_ROOT_PASSWORD=""
            prompt_db_credentials
            setup_mysql_cmd
            if ! test_db_connection; then
                print_error "Still cannot connect. Please verify MariaDB is running."
                [ "$LOG_AVAILABLE" = "true" ] && log_error "MariaDB connection failed after credential retry"
                press_enter
                return
            fi
        else
            [ "$LOG_AVAILABLE" = "true" ] && log_warn "User declined to retry MariaDB credentials"
            press_enter
            return
        fi
    fi
    
    [ "$LOG_AVAILABLE" = "true" ] && log_info "MariaDB connection successful"

    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "         MARIADB DATABASE MANAGEMENT SYSTEM"
        draw_box_line ""
        draw_box_line "              Aegis AIO by The Pokemod Group"
        draw_box_bottom
        echo ""
        
        # Quick status line
        local threads=$(run_query "" "SHOW STATUS LIKE 'Threads_connected'" 2>/dev/null | awk '{print $2}')
        local uptime=$(run_query "" "SHOW STATUS LIKE 'Uptime'" 2>/dev/null | awk '{print $2}')
        local uptime_days=$((${uptime:-0} / 86400))
        echo -e "  ${DIM}Status: ${GREEN}●${NC} ${DIM}Connected | ${threads:-0} active connections | Uptime: ${uptime_days}d${NC}"
        echo ""
        
        echo -e "  ${WHITE}${BOLD}Server & Monitoring${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo "    1) Server Status Dashboard"
        echo "    2) Active Connections (Process List)"
        echo "    3) Performance Tuning"
        echo ""
        
        echo -e "  ${WHITE}${BOLD}Database Management${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo "    4) Database Browser (Query Console)"
        echo "    5) Database & User Management"
        echo "    6) Backup & Restore"
        echo ""
        
        echo -e "  ${WHITE}${BOLD}Aegis Data Maintenance${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo "    7) Account Cleanup (banned, invalid)"
        echo "    8) Map Data Cleanup (stale data)"
        echo "    9) Nest Management"
        echo "    t) Table Optimization"
        echo ""
        
        echo -e "  ${WHITE}${BOLD}Shellder Internal (SQLite - Not MariaDB)${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo "    s) Shellder Stats & Config Database"
        echo ""
        
        echo "    r) Refresh"
        if [ "$SHELLDER_LAUNCHER" = "1" ]; then
            echo "    0) Return to Main Menu"
        else
            echo "    0) Exit"
        fi
        echo ""
        read -p "  Select option: " choice

        case $choice in
            1) show_server_status ;;
            2) show_process_list ;;
            3) performance_tuning_menu ;;
            4) database_browser ;;
            5) db_user_management_menu ;;
            6) backup_management_menu ;;
            7) account_cleanup_menu ;;
            8) map_data_cleanup_menu ;;
            9) nest_management_menu ;;
            t|T) general_maintenance_menu ;;
            s|S) shellder_db_menu ;;
            r|R) continue ;;
            0) 
                echo ""
                if [ "$SHELLDER_LAUNCHER" = "1" ]; then
                    return_to_main
                else
                    print_success "Goodbye!"
                    exit 0
                fi
                ;;
        esac
    done
}

# =============================================================================
# MAIN SCRIPT
# =============================================================================

return_to_main() {
    # Restore file ownership before exiting
    restore_ownership
    
    if [ "$SHELLDER_LAUNCHER" = "1" ]; then
        echo ""
        echo -e "${CYAN}Returning to Shellder Control Panel...${NC}"
        sleep 1
    fi
    exit 0
}

main() {
    check_root
    load_env

    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "           MARIADB DATABASE MANAGER"
        draw_box_line ""
        draw_box_line "              By The Pokemod Group"
        draw_box_bottom
        echo ""
        echo -e "  ${WHITE}${BOLD}Select Mode:${NC}"
        echo ""
        echo -e "  ${CYAN}1) Setup Mode${NC} ${DIM}(First-time installation)${NC}"
        echo "       • Install/configure MariaDB server"
        echo "       • Create Aegis databases (dragonite, golbat, etc.)"
        echo "       • Create database user with permissions"
        echo "       • Auto-tune for your server's resources"
        echo ""
        echo -e "  ${CYAN}2) Maintenance Mode${NC} ${DIM}(Full MariaDB Management)${NC}"
        echo "       • Server status & performance monitoring"
        echo "       • Database browser & SQL query console"
        echo "       • Backup & restore databases"
        echo "       • Account & map data cleanup"
        echo "       • Table optimization & repair"
        echo "       • User & permission management"
        echo ""
        if [ "$SHELLDER_LAUNCHER" = "1" ]; then
            echo "    0) Return to Main Menu"
            echo ""
        fi
        read -p "  Select mode [1-2]: " mode

        case $mode in
            1) run_setup_mode ;;
            2) run_maintenance_mode ;;
            0)
                if [ "$SHELLDER_LAUNCHER" = "1" ]; then
                    return_to_main
                fi
                ;;
            *)
                print_error "Invalid selection"
                sleep 1
                ;;
        esac
    done
}

# Run main function
main "$@"
