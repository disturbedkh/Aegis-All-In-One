#!/bin/bash

# =============================================================================
# Shellder 2.0 - Database Setup & Maintenance Script for Aegis AIO
# =============================================================================
# This script has two modes:
#   SETUP MODE:
#     - MariaDB installation (if needed)
#     - System resource detection and MariaDB tuning
#     - Database creation
#     - User creation with proper permissions
#
#   MAINTENANCE MODE:
#     - Status dashboard (MariaDB, databases, accounts, data counts)
#     - Account cleanup (banned, invalid, auth-banned)
#     - Data cleanup (stale pokestops, gyms, spawnpoints)
#     - Nest management (unknown nests)
#     - General database maintenance (optimize, analyze, repair)
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
        print_error "Please run this script as root (e.g., sudo bash dbsetup.sh)"
        exit 1
    fi
}

# Restore file ownership to original user
restore_ownership() {
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        chown "$REAL_USER:$REAL_GROUP" mysql_data/mariadb.cnf 2>/dev/null || true
        chown "$REAL_USER:$REAL_GROUP" .env 2>/dev/null || true
        chown "$REAL_USER:$REAL_GROUP" *.sh *.yaml *.yml *.md 2>/dev/null || true
        chown -R "$REAL_USER:$REAL_GROUP" mysql_data 2>/dev/null || true
    fi
}

# Set up trap to restore ownership on exit
trap restore_ownership EXIT

load_env() {
if [ ! -f ".env" ]; then
        print_error ".env file not found. Have you run the initial setup script?"
  exit 1
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

    # Check/install MariaDB
    if ! check_mariadb_installed; then
        read -p "MariaDB is not installed. Install now? (y/n) [y]: " INSTALL_CHOICE
        INSTALL_CHOICE=${INSTALL_CHOICE:-y}
        if [ "$INSTALL_CHOICE" = "y" ] || [ "$INSTALL_CHOICE" = "Y" ]; then
            install_mariadb || exit 1
        else
            print_warning "Installation skipped. Please install MariaDB manually."
      exit 1
    fi
  else
        print_success "MariaDB is installed"
    fi

    # Check if running
    if ! check_mariadb_running; then
        print_info "Starting MariaDB..."
        systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null
        sleep 2
    fi

    # Setup MySQL command
    setup_mysql_cmd

    # Test connection
    if ! test_db_connection; then
        print_error "Cannot connect to MariaDB. Check root password in .env"
    exit 1
  fi
    print_success "Connected to MariaDB"

    # Tuning
    echo ""
    read -p "Would you like to tune MariaDB for your hardware? (y/n) [y]: " DO_TUNING
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

# Main Maintenance Menu
run_maintenance_mode() {
    # Check connection first
    setup_mysql_cmd
    if ! test_db_connection; then
        print_error "Cannot connect to MariaDB. Check root password in .env"
        exit 1
    fi

    while true; do
        show_status_dashboard

        echo "  ${WHITE}${BOLD}Maintenance Options${NC}"
        echo "  ${DIM}────────────────────────────────────────${NC}"
        echo "    1) Account Cleanup"
        echo "    2) Map Data Cleanup"
        echo "    3) Nest Management"
        echo "    4) General Database Maintenance"
        echo "    5) Database & User Management"
        echo "    6) Refresh Status"
        if [ "$SHELLDER_LAUNCHER" = "1" ]; then
            echo "    0) Return to Main Menu"
        else
            echo "    0) Exit"
        fi
        echo ""
        read -p "  Select option: " choice

        case $choice in
            1) account_cleanup_menu ;;
            2) map_data_cleanup_menu ;;
            3) nest_management_menu ;;
            4) general_maintenance_menu ;;
            5) db_user_management_menu ;;
            6) continue ;;
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
        draw_box_line "      AEGIS DATABASE SETUP & MAINTENANCE"
        draw_box_line ""
        draw_box_line "              By The Pokemod Group"
        draw_box_line "              https://pokemod.dev/"
        draw_box_bottom
        echo ""
        echo "  Select Mode:"
        echo ""
        echo "    1) Setup Mode"
        echo "       - Install/configure MariaDB"
        echo "       - Create databases and users"
        echo "       - Performance tuning"
        echo ""
        echo "    2) Maintenance Mode"
        echo "       - Status dashboard"
        echo "       - Account cleanup"
        echo "       - Data maintenance"
        echo "       - Database optimization"
        echo "       - Create missing DBs/users"
        echo "       - Fix permissions"
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
