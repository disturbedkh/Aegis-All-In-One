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

# Print functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

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

# Count errors in log by pattern
count_errors_by_pattern() {
    local container=$1
    local pattern=$2
    local count=$(docker logs "$container" 2>&1 | grep -iEc "$pattern" 2>/dev/null || echo "0")
    echo "$count"
}

# Count total errors in log
count_total_errors() {
    local container=$1
    local count=$(docker logs "$container" 2>&1 | grep -iEc "error|err|fatal|panic|critical|failed|exception" 2>/dev/null || echo "0")
    echo "$count"
}

# Count warnings in log
count_warnings() {
    local container=$1
    local count=$(docker logs "$container" 2>&1 | grep -iEc "warn|warning" 2>/dev/null || echo "0")
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
        0) return ;;
        *) show_service_detail "$service" ;;
    esac
}

# =============================================================================
# ERROR VIEWING
# =============================================================================

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

    local count=$(count_errors_by_pattern "$service" "$pattern")
    echo -e "  Found ${RED}$count${NC} entries matching '$category' pattern"
    echo ""

    if [ "$count" -gt 0 ]; then
        echo -e "${WHITE}${BOLD}Error Entries (with context):${NC}"
        echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
        
        # Get errors with context, limit to reasonable amount
        docker logs "$service" 2>&1 | grep -iE -B1 -A1 "$pattern" 2>/dev/null | head -100 | while read line; do
            if echo "$line" | grep -qiE "$pattern"; then
                echo -e "${RED}$line${NC}"
            elif [ "$line" = "--" ]; then
                echo -e "${DIM}---${NC}"
            else
                echo -e "${DIM}$line${NC}"
            fi
        done

        if [ "$count" -gt 30 ]; then
            echo ""
            echo -e "${YELLOW}  (Showing first ~30 matches. Use search for specific entries)${NC}"
        fi
    else
        echo -e "  ${GREEN}No errors found in this category!${NC}"
    fi

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
# MAIN MENU
# =============================================================================

show_main_menu() {
    while true; do
        show_main_dashboard

        echo -e "${WHITE}${BOLD}Options${NC}"
        echo -e "${DIM}──────────────────────────────────────────────────────────────────────────${NC}"
        echo "    1-${#SERVICES[@]}) Select service for details"
        echo "    q) Quick health check"
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
            q|Q) quick_health_check ;;
            d|D) show_device_disconnects ;;
            m|M) log_maintenance_menu ;;
            c|C) docker_config_menu ;;
            r|R) continue ;;
            0)
                echo ""
                print_success "Goodbye!"
                exit 0
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
            echo "  (none)       Interactive menu"
            echo "  -h           Quick health check"
            echo "  --clear-all  Clear all logs (requires sudo)"
            echo "  --help       This help message"
            echo ""
            exit 0
            ;;
        *)
            show_main_menu
            ;;
    esac
}

main "$@"

