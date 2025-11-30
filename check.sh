#!/bin/bash

# =============================================================================
# Aegis All-in-One 2.0 - Configuration & Status Checker
# =============================================================================
# This script provides:
#   - Status dashboard showing system health at a glance
#   - Docker and Docker Compose status
#   - Container status monitoring
#   - Configuration validation
#   - Password/secret/token alignment checking
#   - File permission verification
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

# Counters
ERRORS=0
WARNINGS=0
PASSED=0

# Print functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_pass() { echo -e "${GREEN}[✓]${NC} $1"; ((PASSED++)); }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; ((WARNINGS++)); }
print_fail() { echo -e "${RED}[✗]${NC} $1"; ((ERRORS++)); }
print_check() { echo -e "${BLUE}[CHECK]${NC} $1"; }
print_header() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}\n"; }

# Box drawing
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

press_enter() {
    echo ""
    read -p "Press Enter to continue..."
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Extract value from TOML file
get_toml_value() {
    local file=$1
    local key=$2
    grep -E "^${key}\s*=" "$file" 2>/dev/null | sed 's/.*=\s*"\?\([^"]*\)"\?.*/\1/' | tr -d '"' | tr -d "'" | head -1
}

# Extract value from JSON file (excludes _explanation keys)
get_json_value() {
    local file=$1
    local key=$2
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | grep -v "\"_${key}" | head -1 | sed 's/.*:\s*"\([^"]*\)".*/\1/'
}

# Check if value is a placeholder
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

# Load .env file
load_env() {
    if [ -f ".env" ]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue
            [[ "$key" == "UID" ]] && continue
            [[ "$key" == "GID" ]] && continue
            value="${value%\"}"
            value="${value#\"}"
            export "$key=$value"
        done < .env
        return 0
    fi
    return 1
}

# Check if running from correct directory
check_directory() {
    if [ ! -f "docker-compose.yaml" ]; then
        print_fail "Please run this script from the Aegis-All-In-One directory"
        exit 1
    fi
}

# =============================================================================
# STATUS CHECKS
# =============================================================================

# Check Docker installation and status
check_docker_status() {
    local docker_installed=false
    local docker_running=false
    local compose_installed=false
    local compose_version=""
    local docker_version=""

    # Check Docker
    if command -v docker &> /dev/null; then
        docker_installed=true
        docker_version=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        
        if docker info &> /dev/null; then
            docker_running=true
        fi
    fi

    # Check Docker Compose
    if docker compose version &> /dev/null; then
        compose_installed=true
        compose_version=$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    elif command -v docker-compose &> /dev/null; then
        compose_installed=true
        compose_version=$(docker-compose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi

    echo -e "${WHITE}${BOLD}Docker Status${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    
    if $docker_installed; then
        echo -e "  Docker:          ${GREEN}Installed${NC} (v$docker_version)"
    else
        echo -e "  Docker:          ${RED}Not Installed${NC}"
    fi

    if $docker_running; then
        echo -e "  Docker Daemon:   ${GREEN}Running${NC}"
    else
        echo -e "  Docker Daemon:   ${RED}Not Running${NC}"
    fi

    if $compose_installed; then
        echo -e "  Docker Compose:  ${GREEN}Installed${NC} (v$compose_version)"
    else
        echo -e "  Docker Compose:  ${RED}Not Installed${NC}"
    fi

    # Check docker socket permissions
    if [ -S /var/run/docker.sock ]; then
        if [ -w /var/run/docker.sock ]; then
            echo -e "  Socket Access:   ${GREEN}Writable${NC}"
        else
            echo -e "  Socket Access:   ${YELLOW}No Permission${NC}"
        fi
    fi

    echo ""
    return 0
}

# Check user and group permissions
check_permissions() {
    echo -e "${WHITE}${BOLD}User & Permissions${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"

    local current_user=$(whoami)
    local current_uid=$(id -u)
    local current_gid=$(id -g)
    local in_docker_group=false

    echo -e "  Current User:    ${CYAN}$current_user${NC} (UID: $current_uid, GID: $current_gid)"

    # Check if in docker group
    if groups | grep -q docker; then
        in_docker_group=true
        echo -e "  Docker Group:    ${GREEN}Member${NC}"
    else
        echo -e "  Docker Group:    ${YELLOW}Not a Member${NC}"
    fi

    # Check .env UID/GID settings
    if [ -f ".env" ]; then
        local env_puid=$(grep "^PUID=" .env 2>/dev/null | cut -d= -f2)
        local env_pgid=$(grep "^PGID=" .env 2>/dev/null | cut -d= -f2)
        
        if [ -n "$env_puid" ]; then
            if [ "$env_puid" = "$current_uid" ]; then
                echo -e "  .env PUID:       ${GREEN}$env_puid${NC} (matches current user)"
            else
                echo -e "  .env PUID:       ${YELLOW}$env_puid${NC} (current: $current_uid)"
            fi
        fi
        if [ -n "$env_pgid" ]; then
            if [ "$env_pgid" = "$current_gid" ]; then
                echo -e "  .env PGID:       ${GREEN}$env_pgid${NC} (matches current group)"
            else
                echo -e "  .env PGID:       ${YELLOW}$env_pgid${NC} (current: $current_gid)"
            fi
        fi
    fi

    # Check file ownership of key files
    if [ -f ".env" ]; then
        local env_owner=$(stat -c '%U' .env 2>/dev/null || stat -f '%Su' .env 2>/dev/null)
        if [ "$env_owner" = "$current_user" ] || [ "$env_owner" = "root" ]; then
            echo -e "  .env Owner:      ${GREEN}$env_owner${NC}"
        else
            echo -e "  .env Owner:      ${YELLOW}$env_owner${NC} (may need: sudo chown $current_user .env)"
        fi
    fi

    # Check if running as root
    if [ "$EUID" -eq 0 ]; then
        echo -e "  Running as:      ${YELLOW}root${NC} (some checks may differ)"
    fi

    echo ""
}

# Check container status
check_containers() {
    echo -e "${WHITE}${BOLD}Container Status${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"

    if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
        echo -e "  ${RED}Docker not available${NC}"
        echo ""
        return 1
    fi

    local containers=("database" "golbat" "dragonite" "rotom" "reactmap" "koji" "admin" "grafana" "pma" "xilriws" "vmagent" "victoriametrics" "poracle" "fletchling")
    local running=0
    local stopped=0
    local missing=0

    printf "  ${DIM}%-18s %-12s %-20s${NC}\n" "CONTAINER" "STATUS" "HEALTH"
    
    for container in "${containers[@]}"; do
        local status=$(docker ps -a --filter "name=^${container}$" --format "{{.Status}}" 2>/dev/null | head -1)
        local health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "")
        
        if [ -n "$status" ]; then
            if [[ "$status" == *"Up"* ]]; then
                ((running++))
                local health_display=""
                if [ "$health" = "healthy" ]; then
                    health_display="${GREEN}healthy${NC}"
                elif [ "$health" = "unhealthy" ]; then
                    health_display="${RED}unhealthy${NC}"
                elif [ "$health" = "starting" ]; then
                    health_display="${YELLOW}starting${NC}"
                else
                    health_display="${DIM}-${NC}"
                fi
                printf "  %-18s ${GREEN}%-12s${NC} %-20b\n" "$container" "Running" "$health_display"
            else
                ((stopped++))
                printf "  %-18s ${RED}%-12s${NC} %-20s\n" "$container" "Stopped" "-"
            fi
        else
            ((missing++))
            printf "  %-18s ${DIM}%-12s${NC} %-20s\n" "$container" "Not Found" "-"
        fi
    done

    echo ""
    echo -e "  Summary: ${GREEN}$running running${NC}, ${RED}$stopped stopped${NC}, ${DIM}$missing not found${NC}"
    echo ""
}

# Check MariaDB status
check_mariadb() {
    echo -e "${WHITE}${BOLD}MariaDB Status${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"

    # Check if database container exists and is running
    local db_status=$(docker ps --filter "name=^database$" --format "{{.Status}}" 2>/dev/null)
    
    if [ -z "$db_status" ]; then
        echo -e "  Container:       ${RED}Not Running${NC}"
        echo ""
        return 1
    fi

    if [[ "$db_status" == *"Up"* ]]; then
        echo -e "  Container:       ${GREEN}Running${NC}"
    else
        echo -e "  Container:       ${RED}$db_status${NC}"
        echo ""
        return 1
    fi

    # Try to connect to MariaDB
    load_env
    local root_pass="${MYSQL_ROOT_PASSWORD:-}"
    
    if [ -n "$root_pass" ]; then
        local version=$(docker exec database mysql -u root -p"$root_pass" -e "SELECT VERSION();" -N 2>/dev/null | head -1)
        if [ -n "$version" ]; then
            echo -e "  Connection:      ${GREEN}Connected${NC}"
            echo -e "  Version:         ${CYAN}$version${NC}"
            
            # Check databases
            local dbs=$(docker exec database mysql -u root -p"$root_pass" -e "SHOW DATABASES;" -N 2>/dev/null)
            local expected=("golbat" "dragonite" "koji" "reactmap" "poracle")
            local found=0
            for db in "${expected[@]}"; do
                if echo "$dbs" | grep -q "^${db}$"; then
                    ((found++))
                fi
            done
            echo -e "  Databases:       ${GREEN}$found/${#expected[@]}${NC} configured"
        else
            echo -e "  Connection:      ${YELLOW}Auth Failed${NC}"
        fi
    else
        echo -e "  Connection:      ${YELLOW}No Password${NC}"
    fi

    echo ""
}

# Check configuration alignment
check_config_alignment() {
    echo -e "${WHITE}${BOLD}Configuration Alignment${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"

    load_env
    local issues=0

    # Database Password Check
    local env_db_pass="${MYSQL_PASSWORD:-}"
    local align_db="✓"
    
    if [ -f "unown/dragonite_config.toml" ]; then
        local dragonite_pass=$(get_toml_value "unown/dragonite_config.toml" "password")
        if [ "$dragonite_pass" != "$env_db_pass" ] && [ -n "$dragonite_pass" ]; then
            align_db="✗"
            ((issues++))
        fi
    fi
    if [ -f "unown/golbat_config.toml" ]; then
        local golbat_pass=$(get_toml_value "unown/golbat_config.toml" "password")
        if [ "$golbat_pass" != "$env_db_pass" ] && [ -n "$golbat_pass" ]; then
            align_db="✗"
            ((issues++))
        fi
    fi
    if [ -f "reactmap/local.json" ]; then
        local reactmap_pass=$(get_json_value "reactmap/local.json" "password")
        if [ "$reactmap_pass" != "$env_db_pass" ] && [ -n "$reactmap_pass" ]; then
            align_db="✗"
            ((issues++))
        fi
    fi

    if [ "$align_db" = "✓" ]; then
        echo -e "  DB Password:     ${GREEN}$align_db Aligned${NC}"
    else
        echo -e "  DB Password:     ${RED}$align_db Mismatch${NC}"
    fi

    # Koji Secret Check
    local env_koji="${KOJI_SECRET:-}"
    local align_koji="✓"
    
    if [ -f "unown/dragonite_config.toml" ]; then
        local dragonite_koji=$(get_toml_value "unown/dragonite_config.toml" "bearer_token")
        if [ "$dragonite_koji" != "$env_koji" ] && [ -n "$dragonite_koji" ]; then
            align_koji="✗"
            ((issues++))
        fi
    fi
    if [ -f "unown/golbat_config.toml" ]; then
        local golbat_koji=$(get_toml_value "unown/golbat_config.toml" "bearer_token")
        if [ "$golbat_koji" != "$env_koji" ] && [ -n "$golbat_koji" ] && [ "$golbat_koji" != '${KOJI_SECRET}' ]; then
            align_koji="✗"
            ((issues++))
        fi
    fi

    if [ "$align_koji" = "✓" ]; then
        echo -e "  Koji Secret:     ${GREEN}$align_koji Aligned${NC}"
    else
        echo -e "  Koji Secret:     ${RED}$align_koji Mismatch${NC}"
    fi

    # Golbat API Secret Check
    local env_golbat="${GOLBAT_API_SECRET:-}"
    local align_golbat="✓"
    
    if [ -f "unown/golbat_config.toml" ]; then
        local golbat_api=$(get_toml_value "unown/golbat_config.toml" "api_secret")
        if [ "$golbat_api" != "$env_golbat" ] && [ -n "$golbat_api" ]; then
            align_golbat="✗"
            ((issues++))
        fi
    fi
    if [ -f "unown/dragonite_config.toml" ]; then
        local dragonite_golbat=$(get_toml_value "unown/dragonite_config.toml" "golbat_api_secret")
        if [ "$dragonite_golbat" != "$env_golbat" ] && [ -n "$dragonite_golbat" ]; then
            align_golbat="✗"
            ((issues++))
        fi
    fi
    if [ -f "reactmap/local.json" ]; then
        local reactmap_golbat=$(get_json_value "reactmap/local.json" "secret")
        if [ "$reactmap_golbat" != "$env_golbat" ] && [ -n "$reactmap_golbat" ]; then
            align_golbat="✗"
            ((issues++))
        fi
    fi

    if [ "$align_golbat" = "✓" ]; then
        echo -e "  Golbat Secret:   ${GREEN}$align_golbat Aligned${NC}"
    else
        echo -e "  Golbat Secret:   ${RED}$align_golbat Mismatch${NC}"
    fi

    # Raw Bearer Check
    local align_raw="✓"
    if [ -f "unown/golbat_config.toml" ] && [ -f "unown/dragonite_config.toml" ]; then
        local golbat_raw=$(get_toml_value "unown/golbat_config.toml" "raw_bearer")
        local dragonite_raw=$(get_toml_value "unown/dragonite_config.toml" "golbat_raw_bearer")
        if [ "$golbat_raw" != "$dragonite_raw" ] && [ -n "$golbat_raw" ] && [ -n "$dragonite_raw" ]; then
            align_raw="✗"
            ((issues++))
        fi
    fi

    if [ "$align_raw" = "✓" ]; then
        echo -e "  Raw Bearer:      ${GREEN}$align_raw Aligned${NC}"
    else
        echo -e "  Raw Bearer:      ${RED}$align_raw Mismatch${NC}"
    fi

    # DB Username Check
    local env_user="${MYSQL_USER:-dbuser}"
    local align_user="✓"
    
    if [ -f "unown/dragonite_config.toml" ]; then
        local dragonite_user=$(get_toml_value "unown/dragonite_config.toml" "user")
        if [ "$dragonite_user" != "$env_user" ] && [ -n "$dragonite_user" ]; then
            align_user="✗"
            ((issues++))
        fi
    fi
    if [ -f "unown/golbat_config.toml" ]; then
        local golbat_user=$(get_toml_value "unown/golbat_config.toml" "user")
        if [ "$golbat_user" != "$env_user" ] && [ -n "$golbat_user" ]; then
            align_user="✗"
            ((issues++))
        fi
    fi

    if [ "$align_user" = "✓" ]; then
        echo -e "  DB Username:     ${GREEN}$align_user Aligned${NC}"
    else
        echo -e "  DB Username:     ${RED}$align_user Mismatch${NC}"
    fi

    echo ""
    if [ $issues -eq 0 ]; then
        echo -e "  ${GREEN}All configurations aligned!${NC}"
    else
        echo -e "  ${RED}$issues configuration issue(s) found${NC}"
    fi
    echo ""
}

# Check required files
check_files() {
    echo -e "${WHITE}${BOLD}Required Files${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"

    local core_files=(".env" "docker-compose.yaml" "init/01.sql")
    local config_files=(
        "unown/dragonite_config.toml"
        "unown/golbat_config.toml"
        "unown/rotom_config.json"
        "reactmap/local.json"
    )

    echo "  Core Files:"
    for file in "${core_files[@]}"; do
        if [ -f "$file" ]; then
            echo -e "    ${GREEN}✓${NC} $file"
        else
            echo -e "    ${RED}✗${NC} $file"
        fi
    done

    echo ""
    echo "  Config Files:"
    for file in "${config_files[@]}"; do
        if [ -f "$file" ]; then
            echo -e "    ${GREEN}✓${NC} $file"
        else
            local default="${file/-default/}"
            default="${default%.toml}-default.toml"
            if [[ "$file" == *.json ]]; then
                default="${file%.json}-default.json"
            fi
            if [ -f "$default" ]; then
                echo -e "    ${YELLOW}○${NC} $file (using default)"
            else
                echo -e "    ${RED}✗${NC} $file"
            fi
        fi
    done
    echo ""
}

# Check service endpoints
check_endpoints() {
    echo -e "${WHITE}${BOLD}Service Endpoints${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"

    local endpoints_ok=0
    local endpoints_fail=0

    # Check Dragonite -> Golbat
    if [ -f "unown/dragonite_config.toml" ]; then
        local golbat_ep=$(get_toml_value "unown/dragonite_config.toml" "golbat_endpoint")
        if [ "$golbat_ep" = "http://golbat:9001" ]; then
            echo -e "  Dragonite→Golbat:  ${GREEN}✓${NC}"
            ((endpoints_ok++))
        else
            echo -e "  Dragonite→Golbat:  ${RED}✗${NC} ($golbat_ep)"
            ((endpoints_fail++))
        fi

        local rotom_ep=$(get_toml_value "unown/dragonite_config.toml" "endpoint")
        if [[ "$rotom_ep" == *"rotom:7071"* ]]; then
            echo -e "  Dragonite→Rotom:   ${GREEN}✓${NC}"
            ((endpoints_ok++))
        else
            echo -e "  Dragonite→Rotom:   ${RED}✗${NC}"
            ((endpoints_fail++))
        fi

        local koji_url=$(get_toml_value "unown/dragonite_config.toml" "url")
        if [[ "$koji_url" == *"koji:8080"* ]]; then
            echo -e "  Dragonite→Koji:    ${GREEN}✓${NC}"
            ((endpoints_ok++))
        else
            echo -e "  Dragonite→Koji:    ${RED}✗${NC}"
            ((endpoints_fail++))
        fi
    fi

    # Check ReactMap endpoints
    if [ -f "reactmap/local.json" ]; then
        if grep -q '"http://golbat:9001"' reactmap/local.json 2>/dev/null; then
            echo -e "  ReactMap→Golbat:   ${GREEN}✓${NC}"
            ((endpoints_ok++))
        else
            echo -e "  ReactMap→Golbat:   ${RED}✗${NC}"
            ((endpoints_fail++))
        fi

        if grep -q '"host": "database"' reactmap/local.json 2>/dev/null; then
            echo -e "  ReactMap→Database: ${GREEN}✓${NC}"
            ((endpoints_ok++))
        else
            echo -e "  ReactMap→Database: ${RED}✗${NC}"
            ((endpoints_fail++))
        fi
    fi

    echo ""
    echo -e "  Summary: ${GREEN}$endpoints_ok correct${NC}, ${RED}$endpoints_fail incorrect${NC}"
    echo ""
}

# Check ports
check_ports() {
    echo -e "${WHITE}${BOLD}Port Status${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"

    local ports=(
        "6001:ReactMap"
        "6002:Dragonite"
        "6003:Rotom UI"
        "6004:Koji"
        "6005:phpMyAdmin"
        "6006:Grafana"
        "6007:Poracle"
        "7070:Devices"
    )

    printf "  ${DIM}%-8s %-15s %-15s${NC}\n" "PORT" "SERVICE" "STATUS"

    for port_info in "${ports[@]}"; do
        local port="${port_info%%:*}"
        local service="${port_info##*:}"
        local status="Available"
        local color="$DIM"

        if command -v ss &> /dev/null; then
            if ss -tuln 2>/dev/null | grep -q ":${port} "; then
                status="In Use"
                color="$GREEN"
            fi
        elif command -v netstat &> /dev/null; then
            if netstat -tuln 2>/dev/null | grep -q ":${port} "; then
                status="In Use"
                color="$GREEN"
            fi
        fi

        printf "  %-8s %-15s ${color}%-15s${NC}\n" "$port" "$service" "$status"
    done
    echo ""
}

# Check for placeholder values
check_placeholders() {
    echo -e "${WHITE}${BOLD}Placeholder Check${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"

    local files=(
        ".env"
        "unown/dragonite_config.toml"
        "unown/golbat_config.toml"
        "unown/rotom_config.json"
        "reactmap/local.json"
    )

    local total_placeholders=0

    for file in "${files[@]}"; do
        if [ -f "$file" ]; then
            local count=0
            if [[ "$file" == *.toml ]]; then
                count=$(grep -c -E "(CHANGE_ME|YOUR_|SuperSecure|V3ryS3cUr3)" "$file" 2>/dev/null | grep -v "^[0-9]*:[[:space:]]*#" || echo "0")
            elif [[ "$file" == *.json ]]; then
                count=$(grep -c -E "(CHANGE_ME|YOUR_|SuperSecure|V3ryS3cUr3)" "$file" 2>/dev/null | grep -v "_explanation\|_description" || echo "0")
            else
                count=$(grep -c -E "(CHANGE_ME|YOUR_|SuperSecure|V3ryS3cUr3)" "$file" 2>/dev/null || echo "0")
            fi

            if [ "$count" -gt 0 ] 2>/dev/null; then
                echo -e "  ${YELLOW}!${NC} $file: $count placeholder(s)"
                ((total_placeholders += count))
            else
                echo -e "  ${GREEN}✓${NC} $file: clean"
            fi
        fi
    done

    echo ""
    if [ $total_placeholders -gt 0 ]; then
        echo -e "  ${YELLOW}$total_placeholders total placeholder(s) need updating${NC}"
    else
        echo -e "  ${GREEN}All placeholders have been replaced${NC}"
    fi
    echo ""
}

# =============================================================================
# STATUS DASHBOARD
# =============================================================================

show_status_dashboard() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              AEGIS SYSTEM STATUS DASHBOARD"
    draw_box_bottom
    echo ""

    check_docker_status
    check_permissions
    check_mariadb
    check_containers
    check_config_alignment
}

# =============================================================================
# DETAILED CHECKS
# =============================================================================

run_full_check() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              FULL CONFIGURATION CHECK"
    draw_box_bottom

    # Reset counters
    ERRORS=0
    WARNINGS=0
    PASSED=0

    print_header "Required Files"
    check_files_detailed

    print_header "Environment Variables"
    check_env_detailed

    print_header "Database Configuration"
    check_db_config_detailed

    print_header "API Secrets"
    check_secrets_detailed

    print_header "Service Endpoints"
    check_endpoints_detailed

    print_header "Docker Status"
    check_docker_detailed

    print_header "Port Configuration"
    check_ports_detailed

    print_header "Placeholder Values"
    check_placeholders_detailed

    # Summary
    print_header "Summary"
    echo ""
    echo -e "  ${GREEN}Passed:${NC}   $PASSED"
    echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
    echo -e "  ${RED}Errors:${NC}   $ERRORS"
    echo ""

    if [ $ERRORS -gt 0 ]; then
        print_fail "Configuration has $ERRORS error(s) that need to be fixed!"
        echo ""
        echo "  Common fixes:"
        echo "    1. Run setup.sh to generate proper .env file"
        echo "    2. Copy *-default.* files to active config names"
        echo "    3. Update passwords in config files to match .env"
        echo "    4. Run: docker compose up -d --force-recreate"
    elif [ $WARNINGS -gt 0 ]; then
        print_warn "Configuration has $WARNINGS warning(s) - review recommended"
    else
        print_pass "All configuration checks passed!"
    fi
}

# Detailed check functions
check_files_detailed() {
    local core_files=(".env" "docker-compose.yaml" "init/01.sql")
    local config_pairs=(
        "unown/dragonite_config.toml:unown/dragonite_config-default.toml"
        "unown/golbat_config.toml:unown/golbat_config-default.toml"
        "unown/rotom_config.json:unown/rotom_config-default.json"
        "reactmap/local.json:reactmap/local-default.json"
    )

    for file in "${core_files[@]}"; do
        if [ -f "$file" ]; then
            print_pass "Found: $file"
        else
            print_fail "Missing: $file"
        fi
    done

    echo ""
    print_info "Config files:"
    for pair in "${config_pairs[@]}"; do
        local active="${pair%%:*}"
        local default="${pair##*:}"
        
        if [ -f "$active" ]; then
            print_pass "Found: $active"
        elif [ -f "$default" ]; then
            print_warn "Using default: $default"
        else
            print_warn "Missing: $active"
        fi
    done
}

check_env_detailed() {
    if [ ! -f ".env" ]; then
        print_fail ".env file not found! Run setup.sh first."
        return
    fi

    load_env

    local vars=("MYSQL_ROOT_PASSWORD" "MYSQL_PASSWORD" "MYSQL_USER" "KOJI_SECRET" "DRAGONITE_PASSWORD" "DRAGONITE_API_SECRET" "GOLBAT_API_SECRET" "GOLBAT_RAW_SECRET")

    for var in "${vars[@]}"; do
        if [ -z "${!var}" ]; then
            print_fail "$var is not set"
        elif is_placeholder "${!var}"; then
            print_warn "$var has placeholder value"
        else
            print_pass "$var is set"
        fi
    done
}

check_db_config_detailed() {
    load_env
    local env_pass="${MYSQL_PASSWORD:-}"
    local env_user="${MYSQL_USER:-dbuser}"

    if [ -f "unown/dragonite_config.toml" ]; then
        local pass=$(get_toml_value "unown/dragonite_config.toml" "password")
        local user=$(get_toml_value "unown/dragonite_config.toml" "user")
        
        if [ "$pass" = "$env_pass" ]; then
            print_pass "Dragonite DB password matches .env"
        elif [ -n "$pass" ]; then
            print_fail "Dragonite DB password MISMATCH"
        fi
        
        if [ "$user" = "$env_user" ]; then
            print_pass "Dragonite DB user matches .env"
        elif [ -n "$user" ]; then
            print_warn "Dragonite using different DB user: $user"
        fi
    fi

    if [ -f "unown/golbat_config.toml" ]; then
        local pass=$(get_toml_value "unown/golbat_config.toml" "password")
        if [ "$pass" = "$env_pass" ]; then
            print_pass "Golbat DB password matches .env"
        elif [ -n "$pass" ]; then
            print_fail "Golbat DB password MISMATCH"
        fi
    fi

    if [ -f "reactmap/local.json" ]; then
        local pass=$(get_json_value "reactmap/local.json" "password")
        if [ "$pass" = "$env_pass" ]; then
            print_pass "ReactMap DB password matches .env"
        elif [ -n "$pass" ]; then
            print_fail "ReactMap DB password MISMATCH"
        fi
    fi
}

check_secrets_detailed() {
    load_env

    # Koji Secret
    local env_koji="${KOJI_SECRET:-}"
    if [ -f "unown/dragonite_config.toml" ]; then
        local val=$(get_toml_value "unown/dragonite_config.toml" "bearer_token")
        if [ "$val" = "$env_koji" ]; then
            print_pass "Dragonite Koji secret matches"
        elif [ -n "$val" ]; then
            print_fail "Dragonite Koji secret MISMATCH"
        fi
    fi

    # Golbat API
    local env_golbat="${GOLBAT_API_SECRET:-}"
    if [ -f "unown/golbat_config.toml" ]; then
        local val=$(get_toml_value "unown/golbat_config.toml" "api_secret")
        if [ "$val" = "$env_golbat" ]; then
            print_pass "Golbat API secret matches"
        elif [ -n "$val" ]; then
            print_fail "Golbat API secret MISMATCH"
        fi
    fi

    # Raw Bearer
    if [ -f "unown/golbat_config.toml" ] && [ -f "unown/dragonite_config.toml" ]; then
        local golbat_raw=$(get_toml_value "unown/golbat_config.toml" "raw_bearer")
        local dragonite_raw=$(get_toml_value "unown/dragonite_config.toml" "golbat_raw_bearer")
        if [ "$golbat_raw" = "$dragonite_raw" ]; then
            print_pass "Raw bearer tokens match"
        elif [ -n "$golbat_raw" ] && [ -n "$dragonite_raw" ]; then
            print_fail "Raw bearer tokens MISMATCH"
        fi
    fi
}

check_endpoints_detailed() {
    if [ -f "unown/dragonite_config.toml" ]; then
        local golbat_ep=$(get_toml_value "unown/dragonite_config.toml" "golbat_endpoint")
        if [ "$golbat_ep" = "http://golbat:9001" ]; then
            print_pass "Dragonite->Golbat endpoint correct"
        else
            print_warn "Dragonite->Golbat: $golbat_ep"
        fi

        local rotom_ep=$(get_toml_value "unown/dragonite_config.toml" "endpoint")
        if [[ "$rotom_ep" == *"rotom:7071"* ]]; then
            print_pass "Dragonite->Rotom endpoint correct"
        else
            print_warn "Dragonite->Rotom: $rotom_ep"
        fi
    fi

    if [ -f "reactmap/local.json" ]; then
        if grep -q '"http://golbat:9001"' reactmap/local.json; then
            print_pass "ReactMap->Golbat endpoint correct"
        else
            print_warn "ReactMap->Golbat may be misconfigured"
        fi

        if grep -q '"host": "database"' reactmap/local.json; then
            print_pass "ReactMap->Database host correct"
        else
            print_warn "ReactMap->Database may be misconfigured"
        fi
    fi
}

check_docker_detailed() {
    if ! command -v docker &> /dev/null; then
        print_fail "Docker is not installed"
        return
    fi
    print_pass "Docker is installed"

    if docker info &> /dev/null; then
        print_pass "Docker daemon is running"
    else
        print_fail "Docker daemon is not running"
        return
    fi

    if docker compose version &> /dev/null; then
        print_pass "Docker Compose is available"
    else
        print_warn "Docker Compose plugin not found"
    fi

    echo ""
    print_info "Container Status:"
    local containers=("database" "golbat" "dragonite" "rotom" "reactmap" "koji" "admin" "grafana" "pma" "xilriws")
    
    for container in "${containers[@]}"; do
        local status=$(docker ps --filter "name=^${container}$" --format "{{.Status}}" 2>/dev/null)
        if [ -n "$status" ] && [[ "$status" == *"Up"* ]]; then
            print_pass "$container: Running"
        elif [ -n "$status" ]; then
            print_warn "$container: $status"
        else
            print_info "$container: not running"
        fi
    done
}

check_ports_detailed() {
    local ports=("6001:ReactMap" "6002:Dragonite" "6003:Rotom" "6004:Koji" "6005:phpMyAdmin" "6006:Grafana" "7070:Devices")

    for port_info in "${ports[@]}"; do
        local port="${port_info%%:*}"
        local service="${port_info##*:}"

        if command -v ss &> /dev/null; then
            if ss -tuln | grep -q ":${port} "; then
                print_pass "Port $port ($service) is in use"
            else
                print_info "Port $port ($service) is available"
            fi
        fi
    done
}

check_placeholders_detailed() {
    local files=("unown/dragonite_config.toml" "unown/golbat_config.toml" "unown/rotom_config.json" "reactmap/local.json")
    local found_any=false

    for file in "${files[@]}"; do
        if [ -f "$file" ]; then
            local matches=""
            if [[ "$file" == *.toml ]]; then
                matches=$(grep -n -E "(CHANGE_ME|YOUR_|SuperSecure|V3ryS3cUr3)" "$file" 2>/dev/null | grep -v "^[0-9]*:[[:space:]]*#" || true)
            else
                matches=$(grep -n -E "(CHANGE_ME|YOUR_|SuperSecure|V3ryS3cUr3)" "$file" 2>/dev/null | grep -v "_explanation\|_description" || true)
            fi

            if [ -n "$matches" ]; then
                print_warn "Placeholders in $file:"
                echo "$matches" | head -3 | while read line; do
                    echo "         $line"
                done
                found_any=true
            fi
        fi
    done

    if [ "$found_any" = false ]; then
        print_pass "No placeholder values found"
    fi
}

# =============================================================================
# MENU SYSTEM
# =============================================================================

show_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "         AEGIS CONFIGURATION CHECKER"
        draw_box_line ""
        draw_box_line "              By The Pokemod Group"
        draw_box_line "              https://pokemod.dev/"
        draw_box_bottom
        echo ""
        echo -e "  ${WHITE}${BOLD}Options${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        echo ""
        echo "    1) Status Dashboard"
        echo "       Quick overview of system health"
        echo ""
        echo "    2) Full Configuration Check"
        echo "       Detailed validation of all settings"
        echo ""
        echo "    3) Docker & Container Status"
        echo "       Check Docker and container health"
        echo ""
        echo "    4) Configuration Alignment"
        echo "       Verify passwords/secrets match"
        echo ""
        echo "    5) File & Endpoint Check"
        echo "       Verify files and service endpoints"
        echo ""
        echo "    6) Port Status"
        echo "       Check which ports are in use"
        echo ""
        echo "    0) Exit"
        echo ""
        read -p "  Select option [0-6]: " choice

        case $choice in
            1)
                show_status_dashboard
                press_enter
                ;;
            2)
                run_full_check
                press_enter
                ;;
            3)
                clear
                echo ""
                draw_box_top
                draw_box_line "              DOCKER STATUS"
                draw_box_bottom
                echo ""
                check_docker_status
                check_containers
                press_enter
                ;;
            4)
                clear
                echo ""
                draw_box_top
                draw_box_line "              CONFIGURATION ALIGNMENT"
                draw_box_bottom
                echo ""
                check_config_alignment
                check_placeholders
                press_enter
                ;;
            5)
                clear
                echo ""
                draw_box_top
                draw_box_line "              FILES & ENDPOINTS"
                draw_box_bottom
                echo ""
                check_files
                check_endpoints
                press_enter
                ;;
            6)
                clear
                echo ""
                draw_box_top
                draw_box_line "              PORT STATUS"
                draw_box_bottom
                echo ""
                check_ports
                press_enter
                ;;
            0)
                echo ""
                echo -e "  ${GREEN}Goodbye!${NC}"
                echo ""
                exit 0
                ;;
            *)
                echo ""
                echo -e "  ${RED}Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    check_directory

    # Check for command line arguments
    case "${1:-}" in
        --dashboard|-d)
            show_status_dashboard
            ;;
        --full|-f)
            run_full_check
            ;;
        --quick|-q)
            # Quick non-interactive check
            echo ""
            echo "Aegis Quick Check"
            echo "================"
            ERRORS=0
            WARNINGS=0
            PASSED=0
            
            load_env
            check_files_detailed
            check_env_detailed
            check_docker_detailed
            
            echo ""
            echo "Results: $PASSED passed, $WARNINGS warnings, $ERRORS errors"
            exit $ERRORS
            ;;
        --help|-h)
            echo ""
            echo "Aegis Configuration Checker"
            echo ""
            echo "Usage: $0 [option]"
            echo ""
            echo "Options:"
            echo "  (none)      Interactive menu"
            echo "  -d          Status dashboard"
            echo "  -f          Full configuration check"
            echo "  -q          Quick check (non-interactive)"
            echo "  -h          This help message"
            echo ""
            exit 0
            ;;
        *)
            show_menu
            ;;
    esac
}

main "$@"
