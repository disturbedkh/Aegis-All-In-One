#!/bin/bash

# Aegis All-in-One Configuration Checker
# This script validates that all environment variables, config files,
# and docker-compose settings are consistent and properly configured

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Counters
ERRORS=0
WARNINGS=0
PASSED=0

# Print functions
print_header() { echo -e "\n${CYAN}=== $1 ===${NC}\n"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASSED++)); }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; ((WARNINGS++)); }
print_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((ERRORS++)); }
print_check() { echo -e "${BLUE}[CHECK]${NC} $1"; }

# Helper function to extract value from TOML
get_toml_value() {
    local file=$1
    local key=$2
    grep -E "^${key}\s*=" "$file" 2>/dev/null | sed 's/.*=\s*"\?\([^"]*\)"\?.*/\1/' | tr -d '"' | tr -d "'"
}

# Helper function to extract value from JSON
get_json_value() {
    local file=$1
    local key=$2
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | head -1 | sed 's/.*:\s*"\([^"]*\)".*/\1/'
}

# Helper function to check if value contains placeholder
is_placeholder() {
    local value=$1
    if [[ "$value" == *"CHANGE_ME"* ]] || \
       [[ "$value" == *"YOUR_"* ]] || \
       [[ "$value" == *"SuperSecure"* ]] || \
       [[ "$value" == *"V3ryS3cUr3"* ]] || \
       [[ "$value" == *"placeholder"* ]] || \
       [[ "$value" == *"example"* ]]; then
        return 0
    fi
    return 1
}

echo ""
echo "=============================================="
echo "  Aegis All-in-One Configuration Checker"
echo "  By The Pokemod Group"
echo "  https://pokemod.dev/"
echo "=============================================="
echo ""
echo "This script checks for configuration mismatches"
echo "and common setup issues."
echo ""

# Check if running from correct directory
if [ ! -f "docker-compose.yaml" ]; then
    print_fail "Please run this script from the Aegis-All-In-One directory"
    exit 1
fi

#######################################
# Check 1: Required Files Exist
#######################################
print_header "Checking Required Files"

# Core files
REQUIRED_FILES=(
    ".env"
    "docker-compose.yaml"
    "init/01.sql"
)

# Config files
CONFIG_FILES=(
    "unown/dragonite_config.toml:unown/dragonite_config-default.toml"
    "unown/golbat_config.toml:unown/golbat_config-default.toml"
    "unown/rotom_config.json:unown/rotom_config-default.json"
    "reactmap/local.json:reactmap/local-default.json"
    "fletchling.toml:fletchling.toml"
    "Poracle/config/local.json:Poracle/config/local.json"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        print_pass "Found: $file"
    else
        print_fail "Missing: $file"
    fi
done

echo ""
print_info "Checking config files (active:default)..."

for pair in "${CONFIG_FILES[@]}"; do
    active="${pair%%:*}"
    default="${pair##*:}"
    
    if [ -f "$active" ]; then
        print_pass "Found: $active"
    elif [ -f "$default" ]; then
        print_warn "Using default: $default (copy to $active for customization)"
    else
        print_warn "Missing: $active (and no default found)"
    fi
done

#######################################
# Check 2: Environment Variables
#######################################
print_header "Checking Environment Variables"

if [ ! -f ".env" ]; then
    print_fail ".env file not found! Run setup.sh first."
else
    # Source .env (skip UID/GID which are readonly bash variables)
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        [[ "$key" == "UID" ]] && continue
        [[ "$key" == "GID" ]] && continue
        export "$key=$value"
    done < .env
    
    # Required env variables
    ENV_VARS=(
        "MYSQL_ROOT_PASSWORD"
        "MYSQL_PASSWORD"
        "KOJI_SECRET"
        "DRAGONITE_PASSWORD"
        "DRAGONITE_API_SECRET"
        "GOLBAT_API_SECRET"
    )
    
    for var in "${ENV_VARS[@]}"; do
        if [ -z "${!var}" ]; then
            print_fail "$var is not set in .env"
        elif is_placeholder "${!var}"; then
            print_warn "$var still has placeholder value - change it!"
        else
            print_pass "$var is set"
        fi
    done
    
    # Optional but recommended
    if [ -z "$UID" ] || [ -z "$GID" ]; then
        print_warn "UID/GID not set (will use defaults)"
    fi
fi

#######################################
# Check 3: Database Configuration
#######################################
print_header "Checking Database Configuration Consistency"

# Get password from .env
ENV_DB_PASS="${MYSQL_PASSWORD:-}"
ENV_ROOT_PASS="${MYSQL_ROOT_PASSWORD:-}"

# Check Dragonite config
if [ -f "unown/dragonite_config.toml" ]; then
    DRAGONITE_DB_PASS=$(get_toml_value "unown/dragonite_config.toml" "password")
    DRAGONITE_DB_USER=$(get_toml_value "unown/dragonite_config.toml" "user")
    
    if [ "$DRAGONITE_DB_PASS" = "$ENV_DB_PASS" ]; then
        print_pass "Dragonite DB password matches .env"
    elif [ -n "$DRAGONITE_DB_PASS" ]; then
        print_fail "Dragonite DB password MISMATCH with .env"
        print_info "  dragonite_config.toml: $DRAGONITE_DB_PASS"
        print_info "  .env MYSQL_PASSWORD: $ENV_DB_PASS"
    fi
    
    if [ "$DRAGONITE_DB_USER" = "dbuser" ]; then
        print_pass "Dragonite using correct DB user (dbuser)"
    elif [ -n "$DRAGONITE_DB_USER" ]; then
        print_warn "Dragonite using non-standard DB user: $DRAGONITE_DB_USER"
    fi
fi

# Check Golbat config
if [ -f "unown/golbat_config.toml" ]; then
    GOLBAT_DB_PASS=$(get_toml_value "unown/golbat_config.toml" "password")
    GOLBAT_DB_USER=$(get_toml_value "unown/golbat_config.toml" "user")
    
    if [ "$GOLBAT_DB_PASS" = "$ENV_DB_PASS" ]; then
        print_pass "Golbat DB password matches .env"
    elif [ -n "$GOLBAT_DB_PASS" ]; then
        print_fail "Golbat DB password MISMATCH with .env"
        print_info "  golbat_config.toml: $GOLBAT_DB_PASS"
        print_info "  .env MYSQL_PASSWORD: $ENV_DB_PASS"
    fi
fi

# Check ReactMap config
if [ -f "reactmap/local.json" ]; then
    REACTMAP_DB_PASS=$(get_json_value "reactmap/local.json" "password")
    
    if [ "$REACTMAP_DB_PASS" = "$ENV_DB_PASS" ]; then
        print_pass "ReactMap DB password matches .env"
    elif [ -n "$REACTMAP_DB_PASS" ]; then
        print_fail "ReactMap DB password MISMATCH with .env"
        print_info "  local.json: $REACTMAP_DB_PASS"
        print_info "  .env MYSQL_PASSWORD: $ENV_DB_PASS"
    fi
fi

# Check Poracle config
if [ -f "Poracle/config/local.json" ]; then
    PORACLE_DB_PASS=$(get_json_value "Poracle/config/local.json" "password")
    
    if [ "$PORACLE_DB_PASS" = "$ENV_DB_PASS" ]; then
        print_pass "Poracle DB password matches .env"
    elif [ "$PORACLE_DB_PASS" = "CHANGE_ME" ]; then
        print_fail "Poracle DB password not configured (still CHANGE_ME)"
    elif [ -n "$PORACLE_DB_PASS" ]; then
        print_fail "Poracle DB password MISMATCH with .env"
        print_info "  local.json: $PORACLE_DB_PASS"
        print_info "  .env MYSQL_PASSWORD: $ENV_DB_PASS"
    fi
fi

# Check Fletchling config
if [ -f "fletchling.toml" ]; then
    FLETCHLING_DB_PASS=$(get_toml_value "fletchling.toml" "password")
    
    # Fletchling uses root password by default
    if [ "$FLETCHLING_DB_PASS" = '${MYSQL_ROOT_PASSWORD}' ]; then
        print_pass "Fletchling using environment variable for password"
    elif [ "$FLETCHLING_DB_PASS" = "$ENV_ROOT_PASS" ]; then
        print_pass "Fletchling DB password matches .env MYSQL_ROOT_PASSWORD"
    elif [ -n "$FLETCHLING_DB_PASS" ] && [ "$FLETCHLING_DB_PASS" != '${MYSQL_ROOT_PASSWORD}' ]; then
        print_warn "Fletchling has hardcoded password (should use \${MYSQL_ROOT_PASSWORD})"
    fi
fi

#######################################
# Check 4: API Secrets Consistency
#######################################
print_header "Checking API Secrets Consistency"

# Koji Secret
ENV_KOJI_SECRET="${KOJI_SECRET:-}"

if [ -f "unown/dragonite_config.toml" ]; then
    DRAGONITE_KOJI=$(get_toml_value "unown/dragonite_config.toml" "bearer_token")
    if [ "$DRAGONITE_KOJI" = "$ENV_KOJI_SECRET" ]; then
        print_pass "Dragonite Koji secret matches .env"
    elif [ -n "$DRAGONITE_KOJI" ]; then
        print_fail "Dragonite Koji secret MISMATCH"
    fi
fi

if [ -f "unown/golbat_config.toml" ]; then
    GOLBAT_KOJI=$(get_toml_value "unown/golbat_config.toml" "bearer_token")
    if [ "$GOLBAT_KOJI" = "$ENV_KOJI_SECRET" ]; then
        print_pass "Golbat Koji secret matches .env"
    elif [ "$GOLBAT_KOJI" = '${KOJI_SECRET}' ]; then
        print_pass "Golbat using environment variable for Koji secret"
    elif [ -n "$GOLBAT_KOJI" ]; then
        print_fail "Golbat Koji secret MISMATCH"
    fi
fi

if [ -f "reactmap/local.json" ]; then
    REACTMAP_KOJI=$(get_json_value "reactmap/local.json" "bearerToken")
    if [ "$REACTMAP_KOJI" = "$ENV_KOJI_SECRET" ]; then
        print_pass "ReactMap Koji secret matches .env"
    elif [ -n "$REACTMAP_KOJI" ]; then
        print_fail "ReactMap Koji secret MISMATCH"
    fi
fi

# Golbat API Secret
ENV_GOLBAT_SECRET="${GOLBAT_API_SECRET:-}"

if [ -f "unown/golbat_config.toml" ]; then
    GOLBAT_API=$(get_toml_value "unown/golbat_config.toml" "api_secret")
    if [ "$GOLBAT_API" = "$ENV_GOLBAT_SECRET" ]; then
        print_pass "Golbat API secret matches .env"
    elif [ -n "$GOLBAT_API" ]; then
        print_fail "Golbat API secret MISMATCH with .env"
    fi
fi

if [ -f "unown/dragonite_config.toml" ]; then
    DRAGONITE_GOLBAT=$(get_toml_value "unown/dragonite_config.toml" "golbat_api_secret")
    if [ "$DRAGONITE_GOLBAT" = "$ENV_GOLBAT_SECRET" ]; then
        print_pass "Dragonite->Golbat API secret matches .env"
    elif [ -n "$DRAGONITE_GOLBAT" ]; then
        print_fail "Dragonite->Golbat API secret MISMATCH"
    fi
fi

if [ -f "reactmap/local.json" ]; then
    REACTMAP_GOLBAT=$(get_json_value "reactmap/local.json" "secret")
    if [ "$REACTMAP_GOLBAT" = "$ENV_GOLBAT_SECRET" ]; then
        print_pass "ReactMap->Golbat API secret matches .env"
    elif [ -n "$REACTMAP_GOLBAT" ]; then
        print_fail "ReactMap->Golbat API secret MISMATCH"
    fi
fi

# Golbat Raw Bearer (internal between dragonite and golbat)
if [ -f "unown/golbat_config.toml" ] && [ -f "unown/dragonite_config.toml" ]; then
    GOLBAT_RAW=$(get_toml_value "unown/golbat_config.toml" "raw_bearer")
    DRAGONITE_RAW=$(get_toml_value "unown/dragonite_config.toml" "golbat_raw_bearer")
    
    if [ "$GOLBAT_RAW" = "$DRAGONITE_RAW" ]; then
        print_pass "Golbat raw_bearer matches Dragonite golbat_raw_bearer"
    elif [ -n "$GOLBAT_RAW" ] && [ -n "$DRAGONITE_RAW" ]; then
        print_fail "Golbat raw_bearer MISMATCH with Dragonite"
        print_info "  golbat_config.toml raw_bearer: $GOLBAT_RAW"
        print_info "  dragonite_config.toml golbat_raw_bearer: $DRAGONITE_RAW"
    fi
fi

#######################################
# Check 5: Service Endpoints
#######################################
print_header "Checking Service Endpoint Configuration"

# Check Dragonite -> Golbat endpoint
if [ -f "unown/dragonite_config.toml" ]; then
    GOLBAT_ENDPOINT=$(get_toml_value "unown/dragonite_config.toml" "golbat_endpoint")
    if [ "$GOLBAT_ENDPOINT" = "http://golbat:9001" ]; then
        print_pass "Dragonite->Golbat endpoint correct"
    elif [ -n "$GOLBAT_ENDPOINT" ]; then
        print_warn "Dragonite->Golbat endpoint: $GOLBAT_ENDPOINT (expected http://golbat:9001)"
    fi
    
    ROTOM_ENDPOINT=$(get_toml_value "unown/dragonite_config.toml" "endpoint")
    if [[ "$ROTOM_ENDPOINT" == *"rotom:7071"* ]]; then
        print_pass "Dragonite->Rotom endpoint correct"
    elif [ -n "$ROTOM_ENDPOINT" ]; then
        print_warn "Dragonite->Rotom endpoint: $ROTOM_ENDPOINT"
    fi
    
    KOJI_URL=$(get_toml_value "unown/dragonite_config.toml" "url")
    if [[ "$KOJI_URL" == *"koji:8080"* ]]; then
        print_pass "Dragonite->Koji URL correct"
    elif [ -n "$KOJI_URL" ]; then
        print_warn "Dragonite->Koji URL: $KOJI_URL"
    fi
fi

# Check ReactMap -> services
if [ -f "reactmap/local.json" ]; then
    if grep -q '"http://golbat:9001"' reactmap/local.json; then
        print_pass "ReactMap->Golbat endpoint correct"
    else
        print_warn "ReactMap->Golbat endpoint may be misconfigured"
    fi
    
    if grep -q '"http://dragonite:7272' reactmap/local.json; then
        print_pass "ReactMap->Dragonite endpoint correct"
    else
        print_warn "ReactMap->Dragonite endpoint may be misconfigured"
    fi
    
    if grep -q '"host": "database"' reactmap/local.json; then
        print_pass "ReactMap->Database host correct"
    else
        print_warn "ReactMap->Database host may be misconfigured"
    fi
fi

#######################################
# Check 6: Docker Status
#######################################
print_header "Checking Docker Status"

if ! command -v docker &> /dev/null; then
    print_fail "Docker is not installed"
else
    print_pass "Docker is installed"
    
    if docker info &> /dev/null; then
        print_pass "Docker daemon is running"
        
        # Check if containers are running
        echo ""
        print_info "Container Status:"
        
        CONTAINERS=("database" "golbat" "dragonite" "rotom" "reactmap" "koji" "admin" "grafana" "pma" "poracle")
        
        for container in "${CONTAINERS[@]}"; do
            status=$(docker ps --filter "name=^${container}$" --format "{{.Status}}" 2>/dev/null)
            if [ -n "$status" ]; then
                if [[ "$status" == *"Up"* ]]; then
                    print_pass "$container: $status"
                else
                    print_warn "$container: $status"
                fi
            else
                print_info "$container: not running"
            fi
        done
    else
        print_fail "Docker daemon is not running or no permission"
    fi
fi

#######################################
# Check 7: Port Availability
#######################################
print_header "Checking Port Configuration"

PORTS=(
    "6001:ReactMap"
    "6002:Dragonite Admin"
    "6003:Rotom UI"
    "6004:Koji"
    "6005:phpMyAdmin"
    "6006:Grafana"
    "6007:Poracle"
    "7070:Rotom Devices"
)

for port_info in "${PORTS[@]}"; do
    port="${port_info%%:*}"
    service="${port_info##*:}"
    
    if command -v ss &> /dev/null; then
        if ss -tuln | grep -q ":${port} "; then
            print_pass "Port $port ($service) is in use"
        else
            print_info "Port $port ($service) is available"
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tuln | grep -q ":${port} "; then
            print_pass "Port $port ($service) is in use"
        else
            print_info "Port $port ($service) is available"
        fi
    fi
done

#######################################
# Check 8: Init SQL Database List
#######################################
print_header "Checking Database Initialization"

if [ -f "init/01.sql" ]; then
    EXPECTED_DBS=("golbat" "dragonite" "koji" "reactmap" "poracle")
    
    for db in "${EXPECTED_DBS[@]}"; do
        if grep -q "CREATE DATABASE.*\`${db}\`" init/01.sql; then
            print_pass "Database '$db' in init/01.sql"
        else
            print_warn "Database '$db' NOT in init/01.sql"
        fi
    done
fi

#######################################
# Check 9: Placeholder Values
#######################################
print_header "Checking for Placeholder Values"

print_info "Scanning config files for placeholder values..."

# Check each config file for common placeholders
check_placeholders() {
    local file=$1
    local found=0
    
    if [ -f "$file" ]; then
        if grep -qE "(CHANGE_ME|YOUR_|SuperSecure|V3ryS3cUr3|placeholder|example\.com)" "$file"; then
            print_warn "Placeholders found in $file:"
            grep -n -E "(CHANGE_ME|YOUR_|SuperSecure|V3ryS3cUr3|placeholder|example\.com)" "$file" | head -5 | while read line; do
                echo "         $line"
            done
            found=1
        fi
    fi
    return $found
}

FILES_TO_CHECK=(
    "unown/dragonite_config.toml"
    "unown/golbat_config.toml"
    "unown/rotom_config.json"
    "reactmap/local.json"
    "Poracle/config/local.json"
    "fletchling.toml"
)

placeholder_count=0
for file in "${FILES_TO_CHECK[@]}"; do
    if check_placeholders "$file"; then
        ((placeholder_count++))
    fi
done

if [ $placeholder_count -eq 0 ]; then
    print_pass "No obvious placeholder values found"
fi

#######################################
# Check 10: Koji Project Configuration
#######################################
print_header "Checking Koji Project References"

# Look for Koji project references
if [ -f "unown/golbat_config.toml" ]; then
    GOLBAT_KOJI_URL=$(grep "koji_url" unown/golbat_config.toml 2>/dev/null | head -1)
    if [ -n "$GOLBAT_KOJI_URL" ]; then
        if [[ "$GOLBAT_KOJI_URL" == *"Mapping"* ]]; then
            print_info "Golbat Koji project: Mapping (default)"
        else
            project=$(echo "$GOLBAT_KOJI_URL" | sed 's/.*feature-collection\/\([^"]*\).*/\1/')
            print_info "Golbat Koji project: $project"
        fi
    fi
fi

if [ -f "reactmap/local.json" ]; then
    REACTMAP_KOJI_URL=$(grep "geoJsonFileName" reactmap/local.json 2>/dev/null)
    if [ -n "$REACTMAP_KOJI_URL" ]; then
        if [[ "$REACTMAP_KOJI_URL" == *"Reactmap"* ]]; then
            print_info "ReactMap Koji project: Reactmap (default)"
        else
            project=$(echo "$REACTMAP_KOJI_URL" | sed 's/.*feature-collection\/\([^"]*\).*/\1/')
            print_info "ReactMap Koji project: $project"
        fi
    fi
fi

if [ -f "fletchling.toml" ]; then
    FLETCHLING_KOJI=$(grep "koji_url" fletchling.toml 2>/dev/null | head -1)
    if [[ "$FLETCHLING_KOJI" == *"YOUR-PROJECT"* ]]; then
        print_warn "Fletchling Koji project not configured"
    elif [ -n "$FLETCHLING_KOJI" ]; then
        project=$(echo "$FLETCHLING_KOJI" | sed 's/.*feature-collection\/\([^"]*\).*/\1/')
        print_info "Fletchling Koji project: $project"
    fi
fi

#######################################
# Summary
#######################################
print_header "Configuration Check Summary"

echo ""
echo -e "  ${GREEN}Passed:${NC}   $PASSED"
echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
echo -e "  ${RED}Errors:${NC}   $ERRORS"
echo ""

if [ $ERRORS -gt 0 ]; then
    print_fail "Configuration has $ERRORS error(s) that need to be fixed!"
    echo ""
    echo "Common fixes:"
    echo "  1. Run setup.sh to generate proper .env file"
    echo "  2. Copy *-default.* files to active config names"
    echo "  3. Update passwords in config files to match .env"
    echo "  4. Run: docker compose up -d --force-recreate"
    exit 1
elif [ $WARNINGS -gt 0 ]; then
    print_warn "Configuration has $WARNINGS warning(s) - review recommended"
    echo ""
    echo "Your setup may work but consider reviewing warnings above."
    exit 0
else
    print_pass "All configuration checks passed!"
    echo ""
    echo "Your Aegis setup appears to be properly configured."
    exit 0
fi

