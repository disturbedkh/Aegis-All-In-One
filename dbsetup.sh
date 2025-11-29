#!/bin/bash

# =============================================================================
# Aegis All-in-One 2.0 - Database Setup & Tuning Script
# =============================================================================
# This script handles:
#   1. MariaDB installation (if needed)
#   2. System resource detection (RAM, CPU, Storage)
#   3. MariaDB performance tuning based on your hardware
#   4. Database creation
#   5. User creation
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "======================================"
echo "  Aegis All-in-One 2.0 - DB Setup"
echo "  By The Pokemod Group"
echo "  https://pokemod.dev/"
echo "======================================"
echo ""
echo "This script can:"
echo "  • Install MariaDB (if not installed)"
echo "  • Tune MariaDB for your hardware"
echo "  • Create required databases"
echo "  • Create database users"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  print_error "Please run this script as root (e.g., sudo bash dbsetup.sh)"
  exit 1
fi

# Check if .env exists
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
    export "$key=$value"
done < .env

# Check for MYSQL_ROOT_PASSWORD
if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
  print_error "MYSQL_ROOT_PASSWORD not found in .env."
  print_info "Please ensure it is set in .env (you may need to edit it manually if not generated)."
  exit 1
fi

# Check if MariaDB is installed
if ! command -v mysql &> /dev/null; then
  read -p "MariaDB is not installed. Do you want to install it now? (y/n) [y]: " INSTALL_CHOICE
  INSTALL_CHOICE=${INSTALL_CHOICE:-y}
  if [ "$INSTALL_CHOICE" = "y" ] || [ "$INSTALL_CHOICE" = "Y" ]; then
    print_info "Installing MariaDB..."
    apt update -y
    apt install mariadb-server -y
    # After fresh install, set root password using the one from .env
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD'; FLUSH PRIVILEGES;"
    if [ $? -eq 0 ]; then
      print_success "MariaDB installed and root password set successfully."
    else
      print_error "Error setting root password. Please check installation."
      exit 1
    fi
  else
    print_warning "Installation skipped. Please install MariaDB manually and rerun the script."
    exit 1
  fi
else
  print_success "MariaDB is already installed."
fi

# =============================================================================
# MariaDB Performance Tuning
# =============================================================================
echo ""
read -p "Would you like to tune MariaDB for your hardware? (y/n) [y]: " DO_TUNING
DO_TUNING=${DO_TUNING:-y}

if [ "$DO_TUNING" = "y" ] || [ "$DO_TUNING" = "Y" ]; then
    echo ""
    print_info "Detecting system resources..."
    echo ""

    # Detect RAM (in MB)
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

    # Calculate optimal MariaDB settings
    print_info "Calculating optimal MariaDB settings..."
    echo ""

    # Calculate InnoDB Buffer Pool Size (30% of RAM for shared server)
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

    # Calculate max connections (based on RAM)
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

    # Calculate log file size
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
            
            print_success "MariaDB settings optimized for your hardware!"
            print_warning "Restart MariaDB/Docker for changes to take effect."
        else
            print_warning "mariadb.cnf not found at $MARIADB_CNF - skipping optimization"
        fi
    else
        print_info "Skipping MariaDB optimization."
    fi
fi

echo ""

# =============================================================================
# Database Creation
# =============================================================================

# Prompt for root DB username
read -p "Enter root DB username (or press enter for 'root'): " ROOT_USER
if [ -z "$ROOT_USER" ]; then
  ROOT_USER="root"
fi

# Prompt for non-root DB user
read -p "Enter non-root DB username to create (or press enter to skip): " NON_ROOT_USER
if [ -z "$NON_ROOT_USER" ]; then
  print_info "Skipping non-root user creation."
else
  read -p "Enter password for $NON_ROOT_USER (or press enter for random): " NON_ROOT_PASS
  if [ -z "$NON_ROOT_PASS" ]; then
    NON_ROOT_PASS=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
    print_warning "Generated random password: $NON_ROOT_PASS"
    print_info "Note: Update your config files and .env with this user/password if different from existing DB_USER/DB_PASSWORD."
  fi
fi

echo ""
print_info "Creating databases..."

# Databases from configs
DBS=("dragonite" "golbat" "reactmap" "koji" "poracle")

# Build SQL commands
SQL=""
for db in "${DBS[@]}"; do
  SQL+="CREATE DATABASE IF NOT EXISTS \`$db\`; "
done

if [ -n "$NON_ROOT_USER" ]; then
  SQL+="CREATE USER IF NOT EXISTS '$NON_ROOT_USER'@'%' IDENTIFIED BY '$NON_ROOT_PASS'; "
  SQL+="GRANT ALL PRIVILEGES ON *.* TO '$NON_ROOT_USER'@'%' WITH GRANT OPTION; "
  SQL+="FLUSH PRIVILEGES; "
fi

# Execute SQL on local MariaDB
echo "$SQL" | mysql -u"$ROOT_USER" -p"$MYSQL_ROOT_PASSWORD" -h localhost

if [ $? -eq 0 ]; then
  echo ""
  print_success "Database setup complete!"
  print_success "Databases created: ${DBS[*]}"
  if [ -n "$NON_ROOT_USER" ]; then
    print_success "User '$NON_ROOT_USER' created with all privileges."
  fi
  echo ""
  print_info "Next: Run 'docker compose up -d --force-recreate --build' to start services."
else
  print_error "Error executing SQL commands."
  print_info "Check if MariaDB is running and credentials are correct."
fi
