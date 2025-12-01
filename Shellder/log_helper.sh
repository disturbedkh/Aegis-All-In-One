#!/bin/bash

# =============================================================================
# Shellder Logging System
# =============================================================================
# This file provides comprehensive logging for all Shellder scripts.
# Source this file to enable logging: source "$(dirname "$0")/log_helper.sh"
#
# LOG FORMAT (Human-Readable):
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ [2024-12-01 14:30:45] [INFO] [setup.sh] Message here                    │
# │                                                                          │
# │ For errors, includes:                                                    │
# │   • What happened (plain English)                                        │
# │   • Technical details (for advanced users)                               │
# │   • Suggestions to fix                                                   │
# └─────────────────────────────────────────────────────────────────────────┘
#
# TO SHARE WITH AI ASSISTANT:
#   Run: bash Shellder/log_helper.sh --export
#   This creates a formatted file ready to paste into chat
# =============================================================================

# Log file location
SHELLDER_LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELLDER_LOG_FILE="$SHELLDER_LOG_DIR/shellder.log"
SHELLDER_LOG_MAX_SIZE=5242880  # 5MB before rotation
SHELLDER_LOG_KEEP_ROTATIONS=3

# Current script name (set by sourcing script)
SHELLDER_SCRIPT_NAME="${SHELLDER_SCRIPT_NAME:-$(basename "${BASH_SOURCE[1]}" 2>/dev/null || echo "unknown")}"

# Log levels
LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3
LOG_LEVEL_FATAL=4

# Current log level (default: INFO)
SHELLDER_LOG_LEVEL="${SHELLDER_LOG_LEVEL:-$LOG_LEVEL_INFO}"

# Session ID for grouping related logs
SHELLDER_SESSION_ID="${SHELLDER_SESSION_ID:-$(date +%Y%m%d%H%M%S)_$$}"

# =============================================================================
# CORE LOGGING FUNCTIONS
# =============================================================================

# Initialize logging for a script
init_logging() {
    local script_name="${1:-$SHELLDER_SCRIPT_NAME}"
    SHELLDER_SCRIPT_NAME="$script_name"
    
    # Rotate log if needed
    rotate_log_if_needed
    
    # Log session start
    log_raw "═══════════════════════════════════════════════════════════════════════════"
    log_raw "SESSION START: $SHELLDER_SCRIPT_NAME"
    log_raw "Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    log_raw "Session ID: $SHELLDER_SESSION_ID"
    log_raw "User: ${REAL_USER:-${SUDO_USER:-$USER}}"
    log_raw "Working Dir: $(pwd)"
    log_raw "═══════════════════════════════════════════════════════════════════════════"
    
    # Set up error handling
    setup_error_handlers
}

# Write raw text to log (no formatting)
log_raw() {
    echo "$1" >> "$SHELLDER_LOG_FILE" 2>/dev/null
}

# Main log function
# Usage: log_message LEVEL "message" ["technical_details"] ["suggestion"]
log_message() {
    local level="$1"
    local message="$2"
    local technical="${3:-}"
    local suggestion="${4:-}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local level_name=""
    local level_num=0
    
    case "$level" in
        DEBUG|debug) level_name="DEBUG"; level_num=$LOG_LEVEL_DEBUG ;;
        INFO|info)   level_name="INFO "; level_num=$LOG_LEVEL_INFO ;;
        WARN|warn)   level_name="WARN "; level_num=$LOG_LEVEL_WARN ;;
        ERROR|error) level_name="ERROR"; level_num=$LOG_LEVEL_ERROR ;;
        FATAL|fatal) level_name="FATAL"; level_num=$LOG_LEVEL_FATAL ;;
        *) level_name="INFO "; level_num=$LOG_LEVEL_INFO ;;
    esac
    
    # Skip if below current log level
    [ $level_num -lt $SHELLDER_LOG_LEVEL ] && return 0
    
    # Format and write log entry
    {
        echo "[$timestamp] [$level_name] [$SHELLDER_SCRIPT_NAME] $message"
        
        # Add technical details for WARN/ERROR/FATAL
        if [ -n "$technical" ] && [ $level_num -ge $LOG_LEVEL_WARN ]; then
            echo "    Technical: $technical"
        fi
        
        # Add suggestion for ERROR/FATAL
        if [ -n "$suggestion" ] && [ $level_num -ge $LOG_LEVEL_ERROR ]; then
            echo "    Suggestion: $suggestion"
        fi
    } >> "$SHELLDER_LOG_FILE" 2>/dev/null
}

# Convenience functions
log_debug() { log_message DEBUG "$1" "$2" "$3"; }
log_info()  { log_message INFO "$1" "$2" "$3"; }
log_warn()  { log_message WARN "$1" "$2" "$3"; }
log_error() { log_message ERROR "$1" "$2" "$3"; }
log_fatal() { log_message FATAL "$1" "$2" "$3"; }

# =============================================================================
# STRUCTURED LOGGING FOR COMMON OPERATIONS
# =============================================================================

# Log a command execution
log_command() {
    local cmd="$1"
    local description="${2:-Executing command}"
    
    log_debug "$description: $cmd"
}

# Log command result
log_command_result() {
    local exit_code="$1"
    local cmd="${2:-command}"
    local output="${3:-}"
    
    if [ "$exit_code" -eq 0 ]; then
        log_debug "Command succeeded: $cmd"
    else
        log_error "Command failed: $cmd" \
            "Exit code: $exit_code${output:+, Output: $output}" \
            "Check if the command exists and has proper permissions"
    fi
}

# Log Docker operation
log_docker() {
    local operation="$1"
    local container="${2:-}"
    local result="${3:-}"
    
    if [ -n "$container" ]; then
        log_info "Docker $operation: $container" "$result"
    else
        log_info "Docker $operation" "$result"
    fi
}

# Log database operation
log_database() {
    local operation="$1"
    local details="${2:-}"
    local success="${3:-true}"
    
    if [ "$success" = "true" ]; then
        log_info "Database $operation" "$details"
    else
        log_error "Database $operation failed" "$details" \
            "Check database credentials and connection"
    fi
}

# Log configuration change
log_config() {
    local action="$1"
    local key="$2"
    local file="${3:-}"
    local sensitive="${4:-false}"
    
    if [ "$sensitive" = "true" ]; then
        log_info "Config $action: $key" "File: $file (value hidden)"
    else
        log_info "Config $action: $key" "File: $file"
    fi
}

# Log user action
log_user_action() {
    local action="$1"
    local details="${2:-}"
    
    log_info "User action: $action" "$details"
}

# =============================================================================
# ERROR HANDLING & CRASH CAPTURE
# =============================================================================

# Set up error handlers
setup_error_handlers() {
    # Trap errors
    trap 'handle_error $? $LINENO "$BASH_COMMAND" "${FUNCNAME[*]}"' ERR
    
    # Trap exit
    trap 'handle_exit $?' EXIT
    
    # Trap signals
    trap 'handle_signal SIGINT' SIGINT
    trap 'handle_signal SIGTERM' SIGTERM
    trap 'handle_signal SIGHUP' SIGHUP
}

# Handle errors (called by ERR trap)
handle_error() {
    local exit_code=$1
    local line_num=$2
    local command="$3"
    local func_stack="$4"
    
    # Don't log if exit code is 0
    [ "$exit_code" -eq 0 ] && return
    
    log_raw ""
    log_raw "┌─────────────────────────────────────────────────────────────────────────"
    log_raw "│ ⚠️  ERROR DETECTED"
    log_raw "├─────────────────────────────────────────────────────────────────────────"
    log_raw "│ Time: $(date '+%Y-%m-%d %H:%M:%S')"
    log_raw "│ Script: $SHELLDER_SCRIPT_NAME"
    log_raw "│ Line: $line_num"
    log_raw "│ Exit Code: $exit_code"
    log_raw "│ Command: $command"
    log_raw "│"
    log_raw "│ Function Stack:"
    for func in $func_stack; do
        log_raw "│   → $func"
    done
    log_raw "│"
    log_raw "│ What This Means:"
    log_raw "│   The command above did not complete successfully."
    log_raw "│"
    log_raw "│ Common Causes:"
    case "$exit_code" in
        1)   log_raw "│   • General error - command returned failure" ;;
        2)   log_raw "│   • Misuse of command or invalid arguments" ;;
        126) log_raw "│   • Permission denied - cannot execute command" ;;
        127) log_raw "│   • Command not found - may need to install package" ;;
        128) log_raw "│   • Invalid exit code from command" ;;
        130) log_raw "│   • Script interrupted by Ctrl+C" ;;
        137) log_raw "│   • Process killed (out of memory?)" ;;
        *)   log_raw "│   • Exit code $exit_code - check command documentation" ;;
    esac
    log_raw "│"
    log_raw "│ To share this error with support:"
    log_raw "│   Run: bash Shellder/log_helper.sh --export-error"
    log_raw "└─────────────────────────────────────────────────────────────────────────"
    log_raw ""
    
    # Also capture system state
    capture_system_state "error"
}

# Handle script exit
handle_exit() {
    local exit_code=$1
    
    log_raw ""
    log_raw "───────────────────────────────────────────────────────────────────────────"
    log_raw "SESSION END: $SHELLDER_SCRIPT_NAME"
    log_raw "Exit Code: $exit_code"
    log_raw "Time: $(date '+%Y-%m-%d %H:%M:%S')"
    log_raw "Duration: Script ran for $SECONDS seconds"
    log_raw "───────────────────────────────────────────────────────────────────────────"
    log_raw ""
}

# Handle signals
handle_signal() {
    local signal=$1
    
    log_raw ""
    log_raw "┌─────────────────────────────────────────────────────────────────────────"
    log_raw "│ 🛑 SIGNAL RECEIVED: $signal"
    log_raw "├─────────────────────────────────────────────────────────────────────────"
    log_raw "│ Time: $(date '+%Y-%m-%d %H:%M:%S')"
    log_raw "│ Script: $SHELLDER_SCRIPT_NAME"
    log_raw "│"
    case "$signal" in
        SIGINT)
            log_raw "│ You pressed Ctrl+C to stop the script."
            log_raw "│ This is normal if you wanted to cancel an operation."
            ;;
        SIGTERM)
            log_raw "│ The script was asked to terminate by the system."
            log_raw "│ This can happen during system shutdown or when killed."
            ;;
        SIGHUP)
            log_raw "│ The terminal was closed while script was running."
            ;;
    esac
    log_raw "└─────────────────────────────────────────────────────────────────────────"
    
    # Capture state before exit
    capture_system_state "signal_$signal"
    
    exit 130
}

# Capture system state for debugging
capture_system_state() {
    local trigger="${1:-manual}"
    
    log_raw ""
    log_raw "=== SYSTEM STATE SNAPSHOT ($trigger) ==="
    log_raw "Captured: $(date '+%Y-%m-%d %H:%M:%S')"
    log_raw ""
    
    # Memory info
    log_raw "--- Memory ---"
    if command -v free &>/dev/null; then
        free -h 2>/dev/null | head -3 >> "$SHELLDER_LOG_FILE"
    fi
    log_raw ""
    
    # Disk space
    log_raw "--- Disk Space ---"
    df -h "$(pwd)" 2>/dev/null | head -2 >> "$SHELLDER_LOG_FILE"
    log_raw ""
    
    # Docker status
    log_raw "--- Docker Status ---"
    if command -v docker &>/dev/null; then
        docker ps --format "{{.Names}}: {{.Status}}" 2>/dev/null | head -15 >> "$SHELLDER_LOG_FILE"
    else
        log_raw "Docker not available"
    fi
    log_raw ""
    
    # Recent container logs (if error)
    if [ "$trigger" = "error" ]; then
        log_raw "--- Recent Docker Events ---"
        docker events --since="5m" --until="now" 2>/dev/null | tail -10 >> "$SHELLDER_LOG_FILE"
        log_raw ""
    fi
    
    log_raw "=== END SYSTEM STATE ==="
    log_raw ""
}

# =============================================================================
# LOG MANAGEMENT
# =============================================================================

# Rotate log if it exceeds max size
rotate_log_if_needed() {
    if [ ! -f "$SHELLDER_LOG_FILE" ]; then
        return 0
    fi
    
    local size=$(stat -c%s "$SHELLDER_LOG_FILE" 2>/dev/null || echo 0)
    
    if [ "$size" -gt "$SHELLDER_LOG_MAX_SIZE" ]; then
        # Rotate existing logs
        for i in $(seq $((SHELLDER_LOG_KEEP_ROTATIONS - 1)) -1 1); do
            if [ -f "${SHELLDER_LOG_FILE}.$i" ]; then
                mv "${SHELLDER_LOG_FILE}.$i" "${SHELLDER_LOG_FILE}.$((i + 1))" 2>/dev/null
            fi
        done
        
        # Rotate current log
        mv "$SHELLDER_LOG_FILE" "${SHELLDER_LOG_FILE}.1" 2>/dev/null
        
        # Start fresh
        log_raw "=== LOG ROTATED: $(date '+%Y-%m-%d %H:%M:%S') ==="
        log_raw "Previous log saved as: ${SHELLDER_LOG_FILE}.1"
        log_raw ""
    fi
}

# Get log file size in human-readable format
get_log_size() {
    if [ -f "$SHELLDER_LOG_FILE" ]; then
        du -h "$SHELLDER_LOG_FILE" 2>/dev/null | cut -f1
    else
        echo "0"
    fi
}

# Count errors in log
count_log_errors() {
    if [ -f "$SHELLDER_LOG_FILE" ]; then
        grep -c "\[ERROR\]\|\[FATAL\]" "$SHELLDER_LOG_FILE" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# =============================================================================
# LOG EXPORT FOR AI ASSISTANCE
# =============================================================================

# Export recent logs for sharing with AI assistant
export_for_ai() {
    local output_file="$SHELLDER_LOG_DIR/shellder_debug_export.txt"
    local lines="${1:-200}"
    
    {
        echo "============================================================"
        echo "SHELLDER DEBUG EXPORT"
        echo "============================================================"
        echo ""
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Export Type: Recent Activity (last $lines lines)"
        echo ""
        echo "HOW TO USE THIS FILE:"
        echo "  Paste the contents below into your chat with the AI assistant"
        echo "  to help diagnose issues with your Shellder/Aegis AIO setup."
        echo ""
        echo "============================================================"
        echo "SYSTEM INFORMATION"
        echo "============================================================"
        echo ""
        echo "OS: $(uname -a 2>/dev/null || echo 'Unknown')"
        echo "Docker: $(docker --version 2>/dev/null || echo 'Not installed')"
        echo "Docker Compose: $(docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || echo 'Not installed')"
        echo ""
        echo "Working Directory: $(pwd)"
        echo "Shellder Directory: $SHELLDER_LOG_DIR"
        echo ""
        echo "============================================================"
        echo "RECENT LOG ENTRIES"
        echo "============================================================"
        echo ""
        
        if [ -f "$SHELLDER_LOG_FILE" ]; then
            tail -n "$lines" "$SHELLDER_LOG_FILE"
        else
            echo "No log file found at: $SHELLDER_LOG_FILE"
        fi
        
        echo ""
        echo "============================================================"
        echo "CURRENT CONTAINER STATUS"
        echo "============================================================"
        echo ""
        
        if command -v docker &>/dev/null; then
            docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "Could not get container status"
        else
            echo "Docker not available"
        fi
        
        echo ""
        echo "============================================================"
        echo "END OF DEBUG EXPORT"
        echo "============================================================"
        
    } > "$output_file"
    
    echo "$output_file"
}

# Export only error entries for sharing
export_errors_for_ai() {
    local output_file="$SHELLDER_LOG_DIR/shellder_error_export.txt"
    
    {
        echo "============================================================"
        echo "SHELLDER ERROR EXPORT"
        echo "============================================================"
        echo ""
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Export Type: Errors and Warnings Only"
        echo ""
        echo "HOW TO USE THIS FILE:"
        echo "  Paste the contents below into your chat with the AI assistant"
        echo "  to get help fixing these errors."
        echo ""
        echo "============================================================"
        echo "ERROR ENTRIES"
        echo "============================================================"
        echo ""
        
        if [ -f "$SHELLDER_LOG_FILE" ]; then
            # Get all error blocks (including context)
            grep -B2 -A5 "\[ERROR\]\|\[FATAL\]\|ERROR DETECTED\|SIGNAL RECEIVED" "$SHELLDER_LOG_FILE" 2>/dev/null | tail -100
        else
            echo "No log file found"
        fi
        
        echo ""
        echo "============================================================"
        echo "SYSTEM STATE AT LAST ERROR"
        echo "============================================================"
        echo ""
        
        if [ -f "$SHELLDER_LOG_FILE" ]; then
            # Get the most recent system state snapshot
            sed -n '/=== SYSTEM STATE SNAPSHOT/,/=== END SYSTEM STATE ===/p' "$SHELLDER_LOG_FILE" | tail -50
        fi
        
        echo ""
        echo "============================================================"
        echo "END OF ERROR EXPORT"
        echo "============================================================"
        
    } > "$output_file"
    
    echo "$output_file"
}

# View recent log entries
view_recent_logs() {
    local lines="${1:-50}"
    
    if [ -f "$SHELLDER_LOG_FILE" ]; then
        echo ""
        echo "=== RECENT SHELLDER LOG ENTRIES (last $lines lines) ==="
        echo ""
        tail -n "$lines" "$SHELLDER_LOG_FILE"
        echo ""
    else
        echo "No log file found at: $SHELLDER_LOG_FILE"
    fi
}

# Clear log file
clear_log() {
    if [ -f "$SHELLDER_LOG_FILE" ]; then
        > "$SHELLDER_LOG_FILE"
        log_raw "=== LOG CLEARED: $(date '+%Y-%m-%d %H:%M:%S') ==="
        echo "Log file cleared"
    fi
}

# =============================================================================
# COMMAND-LINE INTERFACE
# =============================================================================

show_log_help() {
    echo ""
    echo "Shellder Logging System"
    echo "======================="
    echo ""
    echo "Usage: bash Shellder/log_helper.sh [option]"
    echo ""
    echo "Options:"
    echo "  --view [N]        View last N log entries (default: 50)"
    echo "  --errors          View only error entries"
    echo "  --export          Export recent logs for AI assistance"
    echo "  --export-error    Export only errors for AI assistance"
    echo "  --size            Show log file size"
    echo "  --count-errors    Count error entries in log"
    echo "  --clear           Clear the log file"
    echo "  --path            Show log file path"
    echo "  --help            This help message"
    echo ""
    echo "Log File: $SHELLDER_LOG_FILE"
    echo ""
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --view)
            view_recent_logs "${2:-50}"
            ;;
        --errors)
            if [ -f "$SHELLDER_LOG_FILE" ]; then
                grep -B1 -A3 "\[ERROR\]\|\[FATAL\]\|ERROR DETECTED" "$SHELLDER_LOG_FILE" | tail -100
            else
                echo "No log file found"
            fi
            ;;
        --export)
            output=$(export_for_ai "${2:-200}")
            echo "Debug export created: $output"
            echo ""
            echo "You can now:"
            echo "  1. Open this file: cat $output"
            echo "  2. Copy its contents"
            echo "  3. Paste into your chat with the AI assistant"
            ;;
        --export-error)
            output=$(export_errors_for_ai)
            echo "Error export created: $output"
            echo ""
            echo "You can now:"
            echo "  1. Open this file: cat $output"
            echo "  2. Copy its contents"  
            echo "  3. Paste into your chat with the AI assistant"
            ;;
        --size)
            echo "Log file size: $(get_log_size)"
            ;;
        --count-errors)
            echo "Error count: $(count_log_errors)"
            ;;
        --clear)
            read -p "Clear log file? (y/n) [n]: " confirm
            if [ "$confirm" = "y" ]; then
                clear_log
            fi
            ;;
        --path)
            echo "$SHELLDER_LOG_FILE"
            ;;
        --help|*)
            show_log_help
            ;;
    esac
fi

