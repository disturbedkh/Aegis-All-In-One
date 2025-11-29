#!/bin/bash

# =============================================================================
# Aegis All-in-One 2.0 - Initial Setup Script
# =============================================================================
# This script handles:
#   1. Checking/installing Docker and Docker Compose
#   2. Checking/installing Google Chrome (specific version for compatibility)
#   3. Detecting system resources (RAM, CPU, Storage)
#   4. Optimizing MariaDB configuration for your hardware
#   5. Copying default config files
#   6. Generating/setting secure passwords and tokens
#   7. Installing MariaDB (optional)
#   8. Creating required databases
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

# Track if user needs to re-login for docker group
NEEDS_RELOGIN=false

# Required Chrome version for compatibility with scanning tools
REQUIRED_CHROME_VERSION="125.0.6422.141"
CHROME_DEB_URL="https://github.com/NDViet/google-chrome-stable/releases/download/125.0.6422.141-1/google-chrome-stable_125.0.6422.141-1_amd64.deb"

# =============================================================================
# Step 1: Check/Install Docker and Docker Compose
# =============================================================================
echo "[1/8] Checking Docker installation..."
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

# Add user to docker group if needed
if [ "$DOCKER_INSTALLED" = true ] && [ "$DOCKER_ACCESSIBLE" = false ] && [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    echo ""
    read -p "  Add user '$REAL_USER' to docker group? (y/n) [y]: " ADD_TO_GROUP
    ADD_TO_GROUP=${ADD_TO_GROUP:-y}
    
    if [ "$ADD_TO_GROUP" = "y" ] || [ "$ADD_TO_GROUP" = "Y" ]; then
        if add_user_to_docker_group "$REAL_USER"; then
            DOCKER_ACCESSIBLE=true
            NEEDS_RELOGIN=true
            print_warning "User '$REAL_USER' needs to log out and back in for group changes to take effect."
        fi
    else
        print_warning "User '$REAL_USER' will need to use 'sudo' for Docker commands."
    fi
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

# =============================================================================
# Step 2: Check/Install Google Chrome (Specific Version)
# =============================================================================
echo "[2/8] Checking Google Chrome installation..."
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
# Step 3: Detect System Resources
# =============================================================================
echo "[3/8] Detecting system resources..."
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
# Step 4: Calculate Optimal MariaDB Settings
# =============================================================================
echo "[4/8] Calculating optimal MariaDB settings..."
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
# Step 5: Copy default config files
# =============================================================================
echo "[5/8] Copying default config files..."

cp env-default .env
cp reactmap/local-default.json reactmap/local.json
cp unown/dragonite_config-default.toml unown/dragonite_config.toml
cp unown/golbat_config-default.toml unown/golbat_config.toml
cp unown/rotom_config-default.json unown/rotom_config.json

print_success "Config files copied."
echo ""

# =============================================================================
# Step 6: Generate/prompt for secrets and passwords
# =============================================================================
echo "[6/8] Configuring secrets and passwords..."
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
# Step 7: MariaDB installation (optional)
# =============================================================================
echo "[7/8] Database setup..."

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
# Step 8: Create databases
# =============================================================================
if [ "$SKIP_DB_SETUP" != "true" ]; then
  echo ""
  echo "[8/8] Creating databases..."

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
  echo "[8/8] Skipped database creation (using Docker's MariaDB)."
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
