#!/bin/bash

# =============================================================================
# Aegis All-in-One 2.0 - Docker Log Manager & Analyzer
# =============================================================================
# This script provides:
#   - Real-time service status dashboard
#   - Log size monitoring and analysis
#   - Error categorization and counting
#   - Detailed service-level error breakdown
#   - Error viewing with log navigation
#   - Event searching (device disconnects, etc.)
#   - Log maintenance (clear, rotate)
#   - Docker configuration management
# =============================================================================

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

# Services to monitor
SERVICES=("database" "golbat" "dragonite" "rotom" "reactmap" "koji" "admin" "grafana" "pma" "xilriws" "vmagent" "victoriametrics" "poracle" "fletchling")

# Error patterns for categorization
declare -A ERROR_PATTERNS
ERROR_PATTERNS=(
    ["account"]="account|login|auth|credential|banned|invalid.*account|auth_banned|suspended"
    ["database"]="database|mysql|mariadb|sql|connection refused.*3306|deadlock|timeout.*db|SQLSTATE"
    ["connection"]="connection|disconnect|refused|timeout|ECONNREFUSED|ETIMEDOUT|socket|websocket"
    ["memory"]="out of memory|OOM|memory.*exceeded|heap|allocation failed"
    ["permission"]="permission|denied|forbidden|unauthorized|access denied"
    ["config"]="config|configuration|missing.*key|invalid.*value|parse error"
    ["network"]="network|DNS|resolve|unreachable|no route"
    ["api"]="api|endpoint|request failed|status code|HTTP.*[45][0-9][0-9]"
    ["device"]="device|worker|phone|pokemon.*go|pgPokemon|mitm"
    ["critical"]="fatal|panic|critical|emergency|FATAL|PANIC"
)

# Exclusion patterns - these are NOT errors even if they match error keywords
# These are success/info messages that contain words like "database" or "connection"
EXCLUSION_PATTERNS=(
    # Info/Warning symbol prefixes (these are log level indicators, not errors)
    # ℹ = info, ⚠ = warning (not error)
    "ℹ"
    "⚠"
    # Success/Info messages with "database" keyword
    "database version:"
    "Current database version"
    "Migration completed.*database"
    "Loaded.*from database"
    "proxies from database"
    "database version: [0-9]"
    "database migrated"
    "database migrations"
    "Determining database types"
    # Success/Info messages with "connection" keyword
    "connection established"
    "connected successfully"
    "connection.*ready"
    "websocket.*connected"
    "new connection from"
    "accepted connection"
    "Bound .* to .* connection"
    "to [0-9]+ connection"
    "for [0-9]+ connections"
    # General success patterns that should be excluded
    "successfully"
    "completed"
    "started"
    "ready for connections"
    "listening on"
    "Starting.*[0-9]+\.[0-9]+\.[0-9]+"
    "auth provider.*is enabled"
    "auth provider.*is disabled"
    "Server is now listening"
    "was not initialized"
    "Loaded areas"
    "Loading.*URL"
    "Caching http"
    "Cached http"
    "cache loaded"
    "initialized"
    "new version available"
    # ReactMap specific info prefixes
    "\[API\]"
    "\[STATS\]"
    "\[UPDATE\]"
    "\[AREAS\]"
    "\[CACHE\]"
    "\[POKEMON\]"
    "\[POKEMON_HISTORY\]"
    "\[DEVICES\]"
    "\[NESTS\]"
    "\[SESSIONS\]"
    "\[WEATHER\]"
    "\[CONFIG\]"
    "\[MASTERFILE\]"
    "\[EVENT\]"
    "\[SCANNER\]"
    "\[GEOCODER\]"
    "\[BACKUP\]"
    "\[CLIENTS\]"
    "\[WEBHOOK\]"
    "\[HISTORICAL\]"
    "\[INVASION\]"
    "\[LURE\]"
    "\[POKESTOP\]"
    "\[GYM\]"
    "\[RAID\]"
    "\[ROUTE\]"
    "\[SPAWNPOINT\]"
    "\[QUEST\]"
    "\[S2CELL\]"
    "\[PORTAL\]"
    # Node.js startup
    "^\\\$ node"
    # Info-level log prefixes (these lines are informational, not errors)
    "^INFO "
    "| I |"
    "\[INFO\]"
    "\[DB\]"
    "\[AUTH\]"
    "\[ReactMap\]"
    # Log level indicators at start of line
    "^[0-9].*\| I \|"
    "^[0-9].*INFO"
    # Grafana log format (level=info, level=warn are not errors)
    "level=info"
    "level=warn"
    "level=debug"
    # Grafana specific success messages
    "Migration successfully"
    "Executing migration"
    "All modules healthy"
    "HTTP Server Listen"
    "Applying new configuration"
    "Using.*store"
    "Setting up remote"
    "successfully executed"
    # Golbat/Dragonite info patterns
    "^\[Pokemon\]"
    "^pokemon\]"
    "Started background worker"
    "Prometheus init"
    "Starting.*Public"
    "APICHECK.*is OK"
    "Loaded [0-9]+ proxies"
    # Koji patterns
    "Listening on"
    "Connected to"
    # VictoriaMetrics/vmagent info patterns (tab-separated format)
    "	info	"
    "	debug	"
    "starting vmagent"
    "started vmagent"
    "started server at"
    "reading scrape configs"
    "starting service discovery"
    "added targets:"
    "initialized client"
    "limiting caches"
    "opened fast queue"
    "build version:"
    "command-line flags"
    "pprof handlers"
    # Note: vmagent "warn" about cannot scrape are NOT excluded - they're real issues
    # but will be marked as [STARTUP] if within startup window
)

# Startup window in seconds - errors within this window after container start are likely transient
STARTUP_WINDOW_SECONDS=120

# Get the original user who called sudo (to prevent files being locked to root)
# Check if REAL_USER was passed from aegis.sh (preferred), otherwise use SUDO_USER
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    # REAL_USER was passed from aegis.sh - use it
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

# Set up trap to restore ownership on exit
cleanup_on_exit() {
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        chown "$REAL_USER:$REAL_GROUP" *.sh *.yaml *.yml *.md 2>/dev/null || true
        chown -R "$REAL_USER:$REAL_GROUP" unown 2>/dev/null || true
    fi
}
trap cleanup_on_exit EXIT

# Print functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

# Return to main menu function
return_to_main() {
    if [ "$AEGIS_LAUNCHER" = "1" ]; then
        echo ""
        echo -e "${CYAN}Returning to Aegis Control Panel...${NC}"
        sleep 1
    fi
    exit 0
}

# Box drawing
draw_box_top() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
}
draw_box_bottom() {
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
}
draw_box_divider() {
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════════════╣${NC}"
}
draw_box_line() {
    printf "${CYAN}║${NC} %-74s ${CYAN}║${NC}\n" "$1"
}

press_enter() {
    echo ""
    read -p "Press Enter to continue..."
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed"
        exit 1
    fi
    if ! docker info &> /dev/null; then
        print_error "Docker daemon is not running or no permission"
        exit 1
    fi
}

# Get container status
get_container_status() {
    local container=$1
    local status=$(docker ps -a --filter "name=^${container}$" --format "{{.Status}}" 2>/dev/null | head -1)
    if [ -z "$status" ]; then
        echo "not_found"
    elif [[ "$status" == *"Up"* ]]; then
        echo "running"
    else
        echo "stopped"
    fi
}

# Get log size for a container
get_log_size() {
    local container=$1
    local log_path=$(docker inspect --format='{{.LogPath}}' "$container" 2>/dev/null)
    if [ -n "$log_path" ] && [ -f "$log_path" ]; then
        local size=$(stat -c%s "$log_path" 2>/dev/null || stat -f%z "$log_path" 2>/dev/null)
        echo "${size:-0}"
    else
        echo "0"
    fi
}

# Format bytes to human readable
format_bytes() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(echo "scale=1; $bytes / 1073741824" | bc)G"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(echo "scale=1; $bytes / 1048576" | bc)M"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(echo "scale=1; $bytes / 1024" | bc)K"
    else
        echo "${bytes}B"
    fi
}

# Count errors in log by pattern (with exclusion filtering)
count_errors_by_pattern() {
    local container=$1
    local pattern=$2
    local count=0
    
    # Build exclusion grep pattern
    local exclusion_pattern=""
    for excl in "${EXCLUSION_PATTERNS[@]}"; do
        if [ -z "$exclusion_pattern" ]; then
            exclusion_pattern="$excl"
        else
            exclusion_pattern="$exclusion_pattern|$excl"
        fi
    done
    
    # Count lines matching pattern but NOT matching exclusions
    count=$(docker logs "$container" 2>&1 | grep -iE "$pattern" 2>/dev/null | grep -ivE "$exclusion_pattern" 2>/dev/null | wc -l || echo "0")
    echo "$count"
}

# Count total errors in log (with exclusion filtering)
count_total_errors() {
    local container=$1
    local count=0
    
    # Build exclusion grep pattern
    local exclusion_pattern=""
    for excl in "${EXCLUSION_PATTERNS[@]}"; do
        if [ -z "$exclusion_pattern" ]; then
            exclusion_pattern="$excl"
        else
            exclusion_pattern="$exclusion_pattern|$excl"
        fi
    done
    
    # Count lines matching error patterns but NOT matching exclusions
    # BUT always include lines with error="/failed=" even if they match exclusions
    local temp_file=$(mktemp)
    docker logs "$container" 2>&1 | grep -iE "error|err\]|fatal|panic|critical|failed|exception|ERRO|FATL" 2>/dev/null > "$temp_file" || true
    
    while IFS= read -r line; do
        # Always count if it has actual error indicators like error="..."
        if echo "$line" | grep -qiE 'error="|err="|failed="|exception="|panic="|fatal="'; then
            ((count++))
        # Otherwise check exclusions
        elif ! echo "$line" | grep -qiE "$exclusion_pattern"; then
            ((count++))
        fi
    done < "$temp_file"
    
    rm -f "$temp_file"
    echo "$count"
}

# Count warnings in log (with exclusion filtering)
count_warnings() {
    local container=$1
    local count=0
    
    # Build exclusion grep pattern
    local exclusion_pattern=""
    for excl in "${EXCLUSION_PATTERNS[@]}"; do
        if [ -z "$exclusion_pattern" ]; then
            exclusion_pattern="$excl"
        else
            exclusion_pattern="$exclusion_pattern|$excl"
        fi
    done
    
    # Count lines matching warning patterns but NOT matching exclusions
    local temp_file=$(mktemp)
    docker logs "$container" 2>&1 | grep -iE "warn|warning" 2>/dev/null > "$temp_file" || true
    
    while IFS= read -r line; do
        # Skip if matches exclusion patterns
        if ! echo "$line" | grep -qiE "$exclusion_pattern"; then
            ((count++))
        fi
    done < "$temp_file"
    
    rm -f "$temp_file"
    echo "$count"
}

# Get last N lines of log
get_log_tail() {
    local container=$1
    local lines=${2:-50}
    docker logs --tail "$lines" "$container" 2>&1
}

# Get log lines matching pattern
get_log_pattern() {
    local container=$1
    local pattern=$2
    local context=${3:-2}
    docker logs "$container" 2>&1 | grep -iE -B"$context" -A"$context" "$pattern" 2>/dev/null
}

# Check if a line should be excluded (it's actually a success/info message)
is_excluded_line() {
    local line=$1
    
    # NEVER exclude lines that contain actual error indicators
    # These patterns indicate real errors even if logged at info/warn level
    if echo "$line" | grep -qiE 'error="|err="|failed="|exception="|panic="|fatal="'; then
        return 1  # Not excluded - this is a real error
    fi
    
    for exclusion in "${EXCLUSION_PATTERNS[@]}"; do
        if echo "$line" | grep -qiE "$exclusion"; then
            return 0  # Should be excluded
        fi
    done
    return 1  # Not excluded
}

# Check if a line is an actual error (has error keywords AND is not excluded)
is_actual_error() {
    local line=$1
    # Must have an error keyword
    if ! echo "$line" | grep -qiE "error|err\]|failed|fatal|panic|critical|exception|ERRO|FATL|WARN"; then
        return 1  # Not an error
    fi
    # Must not be excluded
    if is_excluded_line "$line"; then
        return 1  # Excluded
    fi
    return 0  # Is an actual error
}

# Get container start time in epoch seconds
get_container_start_time() {
    local container=$1
    local start_time=$(docker inspect --format='{{.State.StartedAt}}' "$container" 2>/dev/null)
    if [ -n "$start_time" ]; then
        # Convert to epoch seconds
        date -d "$start_time" +%s 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Get current container uptime in seconds
get_container_uptime_seconds() {
    local container=$1
    local start_epoch=$(get_container_start_time "$container")
    if [ "$start_epoch" -gt 0 ] 2>/dev/null; then
        local now_epoch=$(date +%s)
        echo $((now_epoch - start_epoch))
    else
        echo "0"
    fi
}

# Check if a timestamp is within the startup window
# Returns 0 if within startup window, 1 if not
is_startup_error() {
    local log_timestamp=$1
    local container_start_epoch=$2
    
    if [ "$container_start_epoch" -eq 0 ] 2>/dev/null; then
        return 1  # Can't determine, assume not startup
    fi
    
    # Try to extract timestamp from log line and convert to epoch
    # Common formats: "2025-11-30 12:00:57" or "12:00:57" or ISO format
    local log_epoch=0
    
    # Try full datetime format first
    if echo "$log_timestamp" | grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}"; then
        local datetime=$(echo "$log_timestamp" | grep -oE "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}" | head -1)
        if [ -n "$datetime" ]; then
            log_epoch=$(date -d "$datetime" +%s 2>/dev/null || echo "0")
        fi
    fi
    
    if [ "$log_epoch" -gt 0 ] 2>/dev/null; then
        local diff=$((log_epoch - container_start_epoch))
        if [ "$diff" -ge 0 ] && [ "$diff" -le "$STARTUP_WINDOW_SECONDS" ]; then
            return 0  # Within startup window
        fi
    fi
    
    return 1  # Not within startup window
}

# Format startup annotation
get_startup_annotation() {
    local log_line=$1
    local container=$2
    local container_start=$(get_container_start_time "$container")
    
    if is_startup_error "$log_line" "$container_start"; then
        echo "[STARTUP]"
    else
        echo ""
    fi
}

# Count ACTUAL errors (excluding false positives)
count_actual_errors() {
    local container=$1
    local pattern=$2
    local count=0
    
    while IFS= read -r line; do
        if is_actual_error "$line"; then
            if [ -n "$pattern" ]; then
                if echo "$line" | grep -qiE "$pattern"; then
                    ((count++))
                fi
            else
                ((count++))
            fi
        fi
    done < <(docker logs "$container" 2>&1)
    
    echo "$count"
}

# =============================================================================
# STATUS DASHBOARD
# =============================================================================

show_main_dashboard() {
    clear
    echo ""
    draw_box_top
    draw_box_line "                    AEGIS DOCKER LOG MANAGER"
    draw_box_bottom
    echo ""

    echo -e "${WHITE}${BOLD}Service Status & Log Overview${NC}"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    printf "  ${DIM}%-18s %-10s %-10s %-10s %-10s %-10s${NC}\n" "SERVICE" "STATUS" "LOG SIZE" "ERRORS" "WARNINGS" "CRITICAL"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"

    local idx=1
    for service in "${SERVICES[@]}"; do
        local status=$(get_container_status "$service")
        local status_color=""
        local status_text=""
        
        case $status in
            "running")
                status_color="${GREEN}"
                status_text="Running"
                ;;
            "stopped")
                status_color="${RED}"
                status_text="Stopped"
                ;;
            *)
                status_color="${DIM}"
                status_text="N/A"
                ;;
        esac

        local log_size="--"
        local errors="--"
        local warnings="--"
        local critical="--"

        if [ "$status" = "running" ] || [ "$status" = "stopped" ]; then
            local size_bytes=$(get_log_size "$service")
            log_size=$(format_bytes "$size_bytes")
            
            if [ "$status" = "running" ]; then
                errors=$(count_total_errors "$service")
                warnings=$(count_warnings "$service")
                critical=$(count_errors_by_pattern "$service" "fatal|panic|critical|emergency")
            fi
        fi

        # Color code errors
        local error_color="${GREEN}"
        [ "${errors:-0}" -gt 0 ] 2>/dev/null && error_color="${YELLOW}"
        [ "${errors:-0}" -gt 100 ] 2>/dev/null && error_color="${RED}"

        local crit_color="${GREEN}"
        [ "${critical:-0}" -gt 0 ] 2>/dev/null && crit_color="${RED}"

        printf "  ${DIM}%2d)${NC} %-14s ${status_color}%-10s${NC} %-10s ${error_color}%-10s${NC} %-10s ${crit_color}%-10s${NC}\n" \
            "$idx" "$service" "$status_text" "$log_size" "$errors" "$warnings" "$critical"
        
        ((idx++))
    done

    echo ""
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    
    # Quick summary
    local running=0
    local stopped=0
    for service in "${SERVICES[@]}"; do
        local s=$(get_container_status "$service")
        [ "$s" = "running" ] && ((running++))
        [ "$s" = "stopped" ] && ((stopped++))
    done
    echo -e "  Summary: ${GREEN}$running running${NC}, ${RED}$stopped stopped${NC}"
    echo ""
}

# =============================================================================
# DETAILED SERVICE STATUS
# =============================================================================

show_service_detail() {
    local service=$1
    
    clear
    echo ""
    draw_box_top
    draw_box_line "                 SERVICE DETAIL: $service"
    draw_box_bottom
    echo ""

    local status=$(get_container_status "$service")
    
    # Basic info
    echo -e "${WHITE}${BOLD}Container Information${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    
    case $status in
        "running")
            echo -e "  Status:          ${GREEN}Running${NC}"
            local uptime=$(docker ps --filter "name=^${service}$" --format "{{.Status}}" 2>/dev/null)
            echo -e "  Uptime:          ${CYAN}$uptime${NC}"
            ;;
        "stopped")
            echo -e "  Status:          ${RED}Stopped${NC}"
            ;;
        *)
            echo -e "  Status:          ${DIM}Not Found${NC}"
            press_enter
            return
            ;;
    esac

    # Log info
    local size_bytes=$(get_log_size "$service")
    local log_size=$(format_bytes "$size_bytes")
    echo -e "  Log Size:        ${CYAN}$log_size${NC}"
    
    local log_path=$(docker inspect --format='{{.LogPath}}' "$service" 2>/dev/null)
    echo -e "  Log Path:        ${DIM}$log_path${NC}"
    echo ""

    # Error breakdown
    echo -e "${WHITE}${BOLD}Error Analysis${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    
    local total_errors=$(count_total_errors "$service")
    local total_warnings=$(count_warnings "$service")
    echo -e "  Total Errors:    ${RED}$total_errors${NC}"
    echo -e "  Total Warnings:  ${YELLOW}$total_warnings${NC}"
    echo ""

    echo -e "${WHITE}${BOLD}Error Categories${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    printf "  ${DIM}%-20s %-10s${NC}\n" "CATEGORY" "COUNT"
    
    local idx=1
    for category in "${!ERROR_PATTERNS[@]}"; do
        local pattern="${ERROR_PATTERNS[$category]}"
        local count=$(count_errors_by_pattern "$service" "$pattern")
        
        local count_color="${GREEN}"
        [ "$count" -gt 0 ] 2>/dev/null && count_color="${YELLOW}"
        [ "$count" -gt 50 ] 2>/dev/null && count_color="${RED}"
        
        printf "  ${DIM}%2d)${NC} %-17s ${count_color}%-10s${NC}\n" "$idx" "$category" "$count"
        ((idx++))
    done
    echo ""

    # Recent activity
    echo -e "${WHITE}${BOLD}Recent Log Activity (last 5 lines)${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    docker logs --tail 5 "$service" 2>&1 | while read line; do
        # Colorize based on content
        if echo "$line" | grep -qiE "error|fatal|panic|critical"; then
            echo -e "  ${RED}$line${NC}"
        elif echo "$line" | grep -qiE "warn"; then
            echo -e "  ${YELLOW}$line${NC}"
        else
            echo -e "  ${DIM}$line${NC}"
        fi
    done
    echo ""

    # Menu
    echo -e "${WHITE}${BOLD}Options${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    echo "    1) View errors by category"
    echo "    2) View last 50 log lines"
    echo "    3) View last 200 log lines"
    echo "    4) Follow log (live)"
    echo "    5) Search in log"
    echo "    6) Clear this service's log"
    echo "    ${CYAN}e) View errors only (numbered list with context jump)${NC}"
    echo "    0) Back to main menu"
    echo ""
    read -p "  Select option: " choice

    case $choice in
        1) view_errors_by_category "$service" ;;
        2) view_log_tail "$service" 50 ;;
        3) view_log_tail "$service" 200 ;;
        4) follow_log "$service" ;;
        5) search_in_log "$service" ;;
        6) clear_service_log "$service" ;;
        e|E) view_numbered_errors "$service" ;;
        0) return ;;
        *) show_service_detail "$service" ;;
    esac
}

# =============================================================================
# ERROR VIEWING
# =============================================================================

# View numbered errors with ability to jump to context
view_numbered_errors() {
    local service=$1
    local page=1
    local per_page=20
    
    # Create temp file for storing all log lines with line numbers
    local log_file=$(mktemp)
    local error_file=$(mktemp)
    local classified_file=$(mktemp)
    
    # Trap to clean up temp files
    trap "rm -f '$log_file' '$error_file' '$classified_file'" RETURN
    
    # Get container start time for startup detection
    local container_start=$(get_container_start_time "$service")
    
    # Get full log with line numbers
    docker logs "$service" 2>&1 | nl -ba > "$log_file"
    
    # Extract error lines, filter out exclusions, and classify
    grep -iE "error|err\]|failed|fatal|panic|critical|exception|ERRO|FATL" "$log_file" 2>/dev/null | while IFS= read -r line; do
        local content=$(echo "$line" | cut -c8-)
        
        # Skip if it matches exclusion patterns
        local excluded=false
        for exclusion in "${EXCLUSION_PATTERNS[@]}"; do
            if echo "$content" | grep -qiE "$exclusion"; then
                excluded=true
                break
            fi
        done
        
        if [ "$excluded" = false ]; then
            # Check if it's a startup error
            if is_startup_error "$content" "$container_start"; then
                echo "STARTUP|$line" >> "$classified_file"
            else
                echo "ERROR|$line" >> "$classified_file"
            fi
        fi
    done
    
    # Create final error file with classification prefix
    cat "$classified_file" > "$error_file" 2>/dev/null || true
    
    local total_errors=$(wc -l < "$error_file" 2>/dev/null || echo "0")
    total_errors=$((total_errors + 0))  # Ensure it's a number
    
    if [ "$total_errors" -eq 0 ]; then
        clear
        echo ""
        draw_box_top
        draw_box_line "              NUMBERED ERRORS: $service"
        draw_box_bottom
        echo ""
        echo -e "  ${GREEN}No errors found in logs!${NC}"
        press_enter
        show_service_detail "$service"
        return
    fi
    
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "              NUMBERED ERRORS: $service"
        draw_box_bottom
        echo ""
        
        local total_pages=$(( (total_errors + per_page - 1) / per_page ))
        local start_idx=$(( (page - 1) * per_page + 1 ))
        local end_idx=$(( page * per_page ))
        [ "$end_idx" -gt "$total_errors" ] && end_idx=$total_errors
        
        echo -e "  Found ${RED}$total_errors${NC} errors/warnings  |  Page ${CYAN}$page${NC} of ${CYAN}$total_pages${NC}  |  Showing #$start_idx-$end_idx"
        echo ""
        echo -e "${DIM}  [Error#]  [LogLine]  Message${NC}"
        echo -e "${DIM}──────────────────────────────────────────────────────────────────────────────${NC}"
        
        # Display current page of errors
        local idx=0
        local display_idx=$start_idx
        while IFS= read -r entry; do
            ((idx++))
            if [ "$idx" -ge "$start_idx" ] && [ "$idx" -le "$end_idx" ]; then
                # Extract classification and line
                local classification=$(echo "$entry" | cut -d'|' -f1)
                local line=$(echo "$entry" | cut -d'|' -f2-)
                
                # Extract line number from the log (first field from nl command)
                local log_line_num=$(echo "$line" | awk '{print $1}')
                # Get the rest of the line (the actual log content)
                local log_content=$(echo "$line" | cut -c8-)
                
                # Truncate for display
                local short_content="${log_content:0:50}"
                
                # Color and annotate based on classification and severity
                local annotation=""
                if [ "$classification" = "STARTUP" ]; then
                    annotation="${MAGENTA}[STARTUP]${NC} "
                fi
                
                if echo "$log_content" | grep -qiE "fatal|panic|critical|FATL"; then
                    printf "  ${RED}%4d${NC})  ${DIM}L%-6s${NC}  ${annotation}${RED}%s${NC}\n" "$display_idx" "$log_line_num" "$short_content"
                elif echo "$log_content" | grep -qiE "error|err\]|failed|exception|ERRO"; then
                    if [ "$classification" = "STARTUP" ]; then
                        printf "  ${YELLOW}%4d${NC})  ${DIM}L%-6s${NC}  ${annotation}${DIM}%s${NC}\n" "$display_idx" "$log_line_num" "$short_content"
                    else
                        printf "  ${YELLOW}%4d${NC})  ${DIM}L%-6s${NC}  ${annotation}${YELLOW}%s${NC}\n" "$display_idx" "$log_line_num" "$short_content"
                    fi
                else
                    printf "  ${DIM}%4d${NC})  ${DIM}L%-6s${NC}  ${annotation}%s\n" "$display_idx" "$log_line_num" "$short_content"
                fi
                ((display_idx++))
            fi
        done < "$error_file"
        
        echo ""
        echo -e "${DIM}──────────────────────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${WHITE}${BOLD}Navigation:${NC}"
        echo "    [number]  - View error with 50 lines context before/after"
        echo "    n         - Next page"
        echo "    p         - Previous page"
        echo "    g [page]  - Go to page"
        echo "    f         - Filter by keyword"
        echo "    0         - Back to service detail"
        echo ""
        read -p "  Enter choice: " choice
        
        case $choice in
            n|N)
                if [ "$page" -lt "$total_pages" ]; then
                    ((page++))
                else
                    print_warning "Already at last page"
                    sleep 1
                fi
                ;;
            p|P)
                if [ "$page" -gt 1 ]; then
                    ((page--))
                else
                    print_warning "Already at first page"
                    sleep 1
                fi
                ;;
            g\ *|G\ *)
                local target_page=$(echo "$choice" | awk '{print $2}')
                if [ "$target_page" -ge 1 ] 2>/dev/null && [ "$target_page" -le "$total_pages" ] 2>/dev/null; then
                    page=$target_page
                else
                    print_warning "Invalid page number"
                    sleep 1
                fi
                ;;
            f|F)
                echo ""
                read -p "  Enter filter keyword: " filter_word
                if [ -n "$filter_word" ]; then
                    view_filtered_numbered_errors "$service" "$filter_word"
                fi
                ;;
            0)
                show_service_detail "$service"
                return
                ;;
            *)
                # Check if it's a number (error selection)
                if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$total_errors" ] 2>/dev/null; then
                    # Get the log line number for this error (handle classified format)
                    local selected_entry=$(sed -n "${choice}p" "$error_file")
                    local selected_line=$(echo "$selected_entry" | cut -d'|' -f2-)
                    local log_line_num=$(echo "$selected_line" | awk '{print $1}')
                    view_error_with_context "$service" "$log_line_num" "$log_file" "$choice"
                fi
                ;;
        esac
    done
}

# View filtered errors by keyword
view_filtered_numbered_errors() {
    local service=$1
    local filter=$2
    local page=1
    local per_page=20
    
    # Create temp file for storing all log lines with line numbers
    local log_file=$(mktemp)
    local error_file=$(mktemp)
    
    # Trap to clean up temp files
    trap "rm -f '$log_file' '$error_file'" RETURN
    
    # Get full log with line numbers
    docker logs "$service" 2>&1 | nl -ba > "$log_file"
    
    # Extract error lines matching filter
    grep -iE "error|err\]|failed|fatal|panic|critical|exception|warning|warn\]" "$log_file" | \
        grep -i "$filter" > "$error_file" 2>/dev/null || true
    
    local total_errors=$(wc -l < "$error_file" 2>/dev/null || echo "0")
    total_errors=$((total_errors + 0))
    
    if [ "$total_errors" -eq 0 ]; then
        clear
        echo ""
        draw_box_top
        draw_box_line "              FILTERED ERRORS: $service"
        draw_box_bottom
        echo ""
        echo -e "  ${YELLOW}No errors matching '${filter}' found${NC}"
        press_enter
        return
    fi
    
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "              FILTERED ERRORS: $service"
        draw_box_bottom
        echo ""
        
        local total_pages=$(( (total_errors + per_page - 1) / per_page ))
        local start_idx=$(( (page - 1) * per_page + 1 ))
        local end_idx=$(( page * per_page ))
        [ "$end_idx" -gt "$total_errors" ] && end_idx=$total_errors
        
        echo -e "  Filter: ${CYAN}'$filter'${NC}  |  Found ${RED}$total_errors${NC} matching  |  Page ${CYAN}$page${NC}/${CYAN}$total_pages${NC}"
        echo ""
        echo -e "${DIM}  [Error#]  [LogLine]  Message${NC}"
        echo -e "${DIM}──────────────────────────────────────────────────────────────────────────────${NC}"
        
        local idx=0
        local display_idx=$start_idx
        while IFS= read -r line; do
            ((idx++))
            if [ "$idx" -ge "$start_idx" ] && [ "$idx" -le "$end_idx" ]; then
                local log_line_num=$(echo "$line" | awk '{print $1}')
                local log_content=$(echo "$line" | cut -c8-)
                local short_content="${log_content:0:60}"
                
                if echo "$line" | grep -qiE "fatal|panic|critical"; then
                    printf "  ${RED}%4d${NC})  ${DIM}L%-6s${NC}  ${RED}%s${NC}\n" "$display_idx" "$log_line_num" "$short_content"
                elif echo "$line" | grep -qiE "error|err\]|failed|exception"; then
                    printf "  ${YELLOW}%4d${NC})  ${DIM}L%-6s${NC}  ${YELLOW}%s${NC}\n" "$display_idx" "$log_line_num" "$short_content"
                else
                    printf "  ${DIM}%4d${NC})  ${DIM}L%-6s${NC}  %s\n" "$display_idx" "$log_line_num" "$short_content"
                fi
                ((display_idx++))
            fi
        done < "$error_file"
        
        echo ""
        echo -e "${DIM}──────────────────────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo -e "  ${WHITE}${BOLD}Navigation:${NC}"
        echo "    [number]  - View error with 50 lines context"
        echo "    n/p       - Next/Previous page"
        echo "    0         - Back"
        echo ""
        read -p "  Enter choice: " choice
        
        case $choice in
            n|N) [ "$page" -lt "$total_pages" ] && ((page++)) ;;
            p|P) [ "$page" -gt 1 ] && ((page--)) ;;
            0) return ;;
            *)
                if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$total_errors" ] 2>/dev/null; then
                    local selected_line=$(sed -n "${choice}p" "$error_file")
                    local log_line_num=$(echo "$selected_line" | awk '{print $1}')
                    view_error_with_context "$service" "$log_line_num" "$log_file" "$choice"
                fi
                ;;
        esac
    done
}

# View a specific error with context (50 lines before and after)
view_error_with_context() {
    local service=$1
    local target_line=$2
    local log_file=$3
    local error_num=$4
    local context=50
    
    # Calculate start and end lines
    local start_line=$((target_line - context))
    [ "$start_line" -lt 1 ] && start_line=1
    local end_line=$((target_line + context))
    
    clear
    echo ""
    draw_box_top
    draw_box_line "              ERROR #$error_num CONTEXT: $service"
    draw_box_divider
    printf "${CYAN}║${NC}  Target Error Line: ${RED}%-54s${NC} ${CYAN}║${NC}\n" "L$target_line"
    printf "${CYAN}║${NC}  Context Range:     ${DIM}L$start_line - L$end_line (±$context lines)${NC}%-22s ${CYAN}║${NC}\n" ""
    draw_box_bottom
    echo ""
    
    # Get total lines in log
    local total_lines=$(wc -l < "$log_file" 2>/dev/null || echo "0")
    [ "$end_line" -gt "$total_lines" ] && end_line=$total_lines
    
    echo -e "${DIM}  Log context (${context} lines before and after the error):${NC}"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────────${NC}"
    
    # Display lines with highlighting
    local line_num=0
    while IFS= read -r line; do
        ((line_num++))
        if [ "$line_num" -ge "$start_line" ] && [ "$line_num" -le "$end_line" ]; then
            # Get the actual log line number (first field)
            local actual_line=$(echo "$line" | awk '{print $1}')
            local content=$(echo "$line" | cut -c8-)
            
            # Highlight the target line
            if [ "$actual_line" -eq "$target_line" ] 2>/dev/null; then
                echo -e "  ${RED}▶ L${actual_line}:${NC} ${RED}${BOLD}$content${NC}"
            elif echo "$content" | grep -qiE "error|fatal|panic|critical|failed"; then
                echo -e "  ${YELLOW}  L${actual_line}:${NC} ${YELLOW}$content${NC}"
            elif echo "$content" | grep -qiE "warning|warn"; then
                echo -e "  ${DIM}  L${actual_line}:${NC} $content"
            else
                echo -e "  ${DIM}  L${actual_line}:${NC} $content"
            fi
        fi
    done < "$log_file"
    
    echo ""
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${RED}▶${NC} = Target error line (L$target_line)"
    echo ""
    
    # Options for navigation
    echo -e "${WHITE}${BOLD}Options:${NC}"
    echo "    m - View more context (100 lines)"
    echo "    a - View all log around this error"
    echo "    c - Copy error line to clipboard (if available)"
    echo "    Enter - Back to error list"
    echo ""
    read -p "  Select option: " opt
    
    case $opt in
        m|M)
            view_error_with_extended_context "$service" "$target_line" "$log_file" "$error_num" 100
            ;;
        a|A)
            view_error_with_extended_context "$service" "$target_line" "$log_file" "$error_num" 200
            ;;
        c|C)
            local error_line=$(sed -n "${target_line}p" "$log_file" | cut -c8-)
            if command -v xclip &> /dev/null; then
                echo "$error_line" | xclip -selection clipboard
                print_success "Error copied to clipboard"
            elif command -v pbcopy &> /dev/null; then
                echo "$error_line" | pbcopy
                print_success "Error copied to clipboard"
            else
                print_warning "No clipboard tool available (xclip/pbcopy)"
                echo ""
                echo "  Error line:"
                echo "  $error_line"
            fi
            press_enter
            ;;
    esac
}

# View error with extended context
view_error_with_extended_context() {
    local service=$1
    local target_line=$2
    local log_file=$3
    local error_num=$4
    local context=$5
    
    local start_line=$((target_line - context))
    [ "$start_line" -lt 1 ] && start_line=1
    local end_line=$((target_line + context))
    
    clear
    echo ""
    draw_box_top
    draw_box_line "              ERROR #$error_num EXTENDED CONTEXT: $service"
    draw_box_divider
    printf "${CYAN}║${NC}  Target Error Line: ${RED}%-54s${NC} ${CYAN}║${NC}\n" "L$target_line"
    printf "${CYAN}║${NC}  Context Range:     ${DIM}L$start_line - L$end_line (±$context lines)${NC}%-22s ${CYAN}║${NC}\n" ""
    draw_box_bottom
    echo ""
    
    local total_lines=$(wc -l < "$log_file" 2>/dev/null || echo "0")
    [ "$end_line" -gt "$total_lines" ] && end_line=$total_lines
    
    echo -e "${DIM}  Extended log context (±$context lines):${NC}"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────────${NC}"
    
    # Use sed to extract range and display with highlighting
    sed -n "${start_line},${end_line}p" "$log_file" | while IFS= read -r line; do
        local actual_line=$(echo "$line" | awk '{print $1}')
        local content=$(echo "$line" | cut -c8-)
        
        if [ "$actual_line" -eq "$target_line" ] 2>/dev/null; then
            echo -e "  ${RED}▶ L${actual_line}:${NC} ${RED}${BOLD}$content${NC}"
        elif echo "$content" | grep -qiE "error|fatal|panic|critical|failed"; then
            echo -e "  ${YELLOW}  L${actual_line}:${NC} ${YELLOW}$content${NC}"
        else
            echo -e "  ${DIM}  L${actual_line}:${NC} $content"
        fi
    done | less -R
    
    echo ""
    press_enter
}

view_errors_by_category() {
    local service=$1
    
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "              ERROR CATEGORIES: $service"
        draw_box_bottom
        echo ""

        echo "  Select error category to view:"
        echo ""
        
        local idx=1
        local categories=()
        for category in "${!ERROR_PATTERNS[@]}"; do
            local pattern="${ERROR_PATTERNS[$category]}"
            local count=$(count_errors_by_pattern "$service" "$pattern")
            categories+=("$category")
            
            local count_color="${GREEN}"
            [ "$count" -gt 0 ] 2>/dev/null && count_color="${YELLOW}"
            [ "$count" -gt 50 ] 2>/dev/null && count_color="${RED}"
            
            printf "    ${DIM}%2d)${NC} %-20s ${count_color}%s errors${NC}\n" "$idx" "$category" "$count"
            ((idx++))
        done
        
        echo ""
        echo "    0) Back"
        echo ""
        read -p "  Select category: " choice

        if [ "$choice" = "0" ]; then
            show_service_detail "$service"
            return
        fi

        if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#categories[@]}" ] 2>/dev/null; then
            local selected_category="${categories[$((choice-1))]}"
            view_category_errors "$service" "$selected_category"
        fi
    done
}

view_category_errors() {
    local service=$1
    local category=$2
    local pattern="${ERROR_PATTERNS[$category]}"

    clear
    echo ""
    draw_box_top
    draw_box_line "              $category ERRORS: $service"
    draw_box_bottom
    echo ""

    # Get container start time for startup detection
    local container_start=$(get_container_start_time "$service")
    local uptime=$(get_container_uptime_seconds "$service")
    
    # Build exclusion grep pattern
    local exclusion_pattern=""
    for excl in "${EXCLUSION_PATTERNS[@]}"; do
        if [ -z "$exclusion_pattern" ]; then
            exclusion_pattern="$excl"
        else
            exclusion_pattern="$exclusion_pattern|$excl"
        fi
    done
    
    # Count actual errors (excluding false positives)
    local actual_count=0
    local startup_count=0
    local excluded_count=0
    local temp_errors=$(mktemp)
    local temp_all=$(mktemp)
    
    # First, get all lines matching the category pattern
    docker logs "$service" 2>&1 | grep -iE "$pattern" > "$temp_all" 2>/dev/null || true
    
    # Process each line
    while IFS= read -r line; do
        # Check for real error indicators (error=", failed=", etc.) - these are NEVER excluded
        if echo "$line" | grep -qiE 'error="|err="|failed="|exception="|panic="|fatal="'; then
            # This is a real error even if logged at info level
            if is_startup_error "$line" "$container_start"; then
                echo "STARTUP:$line" >> "$temp_errors"
            else
                echo "ERROR:$line" >> "$temp_errors"
            fi
        # Check if line should be excluded (info/success message)
        elif echo "$line" | grep -qiE "$exclusion_pattern"; then
            echo "EXCLUDED:$line" >> "$temp_errors"
        # Check if it has error keywords
        elif echo "$line" | grep -qiE "error|err\]|failed|fatal|panic|critical|exception|ERRO|FATL"; then
            if is_startup_error "$line" "$container_start"; then
                echo "STARTUP:$line" >> "$temp_errors"
            else
                echo "ERROR:$line" >> "$temp_errors"
            fi
        else
            # Matches pattern but isn't an error keyword - likely info
            echo "EXCLUDED:$line" >> "$temp_errors"
        fi
    done < "$temp_all"
    
    actual_count=$(grep -c "^ERROR:" "$temp_errors" 2>/dev/null || echo "0")
    startup_count=$(grep -c "^STARTUP:" "$temp_errors" 2>/dev/null || echo "0")
    excluded_count=$(grep -c "^EXCLUDED:" "$temp_errors" 2>/dev/null || echo "0")
    
    local total_errors=$((actual_count + startup_count))
    
    echo -e "  ${WHITE}${BOLD}Analysis Results:${NC}"
    echo -e "  ├─ ${RED}Actual errors:${NC}      $actual_count"
    echo -e "  ├─ ${YELLOW}Startup errors:${NC}     $startup_count ${DIM}(within first ${STARTUP_WINDOW_SECONDS}s)${NC}"
    echo -e "  └─ ${DIM}Excluded (info):${NC}    $excluded_count ${DIM}(false positives filtered)${NC}"
    echo ""

    if [ "$total_errors" -gt 0 ]; then
        echo -e "${WHITE}${BOLD}Error Entries:${NC}"
        echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
        
        local shown=0
        
        # Show actual errors first
        if [ "$actual_count" -gt 0 ]; then
            echo -e "  ${RED}${BOLD}── Actual Errors ──${NC}"
            grep "^ERROR:" "$temp_errors" 2>/dev/null | head -20 | while IFS= read -r entry; do
                local line="${entry#ERROR:}"
                echo -e "  ${RED}$line${NC}"
                ((shown++))
            done
            echo ""
        fi
        
        # Show startup errors with annotation
        if [ "$startup_count" -gt 0 ]; then
            echo -e "  ${YELLOW}${BOLD}── Startup Errors ──${NC} ${DIM}(likely transient, occurred during container initialization)${NC}"
            grep "^STARTUP:" "$temp_errors" 2>/dev/null | head -15 | while IFS= read -r entry; do
                local line="${entry#STARTUP:}"
                echo -e "  ${YELLOW}[STARTUP]${NC} ${DIM}$line${NC}"
            done
            echo ""
        fi

        if [ "$total_errors" -gt 35 ]; then
            echo ""
            echo -e "${YELLOW}  (Showing first ~35 matches. Use search for specific entries)${NC}"
        fi
    else
        echo -e "  ${GREEN}No actual errors found in this category!${NC}"
        
        if [ "$excluded_count" -gt 0 ]; then
            echo ""
            echo -e "  ${DIM}$excluded_count info/success messages were filtered out.${NC}"
        fi
    fi
    
    # Cleanup
    rm -f "$temp_errors" "$temp_all"

    press_enter
}

view_log_tail() {
    local service=$1
    local lines=$2

    clear
    echo ""
    draw_box_top
    draw_box_line "              LAST $lines LINES: $service"
    draw_box_bottom
    echo ""

    docker logs --tail "$lines" "$service" 2>&1 | while read line; do
        if echo "$line" | grep -qiE "error|fatal|panic|critical"; then
            echo -e "${RED}$line${NC}"
        elif echo "$line" | grep -qiE "warn"; then
            echo -e "${YELLOW}$line${NC}"
        elif echo "$line" | grep -qiE "success|started|ready|connected"; then
            echo -e "${GREEN}$line${NC}"
        else
            echo "$line"
        fi
    done

    press_enter
    show_service_detail "$service"
}

follow_log() {
    local service=$1
    
    clear
    echo ""
    echo -e "${CYAN}Following log for $service... (Press Ctrl+C to stop)${NC}"
    echo ""
    
    docker logs -f --tail 20 "$service" 2>&1
    
    show_service_detail "$service"
}

# =============================================================================
# SEARCH FUNCTIONALITY
# =============================================================================

search_in_log() {
    local service=$1

    clear
    echo ""
    draw_box_top
    draw_box_line "              SEARCH LOG: $service"
    draw_box_bottom
    echo ""

    echo "  Quick search options:"
    echo "    1) Device disconnects"
    echo "    2) Account errors"
    echo "    3) Database errors"
    echo "    4) Connection issues"
    echo "    5) API errors"
    echo "    6) Custom search"
    echo "    0) Back"
    echo ""
    read -p "  Select option: " choice

    local pattern=""
    case $choice in
        1) pattern="disconnect|disconnected|device.*lost|worker.*offline|device.*removed" ;;
        2) pattern="account|login|auth|banned|invalid.*account|credential" ;;
        3) pattern="database|mysql|mariadb|sql|SQLSTATE|deadlock" ;;
        4) pattern="connection|refused|timeout|ECONNREFUSED|socket.*error" ;;
        5) pattern="api|endpoint|HTTP.*[45][0-9][0-9]|request.*failed" ;;
        6)
            echo ""
            read -p "  Enter search pattern (regex): " pattern
            ;;
        0)
            show_service_detail "$service"
            return
            ;;
    esac

    if [ -n "$pattern" ]; then
        clear
        echo ""
        draw_box_top
        draw_box_line "              SEARCH RESULTS: $service"
        draw_box_bottom
        echo ""
        echo -e "  Pattern: ${CYAN}$pattern${NC}"
        echo ""

        local count=$(docker logs "$service" 2>&1 | grep -iEc "$pattern" 2>/dev/null || echo "0")
        echo -e "  Found ${YELLOW}$count${NC} matching entries"
        echo ""

        if [ "$count" -gt 0 ]; then
            echo -e "${WHITE}${BOLD}Matching Entries:${NC}"
            echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
            
            docker logs "$service" 2>&1 | grep -iE -B1 -A1 "$pattern" 2>/dev/null | head -150 | while read line; do
                if echo "$line" | grep -qiE "$pattern"; then
                    echo -e "${YELLOW}$line${NC}"
                elif [ "$line" = "--" ]; then
                    echo -e "${DIM}---${NC}"
                else
                    echo -e "${DIM}$line${NC}"
                fi
            done

            if [ "$count" -gt 50 ]; then
                echo ""
                echo -e "${YELLOW}  (Showing first ~50 matches)${NC}"
            fi
        fi

        press_enter
    fi

    search_in_log "$service"
}

# =============================================================================
# DEVICE DISCONNECT MONITOR
# =============================================================================

show_device_disconnects() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              DEVICE DISCONNECT MONITOR"
    draw_box_bottom
    echo ""

    echo -e "${WHITE}${BOLD}Scanning all services for device disconnects...${NC}"
    echo ""

    local total_disconnects=0

    for service in "rotom" "dragonite"; do
        local status=$(get_container_status "$service")
        if [ "$status" = "running" ]; then
            local count=$(docker logs "$service" 2>&1 | grep -iEc "disconnect|device.*lost|worker.*offline|device.*removed|connection.*closed" 2>/dev/null || echo "0")
            total_disconnects=$((total_disconnects + count))
            
            echo -e "  ${CYAN}$service:${NC}"
            if [ "$count" -gt 0 ]; then
                echo -e "    Found ${YELLOW}$count${NC} disconnect events"
                echo ""
                echo "    Recent disconnects:"
                docker logs "$service" 2>&1 | grep -iE "disconnect|device.*lost|worker.*offline" 2>/dev/null | tail -5 | while read line; do
                    echo -e "      ${DIM}$line${NC}"
                done
            else
                echo -e "    ${GREEN}No disconnect events found${NC}"
            fi
            echo ""
        fi
    done

    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "  Total disconnect events: ${YELLOW}$total_disconnects${NC}"

    press_enter
}

# =============================================================================
# LOG MAINTENANCE
# =============================================================================

clear_service_log() {
    local service=$1
    
    echo ""
    read -p "  Are you sure you want to clear the log for $service? (y/n) [n]: " confirm
    
    if [ "$confirm" = "y" ]; then
        local log_path=$(docker inspect --format='{{.LogPath}}' "$service" 2>/dev/null)
        if [ -n "$log_path" ] && [ -f "$log_path" ]; then
            sudo truncate -s 0 "$log_path" 2>/dev/null
            if [ $? -eq 0 ]; then
                print_success "Log cleared for $service"
            else
                print_error "Failed to clear log (may need sudo)"
            fi
        else
            print_warning "Log file not found"
        fi
    fi
    
    press_enter
    show_service_detail "$service"
}

log_maintenance_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "              LOG MAINTENANCE"
        draw_box_bottom
        echo ""

        # Show current log sizes
        echo -e "${WHITE}${BOLD}Current Log Sizes${NC}"
        echo -e "${DIM}────────────────────────────────────────${NC}"
        
        local total_size=0
        local idx=1
        for service in "${SERVICES[@]}"; do
            local status=$(get_container_status "$service")
            if [ "$status" != "not_found" ]; then
                local size_bytes=$(get_log_size "$service")
                total_size=$((total_size + size_bytes))
                local log_size=$(format_bytes "$size_bytes")
                
                local size_color="${GREEN}"
                [ "$size_bytes" -gt 104857600 ] 2>/dev/null && size_color="${YELLOW}"  # >100MB
                [ "$size_bytes" -gt 524288000 ] 2>/dev/null && size_color="${RED}"     # >500MB
                
                printf "    ${DIM}%2d)${NC} %-18s ${size_color}%s${NC}\n" "$idx" "$service" "$log_size"
            fi
            ((idx++))
        done
        
        echo ""
        echo -e "  Total log size: ${CYAN}$(format_bytes $total_size)${NC}"
        echo ""

        echo -e "${WHITE}${BOLD}Options${NC}"
        echo -e "${DIM}────────────────────────────────────────${NC}"
        echo "    1) Clear individual service log"
        echo "    2) Clear ALL logs"
        echo "    3) Show log file paths"
        echo "    0) Back"
        echo ""
        read -p "  Select option: " choice

        case $choice in
            1)
                echo ""
                read -p "  Enter service number to clear: " svc_num
                if [ "$svc_num" -ge 1 ] 2>/dev/null && [ "$svc_num" -le "${#SERVICES[@]}" ] 2>/dev/null; then
                    local svc="${SERVICES[$((svc_num-1))]}"
                    read -p "  Clear log for $svc? (y/n) [n]: " confirm
                    if [ "$confirm" = "y" ]; then
                        local log_path=$(docker inspect --format='{{.LogPath}}' "$svc" 2>/dev/null)
                        if [ -n "$log_path" ]; then
                            sudo truncate -s 0 "$log_path" 2>/dev/null
                            print_success "Log cleared for $svc"
                        fi
                    fi
                fi
                press_enter
                ;;
            2)
                echo ""
                print_warning "This will clear ALL Docker logs!"
                read -p "  Type 'CLEAR ALL' to confirm: " confirm
                if [ "$confirm" = "CLEAR ALL" ]; then
                    for service in "${SERVICES[@]}"; do
                        local log_path=$(docker inspect --format='{{.LogPath}}' "$service" 2>/dev/null)
                        if [ -n "$log_path" ] && [ -f "$log_path" ]; then
                            sudo truncate -s 0 "$log_path" 2>/dev/null
                            echo -e "  ${GREEN}✓${NC} Cleared: $service"
                        fi
                    done
                    print_success "All logs cleared!"
                fi
                press_enter
                ;;
            3)
                echo ""
                echo -e "${WHITE}${BOLD}Log File Paths${NC}"
                echo -e "${DIM}────────────────────────────────────────${NC}"
                for service in "${SERVICES[@]}"; do
                    local log_path=$(docker inspect --format='{{.LogPath}}' "$service" 2>/dev/null)
                    if [ -n "$log_path" ]; then
                        echo -e "  ${CYAN}$service:${NC}"
                        echo -e "    ${DIM}$log_path${NC}"
                    fi
                done
                press_enter
                ;;
            0) return ;;
        esac
    done
}

# =============================================================================
# DOCKER CONFIGURATION
# =============================================================================

docker_config_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "              DOCKER CONFIGURATION"
        draw_box_bottom
        echo ""

        # Check current daemon.json settings
        local daemon_file="/etc/docker/daemon.json"
        
        echo -e "${WHITE}${BOLD}Current Docker Configuration${NC}"
        echo -e "${DIM}────────────────────────────────────────${NC}"
        
        if [ -f "$daemon_file" ]; then
            echo -e "  Config file: ${GREEN}Found${NC} ($daemon_file)"
            echo ""
            echo "  Current settings:"
            cat "$daemon_file" 2>/dev/null | while read line; do
                echo "    $line"
            done
        else
            echo -e "  Config file: ${YELLOW}Not found${NC}"
            echo "  (Using Docker defaults)"
        fi
        echo ""

        echo -e "${WHITE}${BOLD}Recommended Settings${NC}"
        echo -e "${DIM}────────────────────────────────────────${NC}"
        echo "  For log management, we recommend:"
        echo ""
        echo '    {'
        echo '      "log-driver": "json-file",'
        echo '      "log-opts": {'
        echo '        "max-size": "100m",'
        echo '        "max-file": "3",'
        echo '        "compress": "true"'
        echo '      }'
        echo '    }'
        echo ""
        echo "  This limits each container to 300MB total logs (3 × 100MB)"
        echo ""

        echo -e "${WHITE}${BOLD}Options${NC}"
        echo -e "${DIM}────────────────────────────────────────${NC}"
        echo "    1) View current config"
        echo "    2) Apply recommended log settings"
        echo "    3) Edit config manually"
        echo "    4) View Docker info"
        echo "    0) Back"
        echo ""
        read -p "  Select option: " choice

        case $choice in
            1)
                echo ""
                if [ -f "$daemon_file" ]; then
                    echo "  Current $daemon_file:"
                    echo ""
                    cat "$daemon_file"
                else
                    echo "  No daemon.json file exists."
                fi
                press_enter
                ;;
            2)
                apply_recommended_docker_config
                ;;
            3)
                echo ""
                echo "  Opening $daemon_file in editor..."
                if [ -f "$daemon_file" ]; then
                    sudo ${EDITOR:-nano} "$daemon_file"
                else
                    echo '{}' | sudo tee "$daemon_file" > /dev/null
                    sudo ${EDITOR:-nano} "$daemon_file"
                fi
                echo ""
                read -p "  Restart Docker to apply changes? (y/n) [n]: " restart
                if [ "$restart" = "y" ]; then
                    sudo systemctl restart docker
                    print_success "Docker restarted"
                fi
                press_enter
                ;;
            4)
                echo ""
                docker info 2>&1 | head -40
                press_enter
                ;;
            0) return ;;
        esac
    done
}

apply_recommended_docker_config() {
    local daemon_file="/etc/docker/daemon.json"
    
    echo ""
    echo "  This will configure Docker with:"
    echo "    - Log rotation (max 100MB per file)"
    echo "    - Max 3 log files per container"
    echo "    - Compressed old logs"
    echo ""
    
    read -p "  Apply these settings? (y/n) [n]: " confirm
    
    if [ "$confirm" = "y" ]; then
        # Backup existing
        if [ -f "$daemon_file" ]; then
            sudo cp "$daemon_file" "${daemon_file}.backup.$(date +%Y%m%d%H%M%S)"
            print_info "Backed up existing config"
        fi
        
        # Check if file exists and has content
        if [ -f "$daemon_file" ] && [ -s "$daemon_file" ]; then
            # Try to merge with existing config
            print_warning "Existing config found. Manual merge may be needed."
            echo ""
            echo "  Current config:"
            cat "$daemon_file"
            echo ""
            read -p "  Overwrite with recommended settings? (y/n) [n]: " overwrite
            if [ "$overwrite" != "y" ]; then
                press_enter
                return
            fi
        fi
        
        # Write recommended config
        sudo tee "$daemon_file" > /dev/null << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3",
    "compress": "true"
  }
}
EOF
        
        print_success "Configuration written to $daemon_file"
        echo ""
        read -p "  Restart Docker now to apply? (y/n) [n]: " restart
        if [ "$restart" = "y" ]; then
            print_info "Restarting Docker..."
            sudo systemctl restart docker
            if [ $? -eq 0 ]; then
                print_success "Docker restarted successfully"
                print_warning "Note: Log settings only apply to NEW containers"
                echo "  Run: docker compose down && docker compose up -d"
            else
                print_error "Failed to restart Docker"
            fi
        fi
    fi
    
    press_enter
}

# =============================================================================
# XILRIWS STATUS & MONITORING
# =============================================================================

# Xilriws log patterns
XILRIWS_PATTERNS=(
    ["success"]="Successfully obtained cookies|cookie.*success|login.*success"
    ["auth_banned"]="auth.banned|auth_banned|authentication.*banned"
    ["invalid_cred"]="invalid.*credential|wrong.*password|incorrect.*login|invalid.*password"
    ["tunnel_error"]="tunnel.*error|tunneling.*failed|proxy.*tunnel|CONNECT.*failed"
    ["code_15"]="code.*15|error.*15|status.*15"
    ["perm_banned"]="permanently.*banned|permanent.*ban|IP.*banned|banned.*IP"
    ["rate_limit"]="rate.*limit|too.*many.*requests|429"
    ["timeout"]="timeout|timed.*out|ETIMEDOUT"
    ["conn_refused"]="connection.*refused|ECONNREFUSED"
    ["proxy_error"]="proxy.*error|proxy.*failed|bad.*proxy"
)

# Get Xilriws stats from logs
get_xilriws_stats() {
    local container="xilriws"
    local status=$(get_container_status "$container")
    
    if [ "$status" != "running" ]; then
        return 1
    fi
    
    # Get log content once for efficiency
    local log_content=$(docker logs "$container" 2>&1)
    
    # Count various events
    XILRIWS_SUCCESS=$(echo "$log_content" | grep -iEc "Successfully obtained cookies|cookie.*success|login.*success" || echo "0")
    XILRIWS_AUTH_BANNED=$(echo "$log_content" | grep -iEc "auth.banned|auth_banned|authentication.*banned" || echo "0")
    XILRIWS_INVALID_CRED=$(echo "$log_content" | grep -iEc "invalid.*credential|wrong.*password|incorrect.*login|invalid.*password" || echo "0")
    XILRIWS_TUNNEL_ERROR=$(echo "$log_content" | grep -iEc "tunnel.*error|tunneling.*failed|proxy.*tunnel|CONNECT.*failed" || echo "0")
    XILRIWS_CODE_15=$(echo "$log_content" | grep -iEc "code.*15|error.*15|status.*15|code\":15" || echo "0")
    XILRIWS_PERM_BANNED=$(echo "$log_content" | grep -iEc "permanently.*banned|permanent.*ban|IP.*banned" || echo "0")
    XILRIWS_RATE_LIMIT=$(echo "$log_content" | grep -iEc "rate.*limit|too.*many.*requests|429" || echo "0")
    XILRIWS_TIMEOUT=$(echo "$log_content" | grep -iEc "timeout|timed.*out|ETIMEDOUT" || echo "0")
    XILRIWS_CONN_REFUSED=$(echo "$log_content" | grep -iEc "connection.*refused|ECONNREFUSED" || echo "0")
    XILRIWS_PROXY_ERROR=$(echo "$log_content" | grep -iEc "proxy.*error|proxy.*failed|bad.*proxy" || echo "0")
    XILRIWS_TOTAL_ERRORS=$(echo "$log_content" | grep -iEc "error|failed|exception" || echo "0")
    
    # Calculate other errors
    local known_errors=$((XILRIWS_AUTH_BANNED + XILRIWS_INVALID_CRED + XILRIWS_TUNNEL_ERROR + XILRIWS_CODE_15 + XILRIWS_PERM_BANNED + XILRIWS_RATE_LIMIT + XILRIWS_TIMEOUT + XILRIWS_CONN_REFUSED + XILRIWS_PROXY_ERROR))
    XILRIWS_OTHER_ERRORS=$((XILRIWS_TOTAL_ERRORS - known_errors))
    [ "$XILRIWS_OTHER_ERRORS" -lt 0 ] && XILRIWS_OTHER_ERRORS=0
    
    return 0
}

# Find IPs that appear banned in logs
get_banned_ips_from_logs() {
    local container="xilriws"
    # Look for IP patterns associated with ban messages
    docker logs "$container" 2>&1 | grep -iE "banned.*([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9]{1,3}\.){3}[0-9]{1,3}.*banned" | \
        grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | sort | uniq -c | sort -rn
}

# Find IPs with many failures and no success
get_failing_ips() {
    local container="xilriws"
    local threshold=${1:-25}
    local proxy_file="proxy.txt"
    
    if [ ! -f "$proxy_file" ]; then
        echo "proxy.txt not found"
        return 1
    fi
    
    # Get IPs from logs with failure counts
    local failing_ips=$(docker logs "$container" 2>&1 | grep -iE "error|failed|timeout|refused" | \
        grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | sort | uniq -c | sort -rn | \
        awk -v thresh="$threshold" '$1 >= thresh {print $2}')
    
    # Get IPs with successful logins
    local success_ips=$(docker logs "$container" 2>&1 | grep -iE "success|obtained.*cookie" | \
        grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | sort -u)
    
    # Return IPs that have failures but no successes
    echo "$failing_ips" | while read ip; do
        if [ -n "$ip" ] && ! echo "$success_ips" | grep -q "^$ip$"; then
            # Check if IP is in proxy.txt
            if grep -q "$ip" "$proxy_file" 2>/dev/null; then
                local count=$(docker logs "$container" 2>&1 | grep -E "error|failed" | grep -c "$ip" 2>/dev/null || echo "0")
                echo "$ip ($count failures)"
            fi
        fi
    done
}

# Show Xilriws status dashboard
show_xilriws_status() {
    clear
    echo ""
    draw_box_top
    draw_box_line "                    XILRIWS STATUS DASHBOARD"
    draw_box_bottom
    echo ""
    
    local status=$(get_container_status "xilriws")
    
    if [ "$status" = "not_found" ]; then
        echo -e "  ${RED}Xilriws container not found${NC}"
        press_enter
        return
    fi
    
    if [ "$status" = "stopped" ]; then
        echo -e "  ${RED}Xilriws container is not running${NC}"
        echo ""
        read -p "  Would you like to start it? (y/n): " start_it
        if [ "$start_it" = "y" ]; then
            docker start xilriws
            print_success "Container started"
            sleep 2
        else
            press_enter
            return
        fi
    fi
    
    echo -e "  ${CYAN}Analyzing Xilriws logs...${NC}"
    
    # Get stats
    get_xilriws_stats
    
    # Get log size
    local log_size=$(get_log_size "xilriws")
    local log_size_fmt=$(format_bytes "$log_size")
    
    # Get uptime
    local uptime=$(docker ps --filter "name=xilriws" --format "{{.Status}}" 2>/dev/null | head -1)
    
    clear
    echo ""
    draw_box_top
    draw_box_line "                    XILRIWS STATUS DASHBOARD"
    draw_box_divider
    
    printf "${CYAN}║${NC}  Container Status: ${GREEN}%-53s${NC} ${CYAN}║${NC}\n" "$uptime"
    printf "${CYAN}║${NC}  Log Size:         %-54s ${CYAN}║${NC}\n" "$log_size_fmt"
    
    draw_box_divider
    draw_box_line "  LOGIN STATISTICS"
    draw_box_divider
    
    printf "${CYAN}║${NC}    ${GREEN}✓ Successful Logins:${NC}    %-49s ${CYAN}║${NC}\n" "$XILRIWS_SUCCESS"
    printf "${CYAN}║${NC}    ${RED}✗ Auth-Banned:${NC}           %-49s ${CYAN}║${NC}\n" "$XILRIWS_AUTH_BANNED"
    printf "${CYAN}║${NC}    ${RED}✗ Invalid Credentials:${NC}   %-49s ${CYAN}║${NC}\n" "$XILRIWS_INVALID_CRED"
    
    draw_box_divider
    draw_box_line "  ERROR BREAKDOWN"
    draw_box_divider
    
    printf "${CYAN}║${NC}    ${YELLOW}⚠ Tunneling Errors:${NC}      %-49s ${CYAN}║${NC}\n" "$XILRIWS_TUNNEL_ERROR"
    printf "${CYAN}║${NC}    ${YELLOW}⚠ Code 15 Errors:${NC}        %-49s ${CYAN}║${NC}\n" "$XILRIWS_CODE_15"
    printf "${CYAN}║${NC}    ${YELLOW}⚠ Rate Limited:${NC}          %-49s ${CYAN}║${NC}\n" "$XILRIWS_RATE_LIMIT"
    printf "${CYAN}║${NC}    ${YELLOW}⚠ Timeouts:${NC}              %-49s ${CYAN}║${NC}\n" "$XILRIWS_TIMEOUT"
    printf "${CYAN}║${NC}    ${YELLOW}⚠ Connection Refused:${NC}    %-49s ${CYAN}║${NC}\n" "$XILRIWS_CONN_REFUSED"
    printf "${CYAN}║${NC}    ${YELLOW}⚠ Proxy Errors:${NC}          %-49s ${CYAN}║${NC}\n" "$XILRIWS_PROXY_ERROR"
    printf "${CYAN}║${NC}    ${RED}✗ Permanently Banned IPs:${NC} %-49s ${CYAN}║${NC}\n" "$XILRIWS_PERM_BANNED"
    printf "${CYAN}║${NC}    ${DIM}○ Other Errors:${NC}          %-49s ${CYAN}║${NC}\n" "$XILRIWS_OTHER_ERRORS"
    
    draw_box_divider
    printf "${CYAN}║${NC}    ${WHITE}TOTAL ERRORS:${NC}            %-49s ${CYAN}║${NC}\n" "$XILRIWS_TOTAL_ERRORS"
    
    # Calculate success rate
    local total_attempts=$((XILRIWS_SUCCESS + XILRIWS_AUTH_BANNED + XILRIWS_INVALID_CRED))
    if [ "$total_attempts" -gt 0 ]; then
        local success_rate=$((XILRIWS_SUCCESS * 100 / total_attempts))
        printf "${CYAN}║${NC}    ${WHITE}Success Rate:${NC}            %-49s ${CYAN}║${NC}\n" "${success_rate}%"
    fi
    
    draw_box_bottom
    echo ""
}

# Xilriws menu
show_xilriws_menu() {
    while true; do
        show_xilriws_status
        
        echo -e "${WHITE}${BOLD}Xilriws Options${NC}"
        echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
        echo "    1) View recent errors"
        echo "    2) Live monitoring mode (auto-restart on failure)"
        echo "    3) Clear Xilriws logs"
        echo "    4) Restart Xilriws container"
        echo "    p) Proxy Manager"
        echo "    r) Refresh"
        echo "    0) Back to main menu"
        echo ""
        read -p "  Select option: " choice
        
        case $choice in
            1) view_xilriws_errors ;;
            2) xilriws_live_monitor ;;
            3) clear_xilriws_logs ;;
            4) restart_xilriws ;;
            p|P) show_proxy_manager ;;
            r|R) continue ;;
            0) return ;;
        esac
    done
}

# =============================================================================
# PROXY MANAGER
# =============================================================================

# Extract IP or domain from proxy line
get_proxy_identifier() {
    local line=$1
    # Handle formats like: ip:port, user:pass@ip:port, protocol://ip:port, etc.
    # Extract the IP or domain portion
    local identifier=$(echo "$line" | sed -E 's|^[^:]+://||' | sed -E 's|^[^@]+@||' | sed -E 's|:[0-9]+.*$||' | sed -E 's|^([0-9]+\.[0-9]+\.[0-9]+)\..*|\1|')
    echo "$identifier"
}

# Get domain/subnet prefix for grouping (first 3 octets for IP, or domain)
get_proxy_group() {
    local line=$1
    local identifier=$(get_proxy_identifier "$line")
    
    # Check if it's an IP address
    if [[ "$identifier" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Return first 3 octets as the group
        echo "$identifier"
    elif [[ "$identifier" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Full IP - return first 3 octets
        echo "$identifier" | sed -E 's|\.[0-9]+$||'
    else
        # Domain - return the domain itself
        echo "$identifier"
    fi
}

# Randomize proxy list avoiding consecutive same-group entries
randomize_proxy_list() {
    local proxy_file="proxy.txt"
    
    if [ ! -f "$proxy_file" ]; then
        print_error "proxy.txt not found"
        return 1
    fi
    
    local total_lines=$(wc -l < "$proxy_file")
    
    if [ "$total_lines" -lt 2 ]; then
        print_warning "Not enough proxies to randomize"
        return 1
    fi
    
    print_info "Analyzing $total_lines proxies..."
    
    # Read all proxies and their groups into arrays
    declare -a proxies
    declare -a groups
    declare -A group_counts
    
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        proxies+=("$line")
        local group=$(get_proxy_group "$line")
        groups+=("$group")
        ((group_counts["$group"]++))
    done < "$proxy_file"
    
    local num_proxies=${#proxies[@]}
    local num_groups=${#group_counts[@]}
    
    echo "  Found $num_proxies proxies in $num_groups groups/subnets"
    echo ""
    
    # Show top groups
    echo -e "${CYAN}Top proxy groups/subnets:${NC}"
    for group in "${!group_counts[@]}"; do
        echo "  $group: ${group_counts[$group]} proxies"
    done | sort -t: -k2 -rn | head -10
    echo ""
    
    # Create shuffled result avoiding consecutive same-group
    declare -a result
    declare -a remaining_indices
    
    # Initialize remaining indices
    for ((i=0; i<num_proxies; i++)); do
        remaining_indices+=($i)
    done
    
    # Shuffle the remaining indices first (Fisher-Yates)
    for ((i=${#remaining_indices[@]}-1; i>0; i--)); do
        local j=$((RANDOM % (i+1)))
        local temp=${remaining_indices[$i]}
        remaining_indices[$i]=${remaining_indices[$j]}
        remaining_indices[$j]=$temp
    done
    
    local last_group=""
    local stuck_count=0
    local max_stuck=100
    
    while [ ${#remaining_indices[@]} -gt 0 ]; do
        local found=false
        local best_idx=-1
        
        # Try to find a proxy from a different group
        for ((i=0; i<${#remaining_indices[@]}; i++)); do
            local idx=${remaining_indices[$i]}
            local this_group=${groups[$idx]}
            
            if [ "$this_group" != "$last_group" ] || [ ${#remaining_indices[@]} -eq 1 ]; then
                best_idx=$i
                found=true
                break
            fi
        done
        
        # If all remaining are same group, just take the first one
        if [ "$found" = false ]; then
            best_idx=0
            ((stuck_count++))
        fi
        
        # Add to result
        local selected_idx=${remaining_indices[$best_idx]}
        result+=("${proxies[$selected_idx]}")
        last_group=${groups[$selected_idx]}
        
        # Remove from remaining
        unset 'remaining_indices[$best_idx]'
        remaining_indices=("${remaining_indices[@]}")
        
        # Safety check
        if [ $stuck_count -gt $max_stuck ]; then
            print_warning "Could not avoid all consecutive duplicates (too many same-group proxies)"
            # Just append the rest
            for idx in "${remaining_indices[@]}"; do
                result+=("${proxies[$idx]}")
            done
            break
        fi
    done
    
    # Count how many consecutive same-group pairs we have
    local consecutive_same=0
    local prev_group=""
    for ((i=0; i<${#result[@]}; i++)); do
        local this_group=$(get_proxy_group "${result[$i]}")
        if [ "$this_group" = "$prev_group" ]; then
            ((consecutive_same++))
        fi
        prev_group=$this_group
    done
    
    echo ""
    echo "  Randomization complete:"
    echo "  - Total proxies: ${#result[@]}"
    echo "  - Unavoidable consecutive same-group: $consecutive_same"
    echo ""
    
    # Write result
    printf '%s\n' "${result[@]}" > "${proxy_file}.new"
    
    # Backup and replace
    cp "$proxy_file" "${proxy_file}.backup.$(date +%Y%m%d_%H%M%S)"
    mv "${proxy_file}.new" "$proxy_file"
    
    # Restore ownership
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        chown "$REAL_USER:$REAL_GROUP" "$proxy_file" 2>/dev/null || true
        chown "$REAL_USER:$REAL_GROUP" "${proxy_file}.backup."* 2>/dev/null || true
    fi
    
    print_success "Proxy list randomized! Backup created."
    return 0
}

# Show proxy statistics
show_proxy_stats() {
    local proxy_file="proxy.txt"
    
    clear
    echo ""
    draw_box_top
    draw_box_line "                    PROXY.TXT STATISTICS"
    draw_box_bottom
    echo ""
    
    if [ ! -f "$proxy_file" ]; then
        print_error "proxy.txt not found in current directory"
        press_enter
        return
    fi
    
    local total=$(wc -l < "$proxy_file")
    local unique_ips=$(cat "$proxy_file" | sed -E 's|^[^:]+://||' | sed -E 's|^[^@]+@||' | sed -E 's|:[0-9]+.*$||' | sort -u | wc -l)
    local file_size=$(stat -c%s "$proxy_file" 2>/dev/null || stat -f%z "$proxy_file" 2>/dev/null)
    local file_size_fmt=$(format_bytes "$file_size")
    
    echo -e "  ${CYAN}File:${NC}          $proxy_file"
    echo -e "  ${CYAN}Size:${NC}          $file_size_fmt"
    echo -e "  ${CYAN}Total Lines:${NC}   $total"
    echo -e "  ${CYAN}Unique IPs:${NC}    $unique_ips"
    echo ""
    
    # Group analysis
    echo -e "${WHITE}${BOLD}Proxy Groups/Subnets:${NC}"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    
    declare -A group_counts
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        local group=$(get_proxy_group "$line")
        ((group_counts["$group"]++))
    done < "$proxy_file"
    
    echo "  Top 15 groups by count:"
    for group in "${!group_counts[@]}"; do
        echo "  $group: ${group_counts[$group]}"
    done | sort -t: -k2 -rn | head -15
    
    echo ""
    echo -e "  ${CYAN}Total unique groups:${NC} ${#group_counts[@]}"
    
    # Check for consecutive same-group
    local consecutive=0
    local prev_group=""
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        local this_group=$(get_proxy_group "$line")
        if [ "$this_group" = "$prev_group" ]; then
            ((consecutive++))
        fi
        prev_group=$this_group
    done < "$proxy_file"
    
    echo -e "  ${CYAN}Consecutive same-group pairs:${NC} $consecutive"
    
    press_enter
}

# Proxy Manager Menu
show_proxy_manager() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "                    XILRIWS PROXY MANAGER"
        draw_box_bottom
        echo ""
        
        local proxy_file="proxy.txt"
        if [ -f "$proxy_file" ]; then
            local total=$(wc -l < "$proxy_file")
            local file_size=$(stat -c%s "$proxy_file" 2>/dev/null || stat -f%z "$proxy_file" 2>/dev/null)
            local file_size_fmt=$(format_bytes "$file_size")
            echo -e "  ${GREEN}✓${NC} proxy.txt found: ${CYAN}$total${NC} proxies (${file_size_fmt})"
        else
            echo -e "  ${RED}✗${NC} proxy.txt not found"
        fi
        
        # Show banned/failing counts from logs
        local status=$(get_container_status "xilriws")
        if [ "$status" = "running" ]; then
            local banned=$(docker logs xilriws 2>&1 | grep -iEc "permanently.*banned|permanent.*ban|IP.*banned" || echo "0")
            local failing=$(get_failing_ips 25 2>/dev/null | grep -c "." || echo "0")
            echo -e "  ${YELLOW}⚠${NC} Banned IPs detected in logs: ${RED}$banned${NC}"
            echo -e "  ${YELLOW}⚠${NC} Failing proxies (25+ failures): ${RED}$failing${NC}"
        fi
        
        echo ""
        echo -e "${WHITE}${BOLD}Proxy Management Options${NC}"
        echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
        echo "    1) View proxy statistics"
        echo "    2) Randomize proxy list (avoids consecutive same-IP/domain)"
        echo "    3) View banned IP addresses from logs"
        echo "    4) Find failing proxies (configurable threshold)"
        echo "    5) Remove banned IPs from proxy.txt"
        echo "    6) Remove failing proxies from proxy.txt"
        echo "    7) Remove duplicate proxies"
        echo "    8) View first/last 10 proxies"
        echo "    0) Back to Xilriws menu"
        echo ""
        read -p "  Select option: " choice
        
        case $choice in
            1) show_proxy_stats ;;
            2) randomize_proxies_menu ;;
            3) view_banned_ips ;;
            4) find_failing_proxies ;;
            5) remove_banned_ips ;;
            6) remove_failing_proxies ;;
            7) remove_duplicate_proxies ;;
            8) view_proxy_sample ;;
            0) return ;;
        esac
    done
}

# Randomize proxies menu
randomize_proxies_menu() {
    clear
    echo ""
    draw_box_top
    draw_box_line "                    RANDOMIZE PROXY LIST"
    draw_box_bottom
    echo ""
    
    local proxy_file="proxy.txt"
    
    if [ ! -f "$proxy_file" ]; then
        print_error "proxy.txt not found"
        press_enter
        return
    fi
    
    echo "  This will shuffle your proxy list while trying to avoid placing"
    echo "  two proxies from the same IP range or domain consecutively."
    echo ""
    echo "  This helps distribute load and avoid detection patterns."
    echo ""
    echo -e "  ${YELLOW}A backup will be created before modification.${NC}"
    echo ""
    
    read -p "  Proceed with randomization? (y/n): " confirm
    
    if [ "$confirm" = "y" ]; then
        echo ""
        randomize_proxy_list
    else
        print_info "Operation cancelled"
    fi
    
    press_enter
}

# Remove duplicate proxies
remove_duplicate_proxies() {
    clear
    echo ""
    draw_box_top
    draw_box_line "                    REMOVE DUPLICATE PROXIES"
    draw_box_bottom
    echo ""
    
    local proxy_file="proxy.txt"
    
    if [ ! -f "$proxy_file" ]; then
        print_error "proxy.txt not found"
        press_enter
        return
    fi
    
    local total=$(wc -l < "$proxy_file")
    local unique=$(sort -u "$proxy_file" | wc -l)
    local duplicates=$((total - unique))
    
    echo "  Total proxies:     $total"
    echo "  Unique proxies:    $unique"
    echo "  Duplicates found:  $duplicates"
    echo ""
    
    if [ "$duplicates" -eq 0 ]; then
        echo -e "  ${GREEN}No duplicates found!${NC}"
        press_enter
        return
    fi
    
    echo -e "  ${YELLOW}$duplicates duplicate entries will be removed${NC}"
    echo ""
    
    read -p "  Proceed with removal? (y/n): " confirm
    
    if [ "$confirm" = "y" ]; then
        # Backup
        cp "$proxy_file" "${proxy_file}.backup.$(date +%Y%m%d_%H%M%S)"
        print_success "Backup created"
        
        # Remove duplicates while preserving order
        awk '!seen[$0]++' "$proxy_file" > "${proxy_file}.tmp"
        mv "${proxy_file}.tmp" "$proxy_file"
        
        # Restore ownership
        if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
            chown "$REAL_USER:$REAL_GROUP" "$proxy_file" 2>/dev/null || true
            chown "$REAL_USER:$REAL_GROUP" "${proxy_file}.backup."* 2>/dev/null || true
        fi
        
        local new_total=$(wc -l < "$proxy_file")
        print_success "Removed $duplicates duplicates. New total: $new_total"
    else
        print_info "Operation cancelled"
    fi
    
    press_enter
}

# View sample of proxies
view_proxy_sample() {
    clear
    echo ""
    draw_box_top
    draw_box_line "                    PROXY SAMPLE VIEW"
    draw_box_bottom
    echo ""
    
    local proxy_file="proxy.txt"
    
    if [ ! -f "$proxy_file" ]; then
        print_error "proxy.txt not found"
        press_enter
        return
    fi
    
    local total=$(wc -l < "$proxy_file")
    
    echo -e "${CYAN}First 10 proxies:${NC}"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    head -10 "$proxy_file" | nl
    
    echo ""
    echo -e "${CYAN}Last 10 proxies:${NC}"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    tail -10 "$proxy_file" | nl -v $((total - 9))
    
    echo ""
    echo -e "  ${DIM}Total: $total proxies${NC}"
    
    press_enter
}

# View recent Xilriws errors
view_xilriws_errors() {
    clear
    echo ""
    draw_box_top
    draw_box_line "                    XILRIWS RECENT ERRORS"
    draw_box_bottom
    echo ""
    
    echo -e "${CYAN}Last 50 error entries:${NC}"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    
    docker logs xilriws 2>&1 | grep -iE "error|failed|banned|invalid|timeout" | tail -50
    
    press_enter
}

# View banned IPs
view_banned_ips() {
    clear
    echo ""
    draw_box_top
    draw_box_line "                    BANNED IP ADDRESSES"
    draw_box_bottom
    echo ""
    
    echo -e "${CYAN}IPs associated with ban messages (count | IP):${NC}"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    
    local banned=$(get_banned_ips_from_logs)
    
    if [ -z "$banned" ]; then
        echo "  No banned IPs detected in logs"
    else
        echo "$banned" | head -30
        local total=$(echo "$banned" | wc -l)
        echo ""
        echo -e "  ${YELLOW}Total unique IPs with ban indicators: $total${NC}"
    fi
    
    press_enter
}

# Find failing proxies
find_failing_proxies() {
    clear
    echo ""
    draw_box_top
    draw_box_line "                    FAILING PROXIES"
    draw_box_bottom
    echo ""
    
    read -p "  Failure threshold (default 25): " threshold
    threshold=${threshold:-25}
    
    echo ""
    echo -e "${CYAN}IPs with $threshold+ failures and NO successful logins:${NC}"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    
    local failing=$(get_failing_ips "$threshold")
    
    if [ -z "$failing" ]; then
        echo "  No proxies found matching criteria"
    else
        echo "$failing"
        local total=$(echo "$failing" | grep -c "." || echo "0")
        echo ""
        echo -e "  ${YELLOW}Total failing proxies: $total${NC}"
    fi
    
    press_enter
}

# Remove banned IPs from proxy.txt
remove_banned_ips() {
    clear
    echo ""
    draw_box_top
    draw_box_line "                    REMOVE BANNED IPs"
    draw_box_bottom
    echo ""
    
    local proxy_file="proxy.txt"
    
    if [ ! -f "$proxy_file" ]; then
        print_error "proxy.txt not found in current directory"
        press_enter
        return
    fi
    
    # Get banned IPs
    local banned_ips=$(get_banned_ips_from_logs | awk '{print $2}')
    
    if [ -z "$banned_ips" ]; then
        echo "  No banned IPs detected in logs"
        press_enter
        return
    fi
    
    local count=$(echo "$banned_ips" | wc -l)
    echo -e "  Found ${RED}$count${NC} IPs with ban indicators"
    echo ""
    
    # Show IPs that would be removed
    echo -e "${CYAN}IPs to be removed from proxy.txt:${NC}"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    
    local found_in_proxy=0
    while IFS= read -r ip; do
        if [ -n "$ip" ] && grep -q "$ip" "$proxy_file" 2>/dev/null; then
            echo "  - $ip"
            ((found_in_proxy++))
        fi
    done <<< "$banned_ips"
    
    if [ "$found_in_proxy" -eq 0 ]; then
        echo "  None of the banned IPs are in proxy.txt"
        press_enter
        return
    fi
    
    echo ""
    echo -e "  ${YELLOW}$found_in_proxy IPs will be removed from proxy.txt${NC}"
    echo ""
    
    read -p "  Proceed with removal? (y/n): " confirm
    
    if [ "$confirm" = "y" ]; then
        # Backup
        cp "$proxy_file" "${proxy_file}.backup.$(date +%Y%m%d_%H%M%S)"
        print_success "Backup created"
        
        # Remove IPs
        local removed=0
        while IFS= read -r ip; do
            if [ -n "$ip" ]; then
                if grep -q "$ip" "$proxy_file" 2>/dev/null; then
                    sed -i "/$ip/d" "$proxy_file"
                    ((removed++))
                fi
            fi
        done <<< "$banned_ips"
        
        # Restore ownership
        if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
            chown "$REAL_USER:$REAL_GROUP" "$proxy_file" 2>/dev/null || true
            chown "$REAL_USER:$REAL_GROUP" "${proxy_file}.backup."* 2>/dev/null || true
        fi
        
        print_success "Removed $removed IPs from proxy.txt"
    else
        print_info "Operation cancelled"
    fi
    
    press_enter
}

# Remove failing proxies from proxy.txt
remove_failing_proxies() {
    clear
    echo ""
    draw_box_top
    draw_box_line "                    REMOVE FAILING PROXIES"
    draw_box_bottom
    echo ""
    
    local proxy_file="proxy.txt"
    
    if [ ! -f "$proxy_file" ]; then
        print_error "proxy.txt not found in current directory"
        press_enter
        return
    fi
    
    read -p "  Failure threshold (default 25): " threshold
    threshold=${threshold:-25}
    
    echo ""
    echo -e "${CYAN}Finding proxies with $threshold+ failures and no successful logins...${NC}"
    
    # Get failing IPs (just the IP part)
    local failing_ips=$(get_failing_ips "$threshold" | sed 's/ (.*//')
    
    if [ -z "$failing_ips" ]; then
        echo "  No failing proxies found matching criteria"
        press_enter
        return
    fi
    
    local count=$(echo "$failing_ips" | grep -c "." || echo "0")
    echo ""
    echo -e "  Found ${RED}$count${NC} failing proxies"
    echo ""
    
    # Show IPs that would be removed
    echo -e "${CYAN}Proxies to be removed:${NC}"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    echo "$failing_ips" | head -20
    [ "$count" -gt 20 ] && echo "  ... and $((count - 20)) more"
    echo ""
    
    read -p "  Proceed with removal? (y/n): " confirm
    
    if [ "$confirm" = "y" ]; then
        # Backup
        cp "$proxy_file" "${proxy_file}.backup.$(date +%Y%m%d_%H%M%S)"
        print_success "Backup created"
        
        # Remove IPs
        local removed=0
        while IFS= read -r ip; do
            if [ -n "$ip" ]; then
                if grep -q "$ip" "$proxy_file" 2>/dev/null; then
                    sed -i "/$ip/d" "$proxy_file"
                    ((removed++))
                fi
            fi
        done <<< "$failing_ips"
        
        # Restore ownership
        if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
            chown "$REAL_USER:$REAL_GROUP" "$proxy_file" 2>/dev/null || true
            chown "$REAL_USER:$REAL_GROUP" "${proxy_file}.backup."* 2>/dev/null || true
        fi
        
        print_success "Removed $removed proxies from proxy.txt"
    else
        print_info "Operation cancelled"
    fi
    
    press_enter
}

# Clear Xilriws logs
clear_xilriws_logs() {
    echo ""
    read -p "  Clear Xilriws logs? (y/n): " confirm
    if [ "$confirm" = "y" ]; then
        local log_path=$(docker inspect --format='{{.LogPath}}' xilriws 2>/dev/null)
        if [ -n "$log_path" ] && [ -f "$log_path" ]; then
            sudo truncate -s 0 "$log_path"
            print_success "Xilriws logs cleared"
        else
            print_error "Could not find log file"
        fi
    fi
    sleep 1
}

# Restart Xilriws
restart_xilriws() {
    echo ""
    read -p "  Restart Xilriws container? (y/n): " confirm
    if [ "$confirm" = "y" ]; then
        print_info "Restarting Xilriws..."
        docker restart xilriws
        if [ $? -eq 0 ]; then
            print_success "Xilriws restarted successfully"
        else
            print_error "Failed to restart Xilriws"
        fi
    fi
    sleep 2
}

# Xilriws critical error pattern - from actual Xilriws logs
# The exact message is: "30 consecutive failures in the browser! this is really bad"
# Log format: "06:50:25.23 | C | Browser    | 30 consecutive failures in the browser! this is really bad"
XILRIWS_CRITICAL_PATTERN="30 consecutive failures in the browser"

# Xilriws live monitoring mode
xilriws_live_monitor() {
    clear
    echo ""
    draw_box_top
    draw_box_line "             XILRIWS LIVE MONITORING MODE"
    draw_box_divider
    draw_box_line "  This mode monitors Xilriws logs in real-time and will:"
    draw_box_line "    • Display live statistics"
    draw_box_line "    • Watch for the critical error message:"
    draw_box_line "      '30 consecutive failures in the browser! this is really bad'"
    draw_box_line "    • Auto-restart container when this message appears"
    draw_box_line ""
    draw_box_line "  This message from Xilriws means it has stopped attempting"
    draw_box_line "  to use proxies entirely and needs a restart to recover."
    draw_box_line ""
    draw_box_line "  Press Ctrl+C to exit monitoring mode"
    draw_box_bottom
    echo ""
    
    read -p "  Start live monitoring? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        return
    fi
    
    echo ""
    print_info "Starting live monitor... (Ctrl+C to stop)"
    sleep 2
    
    local session_start=$(date +%s)
    local last_restart_check=""
    local restart_count=0
    
    # Get initial count of the critical message to establish baseline
    # Pattern: "30 consecutive failures in the browser! this is really bad"
    local initial_failure_count=$(docker logs xilriws 2>&1 | grep -ic "30 consecutive failures in the browser" || echo "0")
    
    # Trap Ctrl+C
    trap 'echo ""; print_info "Monitoring stopped"; sleep 1; return' INT
    
    # Clear screen and start monitoring
    while true; do
        clear
        local current_time=$(date "+%Y-%m-%d %H:%M:%S")
        local uptime_secs=$(($(date +%s) - session_start))
        local uptime_mins=$((uptime_secs / 60))
        
        echo ""
        draw_box_top
        printf "${CYAN}║${NC} %-30s %43s ${CYAN}║${NC}\n" "XILRIWS LIVE MONITOR" "$current_time"
        draw_box_divider
        
        # Get current stats
        get_xilriws_stats 2>/dev/null
        
        local status=$(get_container_status "xilriws")
        local status_color="${GREEN}"
        [ "$status" != "running" ] && status_color="${RED}"
        
        # Count critical messages in log
        local current_failure_count=$(docker logs xilriws 2>&1 | grep -ic "30 consecutive failures in the browser" || echo "0")
        local new_failures=$((current_failure_count - initial_failure_count))
        [ "$new_failures" -lt 0 ] && new_failures=0
        
        printf "${CYAN}║${NC}  Container:          ${status_color}%-52s${NC} ${CYAN}║${NC}\n" "$status"
        printf "${CYAN}║${NC}  Monitor Uptime:     %-53s ${CYAN}║${NC}\n" "${uptime_mins}m $((uptime_secs % 60))s"
        printf "${CYAN}║${NC}  Auto-Restarts:      %-53s ${CYAN}║${NC}\n" "$restart_count"
        
        # Show failure message detection status
        printf "${CYAN}║${NC}  "
        if [ "$new_failures" -gt 0 ]; then
            printf "${RED}⚠ CRITICAL MESSAGE DETECTED: $new_failures times (since start)${NC}"
            printf "%*s" $((42 - ${#new_failures})) ""
        else
            printf "${GREEN}✓ No critical failure message detected${NC}%35s" ""
        fi
        printf " ${CYAN}║${NC}\n"
        
        draw_box_divider
        draw_box_line "  SESSION STATISTICS (from all logs)"
        draw_box_divider
        
        printf "${CYAN}║${NC}    ${GREEN}✓ Successful:${NC}     %-55s ${CYAN}║${NC}\n" "$XILRIWS_SUCCESS"
        printf "${CYAN}║${NC}    ${RED}✗ Auth-Banned:${NC}    %-55s ${CYAN}║${NC}\n" "$XILRIWS_AUTH_BANNED"
        printf "${CYAN}║${NC}    ${RED}✗ Invalid Creds:${NC}  %-55s ${CYAN}║${NC}\n" "$XILRIWS_INVALID_CRED"
        printf "${CYAN}║${NC}    ${YELLOW}⚠ Tunnel Errors:${NC} %-55s ${CYAN}║${NC}\n" "$XILRIWS_TUNNEL_ERROR"
        printf "${CYAN}║${NC}    ${YELLOW}⚠ Code 15:${NC}       %-55s ${CYAN}║${NC}\n" "$XILRIWS_CODE_15"
        printf "${CYAN}║${NC}    ${YELLOW}⚠ Total Errors:${NC}  %-55s ${CYAN}║${NC}\n" "$XILRIWS_TOTAL_ERRORS"
        
        draw_box_divider
        draw_box_line "  WATCHING FOR: '30 consecutive failures in the browser!'"
        draw_box_divider
        
        # Get last 5 log entries
        local recent_logs=$(docker logs xilriws --tail 5 2>&1)
        while IFS= read -r line; do
            # Truncate long lines and highlight the critical message
            local short_line="${line:0:72}"
            if echo "$line" | grep -qi "30 consecutive failures in the browser"; then
                printf "${CYAN}║${NC}  ${RED}${BOLD}%-73s${NC} ${CYAN}║${NC}\n" "$short_line"
            elif echo "$line" | grep -qi "this is really bad"; then
                printf "${CYAN}║${NC}  ${RED}${BOLD}%-73s${NC} ${CYAN}║${NC}\n" "$short_line"
            elif echo "$line" | grep -qiE "error|failed|banned"; then
                printf "${CYAN}║${NC}  ${YELLOW}%-73s${NC} ${CYAN}║${NC}\n" "$short_line"
            else
                printf "${CYAN}║${NC}  %-73s ${CYAN}║${NC}\n" "$short_line"
            fi
        done <<< "$recent_logs"
        
        draw_box_bottom
        
        # Check for the specific critical message in recent logs
        # Xilriws outputs: "30 consecutive failures in the browser! this is really bad"
        # This message means Xilriws has stopped trying to use proxies
        local recent_check=$(docker logs xilriws --tail 50 2>&1)
        
        if echo "$recent_check" | grep -qi "30 consecutive failures in the browser"; then
            # Make sure we haven't just restarted for this same occurrence
            local latest_failure_line=$(echo "$recent_check" | grep -i "30 consecutive failures in the browser" | tail -1)
            
            if [ "$latest_failure_line" != "$last_restart_check" ]; then
                echo ""
                echo -e "  ${RED}╔════════════════════════════════════════════════════════════════════╗${NC}"
                echo -e "  ${RED}║   ⚠️  CRITICAL XILRIWS ERROR DETECTED! ⚠️                           ║${NC}"
                echo -e "  ${RED}║                                                                    ║${NC}"
                echo -e "  ${RED}║   '30 consecutive failures in the browser! this is really bad'    ║${NC}"
                echo -e "  ${RED}║                                                                    ║${NC}"
                echo -e "  ${RED}║   Xilriws has stopped attempting to use proxies.                  ║${NC}"
                echo -e "  ${RED}║   Auto-restarting container to recover...                         ║${NC}"
                echo -e "  ${RED}╚════════════════════════════════════════════════════════════════════╝${NC}"
                echo ""
                
                print_warning "Restarting Xilriws container..."
                docker restart xilriws
                
                if [ $? -eq 0 ]; then
                    print_success "Container restarted successfully"
                    last_restart_check="$latest_failure_line"
                    ((restart_count++))
                    # Reset baseline after restart
                    sleep 3
                    initial_failure_count=$(docker logs xilriws 2>&1 | grep -ic "30 consecutive failures in the browser" || echo "0")
                else
                    print_error "Failed to restart container!"
                fi
                
                sleep 5
            fi
        fi
        
        # Wait before next refresh
        sleep 3
    done
    
    trap - INT
}

# =============================================================================
# QUICK ANALYSIS
# =============================================================================

quick_health_check() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              QUICK HEALTH CHECK"
    draw_box_bottom
    echo ""

    echo -e "${WHITE}${BOLD}Analyzing all services...${NC}"
    echo ""

    local issues=0

    for service in "${SERVICES[@]}"; do
        local status=$(get_container_status "$service")
        
        if [ "$status" = "running" ]; then
            local errors=$(count_total_errors "$service")
            local critical=$(count_errors_by_pattern "$service" "fatal|panic|critical")
            local db_errors=$(count_errors_by_pattern "$service" "${ERROR_PATTERNS[database]}")
            local conn_errors=$(count_errors_by_pattern "$service" "${ERROR_PATTERNS[connection]}")
            
            local has_issues=false
            
            if [ "$critical" -gt 0 ] 2>/dev/null; then
                echo -e "  ${RED}✗${NC} $service: ${RED}$critical critical error(s)${NC}"
                has_issues=true
                ((issues++))
            fi
            
            if [ "$db_errors" -gt 10 ] 2>/dev/null; then
                echo -e "  ${YELLOW}!${NC} $service: ${YELLOW}$db_errors database error(s)${NC}"
                has_issues=true
            fi
            
            if [ "$conn_errors" -gt 20 ] 2>/dev/null; then
                echo -e "  ${YELLOW}!${NC} $service: ${YELLOW}$conn_errors connection error(s)${NC}"
                has_issues=true
            fi
            
            if [ "$has_issues" = false ]; then
                echo -e "  ${GREEN}✓${NC} $service: OK"
            fi
        elif [ "$status" = "stopped" ]; then
            echo -e "  ${RED}✗${NC} $service: ${RED}Not running${NC}"
            ((issues++))
        fi
    done

    echo ""
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    
    if [ $issues -eq 0 ]; then
        echo -e "  ${GREEN}All services healthy!${NC}"
    else
        echo -e "  ${RED}$issues issue(s) detected${NC}"
    fi

    press_enter
}

# =============================================================================
# LOG SEARCH
# =============================================================================

# Search logs across all containers
search_all_logs() {
    local keyword=$1
    local context=${2:-3}
    
    clear
    echo ""
    draw_box_top
    draw_box_line "                    SEARCH ALL LOGS: \"$keyword\""
    draw_box_bottom
    echo ""
    
    local total_matches=0
    local containers_with_matches=0
    local temp_results=$(mktemp)
    
    echo -e "${CYAN}Searching all container logs...${NC}"
    echo ""
    
    for service in "${SERVICES[@]}"; do
        local status=$(get_container_status "$service")
        if [ "$status" = "running" ] || [ "$status" = "stopped" ]; then
            local count=$(docker logs "$service" 2>&1 | grep -ic "$keyword" 2>/dev/null || echo "0")
            if [ "$count" -gt 0 ] 2>/dev/null; then
                echo "$service:$count" >> "$temp_results"
                ((total_matches += count))
                ((containers_with_matches++))
            fi
        fi
    done
    
    if [ "$total_matches" -eq 0 ]; then
        echo -e "  ${YELLOW}No matches found for \"$keyword\"${NC}"
        rm -f "$temp_results"
        press_enter
        return
    fi
    
    echo -e "${WHITE}${BOLD}Search Results Summary${NC}"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "  Total matches: ${GREEN}$total_matches${NC} across ${GREEN}$containers_with_matches${NC} container(s)"
    echo ""
    
    # Show breakdown by container
    echo -e "${WHITE}${BOLD}Matches by Container:${NC}"
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    
    local i=1
    local containers_array=()
    while IFS=: read -r container count; do
        printf "  %2d) %-20s %s matches\n" "$i" "$container" "$count"
        containers_array+=("$container")
        ((i++))
    done < "$temp_results"
    
    echo ""
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    echo "  v) View all matches (first 100)"
    echo "  #) Enter number to view specific container's matches"
    echo "  0) Back"
    echo ""
    read -p "  Select option: " choice
    
    case $choice in
        v|V)
            view_search_results_all "$keyword" "$context"
            ;;
        [1-9]|[1-9][0-9])
            if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#containers_array[@]}" ] 2>/dev/null; then
                local selected="${containers_array[$((choice-1))]}"
                view_search_results_container "$selected" "$keyword" "$context"
            fi
            ;;
        0|"")
            ;;
        *)
            ;;
    esac
    
    rm -f "$temp_results"
}

# View search results from all containers
view_search_results_all() {
    local keyword=$1
    local context=${2:-3}
    
    clear
    echo ""
    draw_box_top
    draw_box_line "                    ALL MATCHES: \"$keyword\""
    draw_box_bottom
    echo ""
    
    local temp_output=$(mktemp)
    
    for service in "${SERVICES[@]}"; do
        local status=$(get_container_status "$service")
        if [ "$status" = "running" ] || [ "$status" = "stopped" ]; then
            local matches=$(docker logs "$service" 2>&1 | grep -i "$keyword" 2>/dev/null | head -20)
            if [ -n "$matches" ]; then
                echo -e "${CYAN}━━━ $service ━━━${NC}" >> "$temp_output"
                echo "$matches" >> "$temp_output"
                echo "" >> "$temp_output"
            fi
        fi
    done
    
    # Use less for pagination if available
    if command -v less &> /dev/null; then
        less -R "$temp_output"
    else
        cat "$temp_output"
        press_enter
    fi
    
    rm -f "$temp_output"
}

# View search results from a specific container
view_search_results_container() {
    local container=$1
    local keyword=$2
    local context=${3:-3}
    
    clear
    echo ""
    draw_box_top
    draw_box_line "                    MATCHES IN: $container"
    draw_box_line "                    Keyword: \"$keyword\""
    draw_box_bottom
    echo ""
    
    local temp_output=$(mktemp)
    
    # Get matches with context
    docker logs "$container" 2>&1 | grep -i -B"$context" -A"$context" --color=always "$keyword" > "$temp_output" 2>/dev/null || true
    
    local match_count=$(docker logs "$container" 2>&1 | grep -ic "$keyword" 2>/dev/null || echo "0")
    
    echo -e "  Found ${GREEN}$match_count${NC} matches (showing with $context lines context)"
    echo ""
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    
    # Use less for pagination if available
    if command -v less &> /dev/null; then
        less -R "$temp_output"
    else
        head -200 "$temp_output"
        if [ "$match_count" -gt 50 ]; then
            echo ""
            echo -e "${YELLOW}(Showing first ~200 lines. Use less for full output)${NC}"
        fi
        press_enter
    fi
    
    rm -f "$temp_output"
}

# Search a specific container's logs
search_container_logs() {
    local container=$1
    local keyword=$2
    local context=${3:-3}
    
    clear
    echo ""
    draw_box_top
    draw_box_line "                    SEARCH: $container"
    draw_box_line "                    Keyword: \"$keyword\""
    draw_box_bottom
    echo ""
    
    local match_count=$(docker logs "$container" 2>&1 | grep -ic "$keyword" 2>/dev/null || echo "0")
    
    if [ "$match_count" -eq 0 ]; then
        echo -e "  ${YELLOW}No matches found for \"$keyword\" in $container${NC}"
        press_enter
        return
    fi
    
    echo -e "  Found ${GREEN}$match_count${NC} matches"
    echo ""
    echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    local temp_output=$(mktemp)
    docker logs "$container" 2>&1 | grep -i -B"$context" -A"$context" --color=always "$keyword" > "$temp_output" 2>/dev/null || true
    
    # Use less for pagination if available
    if command -v less &> /dev/null; then
        less -R "$temp_output"
    else
        head -200 "$temp_output"
        if [ "$match_count" -gt 50 ]; then
            echo ""
            echo -e "${YELLOW}(Showing first ~200 lines)${NC}"
        fi
        press_enter
    fi
    
    rm -f "$temp_output"
}

# Main search menu
search_logs_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "                    LOG SEARCH"
        draw_box_bottom
        echo ""
        
        echo -e "${WHITE}${BOLD}Search Options${NC}"
        echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo "  1) Search all containers"
        echo "  2) Search specific container"
        echo ""
        echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
        echo "  0) Back to main menu"
        echo ""
        read -p "  Select option: " choice
        
        case $choice in
            1)
                echo ""
                read -p "  Enter search keyword: " keyword
                if [ -n "$keyword" ]; then
                    read -p "  Context lines (default 3): " ctx
                    ctx=${ctx:-3}
                    search_all_logs "$keyword" "$ctx"
                fi
                ;;
            2)
                echo ""
                echo -e "${WHITE}${BOLD}Available Containers:${NC}"
                echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
                local i=1
                for service in "${SERVICES[@]}"; do
                    local status=$(get_container_status "$service")
                    local status_color="${GREEN}"
                    [ "$status" != "running" ] && status_color="${RED}"
                    printf "  %2d) %-20s [${status_color}%s${NC}]\n" "$i" "$service" "$status"
                    ((i++))
                done
                echo ""
                read -p "  Select container (1-${#SERVICES[@]}): " container_choice
                
                if [ "$container_choice" -ge 1 ] 2>/dev/null && [ "$container_choice" -le "${#SERVICES[@]}" ] 2>/dev/null; then
                    local selected="${SERVICES[$((container_choice-1))]}"
                    echo ""
                    read -p "  Enter search keyword: " keyword
                    if [ -n "$keyword" ]; then
                        read -p "  Context lines (default 3): " ctx
                        ctx=${ctx:-3}
                        search_container_logs "$selected" "$keyword" "$ctx"
                    fi
                fi
                ;;
            0|"")
                return
                ;;
            *)
                ;;
        esac
    done
}

# =============================================================================
# MAIN MENU
# =============================================================================

show_main_menu() {
    while true; do
        show_main_dashboard

        echo -e "${WHITE}${BOLD}Options${NC}"
        echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
        echo "    1-${#SERVICES[@]}) Select service for details"
        echo "    s) Search logs"
        echo "    q) Quick health check"
        echo "    x) Xilriws status & proxy management"
        echo "    d) Device disconnect monitor"
        echo "    m) Log maintenance"
        echo "    c) Docker configuration"
        echo "    r) Refresh"
        echo "    0) Exit"
        echo ""
        read -p "  Select option: " choice

        case $choice in
            [1-9]|1[0-4])
                if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#SERVICES[@]}" ] 2>/dev/null; then
                    show_service_detail "${SERVICES[$((choice-1))]}"
                fi
                ;;
            s|S) search_logs_menu ;;
            q|Q) quick_health_check ;;
            x|X) show_xilriws_menu ;;
            d|D) show_device_disconnects ;;
            m|M) log_maintenance_menu ;;
            c|C) docker_config_menu ;;
            r|R) continue ;;
            0)
                echo ""
                print_success "Goodbye!"
                return_to_main
                ;;
        esac
    done
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    check_docker

    # Check for command line arguments
    case "${1:-}" in
        --health|-h)
            quick_health_check
            ;;
        --xilriws|-x)
            show_xilriws_menu
            ;;
        --xilriws-monitor)
            xilriws_live_monitor
            ;;
        --clear-all)
            echo "Clearing all logs..."
            for service in "${SERVICES[@]}"; do
                local log_path=$(docker inspect --format='{{.LogPath}}' "$service" 2>/dev/null)
                if [ -n "$log_path" ] && [ -f "$log_path" ]; then
                    sudo truncate -s 0 "$log_path" 2>/dev/null && echo "  Cleared: $service"
                fi
            done
            ;;
        --help)
            echo ""
            echo "Aegis Docker Log Manager"
            echo ""
            echo "Usage: $0 [option]"
            echo ""
            echo "Options:"
            echo "  (none)           Interactive menu"
            echo "  -h               Quick health check"
            echo "  -x, --xilriws    Xilriws status & proxy management"
            echo "  --xilriws-monitor  Xilriws live monitor mode"
            echo "  --clear-all      Clear all logs (requires sudo)"
            echo "  --help           This help message"
            echo ""
            exit 0
            ;;
        *)
            show_main_menu
            ;;
    esac
}

main "$@"

