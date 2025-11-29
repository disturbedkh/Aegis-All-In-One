#!/bin/bash

# Fletchling Setup Script for Aegis All-in-One
# This script configures Fletchling for Pokemon nest tracking with ReactMap

set -e

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

echo "=============================================="
echo "  Fletchling Setup - Pokemon Nest Tracking"
echo "  Aegis All-in-One by The Pokemod Group"
echo "  https://pokemod.dev/"
echo "=============================================="
echo ""

# Get the original user who called sudo (to fix file ownership later)
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    REAL_GROUP=$(id -gn "$SUDO_USER")
else
    REAL_USER="$USER"
    REAL_GROUP=$(id -gn)
fi

# Welcome message
print_info "This script will setup Fletchling to import Pokemon nests to ReactMap."
echo ""

# Check prerequisites
print_warning "Prerequisites:"
echo "  1. You MUST have created a project with geofences in Koji Admin"
echo "  2. Docker containers should be running (or will be started)"
echo "  3. The .env file must exist with proper configuration"
echo ""

read -p "Have you completed the prerequisites? (y/n): " PREREQ_CHECK
if [ "$PREREQ_CHECK" != "y" ] && [ "$PREREQ_CHECK" != "Y" ]; then
    print_error "Please complete the prerequisites first:"
    echo "  1. Start your stack: docker compose up -d"
    echo "  2. Access Koji at http://localhost:6004"
    echo "  3. Create a project with your scanning area geofences"
    echo "  4. Run this script again"
    exit 1
fi

# Check if running from correct directory
if [ ! -f "docker-compose.yaml" ]; then
    print_error "Please run this script from the Aegis-All-In-One directory"
    exit 1
fi

# Check if .env exists
if [ ! -f ".env" ]; then
    print_error ".env file not found. Have you run the initial setup script?"
    print_info "Run: sudo bash setup.sh"
    exit 1
fi

# Source .env
source .env

# Check for required environment variables
if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
    print_error "MYSQL_ROOT_PASSWORD not found in .env"
    exit 1
fi

if [ -z "$KOJI_SECRET" ]; then
    print_error "KOJI_SECRET not found in .env"
    exit 1
fi

print_success "Environment variables loaded"

# Check if fletchling.toml exists
CONFIG_FILE="./fletchling.toml"
if [ ! -f "$CONFIG_FILE" ]; then
    print_error "fletchling.toml not found in current directory"
    exit 1
fi

print_success "Found fletchling.toml configuration file"

# Prompt for Koji project name
echo ""
print_info "Enter your Koji project name (exactly as shown in Koji Admin)"
print_info "This is the project containing your scanning area geofences"
read -p "Koji project name: " KOJI_PROJECT

if [ -z "$KOJI_PROJECT" ]; then
    print_error "Koji project name is required"
    exit 1
fi

# Prompt for area name for OSM import
echo ""
print_info "Enter the area name for OSM park data import"
print_info "This should match one of your geofence areas in Koji"
read -p "Area name for OSM import: " AREA_NAME

if [ -z "$AREA_NAME" ]; then
    print_error "Area name is required for OSM import"
    exit 1
fi

# Backup original config
print_info "Creating backup of fletchling.toml..."
cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"

# Update fletchling.toml with Koji project name
print_info "Updating fletchling.toml with your Koji project..."

# Replace the placeholder in koji_url
if grep -q "YOUR-PROJECT-IN-KOJI-ADMIN-HERE" "$CONFIG_FILE"; then
    sed -i "s/YOUR-PROJECT-IN-KOJI-ADMIN-HERE/${KOJI_PROJECT}/g" "$CONFIG_FILE"
    print_success "Updated Koji project URL"
else
    # Check if already configured
    if grep -q "koji_url.*${KOJI_PROJECT}" "$CONFIG_FILE"; then
        print_warning "Koji project already configured in fletchling.toml"
    else
        print_warning "Could not find placeholder. You may need to manually update koji_url"
        print_info "Expected format: koji_url = \"http://koji:8080/api/v1/geofence/feature-collection/${KOJI_PROJECT}\""
    fi
fi

# Verify the config has proper environment variable references
print_info "Verifying configuration..."

# Check if config uses environment variables properly
if grep -q '\${MYSQL_ROOT_PASSWORD}' "$CONFIG_FILE"; then
    print_success "Database password configured to use environment variable"
else
    print_warning "Database password may need manual configuration"
fi

if grep -q '\${KOJI_SECRET}' "$CONFIG_FILE"; then
    print_success "Koji token configured to use environment variable"
else
    print_warning "Koji token may need manual configuration"
fi

# Enable fletchling in docker-compose if commented out
echo ""
print_info "Checking docker-compose.yaml for Fletchling service..."

if grep -q "^# fletchling:" docker-compose.yaml; then
    read -p "Fletchling is commented out in docker-compose.yaml. Enable it? (y/n) [y]: " ENABLE_FLETCHLING
    ENABLE_FLETCHLING=${ENABLE_FLETCHLING:-y}
    
    if [ "$ENABLE_FLETCHLING" = "y" ] || [ "$ENABLE_FLETCHLING" = "Y" ]; then
        print_info "Enabling Fletchling in docker-compose.yaml..."
        
        # Uncomment fletchling service (new format without leading space)
        sed -i 's/^# fletchling:/fletchling:/g' docker-compose.yaml
        sed -i 's/^  # image: ghcr.io\/unownhash\/fletchling:latest/  image: ghcr.io\/unownhash\/fletchling:latest/g' docker-compose.yaml
        sed -i 's/^  # container_name: fletchling/  container_name: fletchling/g' docker-compose.yaml
        sed -i 's/^  # restart: unless-stopped/  restart: unless-stopped/g' docker-compose.yaml
        sed -i 's/^  # volumes:/  volumes:/g' docker-compose.yaml
        sed -i 's/^    # - .\/fletchling.toml/    - .\/fletchling.toml/g' docker-compose.yaml
        sed -i 's/^    # - .\/fletchling:/    - .\/fletchling:/g' docker-compose.yaml
        sed -i 's/^    # - \/etc\/timezone/    - \/etc\/timezone/g' docker-compose.yaml
        sed -i 's/^    # - \/etc\/localtime/    - \/etc\/localtime/g' docker-compose.yaml
        sed -i 's/^  # ports:/  ports:/g' docker-compose.yaml
        sed -i 's/^    # - "9042:9042"/    - "9042:9042"/g' docker-compose.yaml
        sed -i 's/^  # healthcheck:/  healthcheck:/g' docker-compose.yaml
        sed -i 's/^    # test:/    test:/g' docker-compose.yaml
        sed -i 's/^    # interval:/    interval:/g' docker-compose.yaml
        sed -i 's/^    # timeout:/    timeout:/g' docker-compose.yaml
        sed -i 's/^    # retries:/    retries:/g' docker-compose.yaml
        sed -i 's/^    # start_period:/    start_period:/g' docker-compose.yaml
        
        # Uncomment fletchling-tools service
        sed -i 's/^# fletchling-tools:/fletchling-tools:/g' docker-compose.yaml
        sed -i 's/^  # command: .\/sleep/  command: .\/sleep/g' docker-compose.yaml
        
        print_success "Fletchling services enabled in docker-compose.yaml"
    fi
fi

# Start/restart containers
echo ""
read -p "Would you like to start/restart the Fletchling containers now? (y/n) [y]: " START_CONTAINERS
START_CONTAINERS=${START_CONTAINERS:-y}

if [ "$START_CONTAINERS" = "y" ] || [ "$START_CONTAINERS" = "Y" ]; then
    print_info "Starting Fletchling containers..."
    
    # Detect docker compose command
    if command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        COMPOSE_CMD="docker compose"
    fi
    
    $COMPOSE_CMD up -d fletchling fletchling-tools
    
    if [ $? -eq 0 ]; then
        print_success "Fletchling containers started"
        
        # Wait for containers to be ready
        print_info "Waiting for containers to initialize..."
        sleep 10
    else
        print_error "Failed to start containers. Check docker-compose.yaml for errors."
        exit 1
    fi
fi

# Run OSM importer
echo ""
print_info "Running OSM park data importer for area: $AREA_NAME"
print_warning "This may take a while depending on the area size..."

if [ -f "./docker-osm-importer.sh" ]; then
    chmod +x ./docker-osm-importer.sh
    ./docker-osm-importer.sh "$AREA_NAME"
    
    if [ $? -eq 0 ]; then
        print_success "OSM import completed successfully"
    else
        print_error "OSM import failed. Check the logs for details."
        print_info "You can retry manually: ./docker-osm-importer.sh '$AREA_NAME'"
    fi
else
    print_error "docker-osm-importer.sh not found"
    exit 1
fi

# Restore file ownership to the original user (not root)
print_info "Restoring file ownership..."
chown "$REAL_USER:$REAL_GROUP" "$CONFIG_FILE" 2>/dev/null || true
chown "$REAL_USER:$REAL_GROUP" "${CONFIG_FILE}.backup."* 2>/dev/null || true
chown "$REAL_USER:$REAL_GROUP" docker-compose.yaml 2>/dev/null || true
print_success "File ownership restored to $REAL_USER"

# Print summary
echo ""
echo "=============================================="
print_success "Fletchling Setup Complete!"
echo "=============================================="
echo ""
print_info "Configuration Summary:"
echo "  Koji Project:    $KOJI_PROJECT"
echo "  OSM Import Area: $AREA_NAME"
echo "  Config File:     $CONFIG_FILE"
echo ""
print_info "Next Steps:"
echo "  1. Configure Golbat to send webhooks to Fletchling"
echo "     Add to golbat_config.toml:"
echo "     [[webhooks]]"
echo "     url = \"http://fletchling:9042/webhook\""
echo "     types = [\"pokemon_iv\"]"
echo ""
echo "  2. Restart Golbat to apply webhook changes:"
echo "     docker compose restart golbat"
echo ""
echo "  3. Monitor Fletchling logs:"
echo "     docker compose logs -f fletchling"
echo ""
echo "  4. Access Fletchling status:"
echo "     http://localhost:9042/status"
echo ""
print_info "Useful Commands:"
echo "  View logs:       docker compose logs -f fletchling"
echo "  Restart:         docker compose restart fletchling"
echo "  Re-import OSM:   ./docker-osm-importer.sh '$AREA_NAME'"
echo ""
print_warning "Remember: Nest data takes time to accumulate. Check back after a few hours!"
