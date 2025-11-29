#!/bin/bash

# =============================================================================
# Aegis All-in-One 2.0 - Initial Setup Script
# =============================================================================
# This script handles:
#   1. Detecting system resources (RAM, CPU, Storage)
#   2. Optimizing MariaDB configuration for your hardware
#   3. Copying default config files
#   4. Generating/setting secure passwords and tokens
#   5. Installing MariaDB (optional)
#   6. Creating required databases
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

echo ""
echo "======================================"
echo "  Aegis All-in-One 2.0 - Setup"
echo "  By The Pokemod Group"
echo "  https://pokemod.dev/"
echo "======================================"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  print_error "Please run this script as root (e.g., sudo bash setup.sh)"
  exit 1
fi

# Get the original user who called sudo (to fix file ownership later)
if [ -n "$SUDO_USER" ]; then
  REAL_USER="$SUDO_USER"
  REAL_GROUP=$(id -gn "$SUDO_USER")
else
  REAL_USER="$USER"
  REAL_GROUP=$(id -gn)
fi

# =============================================================================
# Step 1: Detect System Resources
# =============================================================================
echo "[1/6] Detecting system resources..."
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
# Step 2: Calculate Optimal MariaDB Settings
# =============================================================================
echo "[2/6] Calculating optimal MariaDB settings..."
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
        
        print_success "MariaDB settings optimized for your hardware!"
    else
        print_warning "mariadb.cnf not found at $MARIADB_CNF - skipping optimization"
    fi
else
    print_info "Skipping MariaDB optimization. Using default settings."
fi

echo ""

# =============================================================================
# Step 3: Copy default config files
# =============================================================================
echo "[3/6] Copying default config files..."

cp env-default .env
cp reactmap/local-default.json reactmap/local.json
cp unown/dragonite_config-default.toml unown/dragonite_config.toml
cp unown/golbat_config-default.toml unown/golbat_config.toml
cp unown/rotom_config-default.json unown/rotom_config.json

print_success "Config files copied."
echo ""

# =============================================================================
# Step 4: Generate/prompt for secrets and passwords
# =============================================================================
echo "[4/6] Configuring secrets and passwords..."
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

echo ""
print_info "Applying secrets to config files..."

# Replace defaults in config files
# IMPORTANT: Replace password BEFORE username since "dbuser" appears inside "SuperSecuredbuserPassword"

# DB password (must be done before DB user)
sed -i "s/SuperSecuredbuserPassword/${DB_PASSWORD}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# DB user
sed -i "s/dbuser/${DB_USER}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# MySQL root password
sed -i "s/V3ryS3cUr3MYSQL_ROOT_P4ssw0rd/${MYSQL_ROOT_PASSWORD}/g" .env

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

# Restore file ownership to the original user (not root)
chown "$REAL_USER:$REAL_GROUP" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json
chown "$REAL_USER:$REAL_GROUP" mysql_data/mariadb.cnf 2>/dev/null || true

print_success "Secrets applied to all config files."
echo ""

# =============================================================================
# Step 5: MariaDB installation (optional)
# =============================================================================
echo "[5/6] Database setup..."

if ! command -v mysql &> /dev/null; then
  read -p "      MariaDB not found. Install it now? (y/n): " INSTALL_CHOICE
  if [ "$INSTALL_CHOICE" = "y" ] || [ "$INSTALL_CHOICE" = "Y" ]; then
    print_info "Installing MariaDB..."
    apt update -y
    apt install mariadb-server -y
    # Set root password on fresh install
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD'; FLUSH PRIVILEGES;"
    if [ $? -eq 0 ]; then
      print_success "MariaDB installed and root password set."
    else
      print_error "Error setting root password. Please check installation."
      exit 1
    fi
  else
    print_info "Skipping MariaDB installation."
    print_info "You will need to set up databases manually or use Docker's MariaDB."
    SKIP_DB_SETUP=true
  fi
else
  print_success "MariaDB is already installed."
fi

# =============================================================================
# Step 6: Create databases
# =============================================================================
if [ "$SKIP_DB_SETUP" != "true" ]; then
  echo ""
  echo "[6/6] Creating databases..."

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
  echo "$SQL" | mysql -u"$ROOT_USER" -p"$MYSQL_ROOT_PASSWORD" -h localhost

  if [ $? -eq 0 ]; then
    print_success "Databases created: ${DBS[*]}"
    print_success "DB user '$DB_USER' created with full privileges."
  else
    print_error "Error creating databases. Check credentials and try again."
    exit 1
  fi
else
  echo ""
  echo "[6/6] Skipped database creation (MariaDB not installed locally)."
  print_info "Docker's MariaDB will create databases on first run."
fi

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
echo "  └── MariaDB buffer pool: ${BUFFER_POOL_SIZE}"
echo ""
echo "  Generated Credentials (save these!):"
echo "  ├── DB User: $DB_USER"
echo "  ├── DB Password: $DB_PASSWORD"
echo "  ├── MySQL Root Password: $MYSQL_ROOT_PASSWORD"
echo "  └── Rotom Auth Bearer: $ROTOM_AUTH_BEARER"
echo ""
echo "  Next steps:"
echo "  1. Review config files for any manual changes needed"
echo "  2. Run: docker compose up -d --force-recreate --build"
echo "  3. Access services at http://localhost:6001-6007"
echo ""
print_warning "IMPORTANT: Save the credentials above! They won't be shown again."
echo ""
