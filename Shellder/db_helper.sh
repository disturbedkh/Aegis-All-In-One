#!/bin/bash

# =============================================================================
# Shellder Database Helper Functions
# =============================================================================
# This file provides common SQLite database functions for all Shellder scripts.
# Source this file to use the database: source "$(dirname "$0")/db_helper.sh"
# =============================================================================

# Database file location (in Shellder directory)
SHELLDER_DB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELLDER_DB="$SHELLDER_DB_DIR/shellder.db"

# =============================================================================
# DATABASE INITIALIZATION
# =============================================================================

# Initialize the database with all required tables
init_shellder_db() {
    # Check if sqlite3 is available
    if ! command -v sqlite3 &> /dev/null; then
        return 1
    fi
    
    # Create database and tables if they don't exist
    sqlite3 "$SHELLDER_DB" <<EOF
-- Proxy statistics table (Xilriws)
CREATE TABLE IF NOT EXISTS proxy_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    proxy_address TEXT UNIQUE NOT NULL,
    requests_total INTEGER DEFAULT 0,
    requests_success INTEGER DEFAULT 0,
    requests_failed INTEGER DEFAULT 0,
    requests_timeout INTEGER DEFAULT 0,
    avg_response_time_ms INTEGER DEFAULT 0,
    first_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_status TEXT DEFAULT 'unknown',
    notes TEXT
);

-- Error statistics table
CREATE TABLE IF NOT EXISTS error_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    service_name TEXT NOT NULL,
    error_type TEXT NOT NULL,
    error_message TEXT,
    occurrence_count INTEGER DEFAULT 1,
    first_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
    resolved INTEGER DEFAULT 0,
    UNIQUE(service_name, error_type, error_message)
);

-- Container statistics table
CREATE TABLE IF NOT EXISTS container_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    container_name TEXT UNIQUE NOT NULL,
    start_count INTEGER DEFAULT 0,
    restart_count INTEGER DEFAULT 0,
    crash_count INTEGER DEFAULT 0,
    total_uptime_seconds INTEGER DEFAULT 0,
    last_start DATETIME,
    last_stop DATETIME,
    last_status TEXT DEFAULT 'unknown',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Daily log summaries table
CREATE TABLE IF NOT EXISTS log_summaries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    log_date DATE NOT NULL,
    service_name TEXT NOT NULL,
    total_lines INTEGER DEFAULT 0,
    error_count INTEGER DEFAULT 0,
    warning_count INTEGER DEFAULT 0,
    info_count INTEGER DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(log_date, service_name)
);

-- Scan statistics table
CREATE TABLE IF NOT EXISTS scan_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    stat_date DATE NOT NULL,
    pokemon_seen INTEGER DEFAULT 0,
    pokestops_scanned INTEGER DEFAULT 0,
    gyms_scanned INTEGER DEFAULT 0,
    quests_found INTEGER DEFAULT 0,
    raids_found INTEGER DEFAULT 0,
    devices_active INTEGER DEFAULT 0,
    accounts_used INTEGER DEFAULT 0,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(stat_date)
);

-- System events table (for tracking important events)
CREATE TABLE IF NOT EXISTS system_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type TEXT NOT NULL,
    event_source TEXT NOT NULL,
    event_message TEXT,
    event_data TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Database metadata table
CREATE TABLE IF NOT EXISTS db_metadata (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Insert or update database version
INSERT OR REPLACE INTO db_metadata (key, value, updated_at) 
VALUES ('version', '1.0', CURRENT_TIMESTAMP);

INSERT OR REPLACE INTO db_metadata (key, value, updated_at) 
VALUES ('created', COALESCE((SELECT value FROM db_metadata WHERE key='created'), CURRENT_TIMESTAMP), CURRENT_TIMESTAMP);

-- Create indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_error_stats_service ON error_stats(service_name);
CREATE INDEX IF NOT EXISTS idx_error_stats_last_seen ON error_stats(last_seen);
CREATE INDEX IF NOT EXISTS idx_log_summaries_date ON log_summaries(log_date);
CREATE INDEX IF NOT EXISTS idx_system_events_type ON system_events(event_type);
CREATE INDEX IF NOT EXISTS idx_system_events_created ON system_events(created_at);
EOF

    return 0
}

# Check if database exists and is valid
check_shellder_db() {
    if [ ! -f "$SHELLDER_DB" ]; then
        return 1
    fi
    
    # Verify database integrity
    local integrity=$(sqlite3 "$SHELLDER_DB" "PRAGMA integrity_check;" 2>/dev/null)
    if [ "$integrity" = "ok" ]; then
        return 0
    else
        return 2
    fi
}

# =============================================================================
# PROXY STATS FUNCTIONS
# =============================================================================

# Record a proxy request
# Usage: record_proxy_request "proxy_address" "success|failed|timeout" [response_time_ms]
record_proxy_request() {
    local proxy="$1"
    local status="$2"
    local response_time="${3:-0}"
    
    [ -z "$proxy" ] && return 1
    
    sqlite3 "$SHELLDER_DB" <<EOF
INSERT INTO proxy_stats (proxy_address, requests_total, requests_success, requests_failed, requests_timeout, avg_response_time_ms, last_seen, last_status)
VALUES ('$proxy', 1, 
    CASE WHEN '$status' = 'success' THEN 1 ELSE 0 END,
    CASE WHEN '$status' = 'failed' THEN 1 ELSE 0 END,
    CASE WHEN '$status' = 'timeout' THEN 1 ELSE 0 END,
    $response_time, CURRENT_TIMESTAMP, '$status')
ON CONFLICT(proxy_address) DO UPDATE SET
    requests_total = requests_total + 1,
    requests_success = requests_success + CASE WHEN '$status' = 'success' THEN 1 ELSE 0 END,
    requests_failed = requests_failed + CASE WHEN '$status' = 'failed' THEN 1 ELSE 0 END,
    requests_timeout = requests_timeout + CASE WHEN '$status' = 'timeout' THEN 1 ELSE 0 END,
    avg_response_time_ms = (avg_response_time_ms * requests_total + $response_time) / (requests_total + 1),
    last_seen = CURRENT_TIMESTAMP,
    last_status = '$status';
EOF
}

# Bulk update proxy stats from parsed log data
# Usage: update_proxy_stats "proxy_address" total success failed timeout
update_proxy_stats() {
    local proxy="$1"
    local total="${2:-0}"
    local success="${3:-0}"
    local failed="${4:-0}"
    local timeout="${5:-0}"
    
    [ -z "$proxy" ] && return 1
    
    sqlite3 "$SHELLDER_DB" <<EOF
INSERT INTO proxy_stats (proxy_address, requests_total, requests_success, requests_failed, requests_timeout, last_seen)
VALUES ('$proxy', $total, $success, $failed, $timeout, CURRENT_TIMESTAMP)
ON CONFLICT(proxy_address) DO UPDATE SET
    requests_total = requests_total + $total,
    requests_success = requests_success + $success,
    requests_failed = requests_failed + $failed,
    requests_timeout = requests_timeout + $timeout,
    last_seen = CURRENT_TIMESTAMP;
EOF
}

# Get all-time proxy stats
get_proxy_stats_all_time() {
    sqlite3 -header -column "$SHELLDER_DB" <<EOF
SELECT 
    proxy_address AS "Proxy",
    requests_total AS "Total",
    requests_success AS "Success",
    requests_failed AS "Failed",
    requests_timeout AS "Timeout",
    ROUND(100.0 * requests_success / NULLIF(requests_total, 0), 1) AS "Success%",
    avg_response_time_ms AS "AvgMs",
    last_status AS "Status",
    datetime(last_seen, 'localtime') AS "Last Seen"
FROM proxy_stats
ORDER BY requests_total DESC;
EOF
}

# Get proxy stats summary
get_proxy_stats_summary() {
    sqlite3 "$SHELLDER_DB" <<EOF
SELECT 
    COUNT(*) AS total_proxies,
    SUM(requests_total) AS total_requests,
    SUM(requests_success) AS total_success,
    SUM(requests_failed) AS total_failed,
    SUM(requests_timeout) AS total_timeout,
    ROUND(100.0 * SUM(requests_success) / NULLIF(SUM(requests_total), 0), 1) AS success_rate
FROM proxy_stats;
EOF
}

# =============================================================================
# ERROR STATS FUNCTIONS
# =============================================================================

# Record an error occurrence
# Usage: record_error "service_name" "error_type" "error_message"
record_error() {
    local service="$1"
    local error_type="$2"
    local message="$3"
    
    [ -z "$service" ] || [ -z "$error_type" ] && return 1
    
    # Escape single quotes in message
    message="${message//\'/\'\'}"
    
    sqlite3 "$SHELLDER_DB" <<EOF
INSERT INTO error_stats (service_name, error_type, error_message, occurrence_count, last_seen)
VALUES ('$service', '$error_type', '$message', 1, CURRENT_TIMESTAMP)
ON CONFLICT(service_name, error_type, error_message) DO UPDATE SET
    occurrence_count = occurrence_count + 1,
    last_seen = CURRENT_TIMESTAMP,
    resolved = 0;
EOF
}

# Bulk record errors (increment count by specified amount)
# Usage: record_error_bulk "service_name" "error_type" count "error_message"
record_error_bulk() {
    local service="$1"
    local error_type="$2"
    local count="${3:-1}"
    local message="$4"
    
    [ -z "$service" ] || [ -z "$error_type" ] && return 1
    
    message="${message//\'/\'\'}"
    
    sqlite3 "$SHELLDER_DB" <<EOF
INSERT INTO error_stats (service_name, error_type, error_message, occurrence_count, last_seen)
VALUES ('$service', '$error_type', '$message', $count, CURRENT_TIMESTAMP)
ON CONFLICT(service_name, error_type, error_message) DO UPDATE SET
    occurrence_count = occurrence_count + $count,
    last_seen = CURRENT_TIMESTAMP;
EOF
}

# Get all-time error stats
get_error_stats_all_time() {
    sqlite3 -header -column "$SHELLDER_DB" <<EOF
SELECT 
    service_name AS "Service",
    error_type AS "Error Type",
    occurrence_count AS "Count",
    datetime(first_seen, 'localtime') AS "First Seen",
    datetime(last_seen, 'localtime') AS "Last Seen",
    CASE WHEN resolved THEN 'Yes' ELSE 'No' END AS "Resolved"
FROM error_stats
ORDER BY occurrence_count DESC
LIMIT 50;
EOF
}

# Get error stats by service
get_error_stats_by_service() {
    local service="$1"
    sqlite3 -header -column "$SHELLDER_DB" <<EOF
SELECT 
    error_type AS "Error Type",
    occurrence_count AS "Count",
    error_message AS "Message",
    datetime(last_seen, 'localtime') AS "Last Seen"
FROM error_stats
WHERE service_name = '$service'
ORDER BY occurrence_count DESC;
EOF
}

# Get error summary by service
get_error_summary() {
    sqlite3 -header -column "$SHELLDER_DB" <<EOF
SELECT 
    service_name AS "Service",
    COUNT(*) AS "Error Types",
    SUM(occurrence_count) AS "Total Occurrences",
    datetime(MAX(last_seen), 'localtime') AS "Most Recent"
FROM error_stats
WHERE resolved = 0
GROUP BY service_name
ORDER BY SUM(occurrence_count) DESC;
EOF
}

# Mark errors as resolved for a service
mark_errors_resolved() {
    local service="$1"
    if [ -z "$service" ]; then
        sqlite3 "$SHELLDER_DB" "UPDATE error_stats SET resolved = 1;"
    else
        sqlite3 "$SHELLDER_DB" "UPDATE error_stats SET resolved = 1 WHERE service_name = '$service';"
    fi
}

# =============================================================================
# CONTAINER STATS FUNCTIONS
# =============================================================================

# Record container start
record_container_start() {
    local container="$1"
    [ -z "$container" ] && return 1
    
    sqlite3 "$SHELLDER_DB" <<EOF
INSERT INTO container_stats (container_name, start_count, last_start, last_status, updated_at)
VALUES ('$container', 1, CURRENT_TIMESTAMP, 'running', CURRENT_TIMESTAMP)
ON CONFLICT(container_name) DO UPDATE SET
    start_count = start_count + 1,
    last_start = CURRENT_TIMESTAMP,
    last_status = 'running',
    updated_at = CURRENT_TIMESTAMP;
EOF
}

# Record container stop
record_container_stop() {
    local container="$1"
    local uptime_seconds="${2:-0}"
    [ -z "$container" ] && return 1
    
    sqlite3 "$SHELLDER_DB" <<EOF
INSERT INTO container_stats (container_name, last_stop, last_status, total_uptime_seconds, updated_at)
VALUES ('$container', CURRENT_TIMESTAMP, 'stopped', $uptime_seconds, CURRENT_TIMESTAMP)
ON CONFLICT(container_name) DO UPDATE SET
    last_stop = CURRENT_TIMESTAMP,
    last_status = 'stopped',
    total_uptime_seconds = total_uptime_seconds + $uptime_seconds,
    updated_at = CURRENT_TIMESTAMP;
EOF
}

# Record container restart
record_container_restart() {
    local container="$1"
    [ -z "$container" ] && return 1
    
    sqlite3 "$SHELLDER_DB" <<EOF
INSERT INTO container_stats (container_name, restart_count, last_start, last_status, updated_at)
VALUES ('$container', 1, CURRENT_TIMESTAMP, 'running', CURRENT_TIMESTAMP)
ON CONFLICT(container_name) DO UPDATE SET
    restart_count = restart_count + 1,
    last_start = CURRENT_TIMESTAMP,
    last_status = 'running',
    updated_at = CURRENT_TIMESTAMP;
EOF
}

# Record container crash
record_container_crash() {
    local container="$1"
    [ -z "$container" ] && return 1
    
    sqlite3 "$SHELLDER_DB" <<EOF
INSERT INTO container_stats (container_name, crash_count, last_status, updated_at)
VALUES ('$container', 1, 'crashed', CURRENT_TIMESTAMP)
ON CONFLICT(container_name) DO UPDATE SET
    crash_count = crash_count + 1,
    last_status = 'crashed',
    updated_at = CURRENT_TIMESTAMP;
EOF
}

# Update container status
update_container_status() {
    local container="$1"
    local status="$2"
    [ -z "$container" ] || [ -z "$status" ] && return 1
    
    sqlite3 "$SHELLDER_DB" <<EOF
INSERT INTO container_stats (container_name, last_status, updated_at)
VALUES ('$container', '$status', CURRENT_TIMESTAMP)
ON CONFLICT(container_name) DO UPDATE SET
    last_status = '$status',
    updated_at = CURRENT_TIMESTAMP;
EOF
}

# Get all-time container stats
get_container_stats_all_time() {
    sqlite3 -header -column "$SHELLDER_DB" <<EOF
SELECT 
    container_name AS "Container",
    start_count AS "Starts",
    restart_count AS "Restarts",
    crash_count AS "Crashes",
    ROUND(total_uptime_seconds / 3600.0, 1) AS "Uptime(hrs)",
    last_status AS "Status",
    datetime(last_start, 'localtime') AS "Last Start"
FROM container_stats
ORDER BY container_name;
EOF
}

# =============================================================================
# LOG SUMMARY FUNCTIONS
# =============================================================================

# Record daily log summary
record_log_summary() {
    local service="$1"
    local total="${2:-0}"
    local errors="${3:-0}"
    local warnings="${4:-0}"
    local infos="${5:-0}"
    local date="${6:-$(date +%Y-%m-%d)}"
    
    [ -z "$service" ] && return 1
    
    sqlite3 "$SHELLDER_DB" <<EOF
INSERT INTO log_summaries (log_date, service_name, total_lines, error_count, warning_count, info_count)
VALUES ('$date', '$service', $total, $errors, $warnings, $infos)
ON CONFLICT(log_date, service_name) DO UPDATE SET
    total_lines = total_lines + $total,
    error_count = error_count + $errors,
    warning_count = warning_count + $warnings,
    info_count = info_count + $infos;
EOF
}

# Get log summaries for a service
get_log_summaries() {
    local service="$1"
    local days="${2:-7}"
    
    if [ -z "$service" ]; then
        sqlite3 -header -column "$SHELLDER_DB" <<EOF
SELECT 
    log_date AS "Date",
    service_name AS "Service",
    total_lines AS "Lines",
    error_count AS "Errors",
    warning_count AS "Warnings"
FROM log_summaries
WHERE log_date >= date('now', '-$days days')
ORDER BY log_date DESC, service_name;
EOF
    else
        sqlite3 -header -column "$SHELLDER_DB" <<EOF
SELECT 
    log_date AS "Date",
    total_lines AS "Lines",
    error_count AS "Errors",
    warning_count AS "Warnings",
    info_count AS "Info"
FROM log_summaries
WHERE service_name = '$service' AND log_date >= date('now', '-$days days')
ORDER BY log_date DESC;
EOF
    fi
}

# =============================================================================
# SYSTEM EVENTS FUNCTIONS
# =============================================================================

# Record a system event
record_event() {
    local event_type="$1"
    local source="$2"
    local message="$3"
    local data="$4"
    
    [ -z "$event_type" ] || [ -z "$source" ] && return 1
    
    message="${message//\'/\'\'}"
    data="${data//\'/\'\'}"
    
    sqlite3 "$SHELLDER_DB" <<EOF
INSERT INTO system_events (event_type, event_source, event_message, event_data)
VALUES ('$event_type', '$source', '$message', '$data');
EOF
}

# Get recent events
get_recent_events() {
    local limit="${1:-20}"
    sqlite3 -header -column "$SHELLDER_DB" <<EOF
SELECT 
    datetime(created_at, 'localtime') AS "Time",
    event_type AS "Type",
    event_source AS "Source",
    event_message AS "Message"
FROM system_events
ORDER BY created_at DESC
LIMIT $limit;
EOF
}

# =============================================================================
# DATABASE MAINTENANCE FUNCTIONS
# =============================================================================

# Get database size
get_db_size() {
    if [ -f "$SHELLDER_DB" ]; then
        local size=$(du -h "$SHELLDER_DB" 2>/dev/null | cut -f1)
        echo "$size"
    else
        echo "0"
    fi
}

# Get database statistics
get_db_stats() {
    sqlite3 "$SHELLDER_DB" <<EOF
.mode column
.headers on
SELECT 
    'proxy_stats' AS "Table",
    (SELECT COUNT(*) FROM proxy_stats) AS "Rows",
    (SELECT SUM(requests_total) FROM proxy_stats) AS "Total Requests"
UNION ALL
SELECT 
    'error_stats',
    (SELECT COUNT(*) FROM error_stats),
    (SELECT SUM(occurrence_count) FROM error_stats)
UNION ALL
SELECT 
    'container_stats',
    (SELECT COUNT(*) FROM container_stats),
    (SELECT SUM(start_count) FROM container_stats)
UNION ALL
SELECT 
    'log_summaries',
    (SELECT COUNT(*) FROM log_summaries),
    (SELECT SUM(total_lines) FROM log_summaries)
UNION ALL
SELECT 
    'system_events',
    (SELECT COUNT(*) FROM system_events),
    NULL;
EOF
}

# Vacuum database (optimize)
vacuum_db() {
    sqlite3 "$SHELLDER_DB" "VACUUM;"
    return $?
}

# Clear old records (keep last N days)
clear_old_records() {
    local days="${1:-30}"
    
    sqlite3 "$SHELLDER_DB" <<EOF
DELETE FROM system_events WHERE created_at < datetime('now', '-$days days');
DELETE FROM log_summaries WHERE log_date < date('now', '-$days days');
DELETE FROM error_stats WHERE last_seen < datetime('now', '-$days days') AND resolved = 1;
EOF
    
    vacuum_db
}

# Reset all statistics (keep structure)
reset_all_stats() {
    sqlite3 "$SHELLDER_DB" <<EOF
DELETE FROM proxy_stats;
DELETE FROM error_stats;
DELETE FROM container_stats;
DELETE FROM log_summaries;
DELETE FROM scan_stats;
DELETE FROM system_events;
UPDATE db_metadata SET value = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE key = 'last_reset';
INSERT OR IGNORE INTO db_metadata (key, value) VALUES ('last_reset', CURRENT_TIMESTAMP);
VACUUM;
EOF
}

# Backup database
backup_db() {
    local backup_path="${1:-$SHELLDER_DB_DIR/shellder_backup_$(date +%Y%m%d_%H%M%S).db}"
    if [ -f "$SHELLDER_DB" ]; then
        cp "$SHELLDER_DB" "$backup_path"
        echo "$backup_path"
        return 0
    fi
    return 1
}

# Export table to CSV
export_table_csv() {
    local table="$1"
    local output="${2:-$SHELLDER_DB_DIR/${table}_export_$(date +%Y%m%d).csv}"
    
    sqlite3 -header -csv "$SHELLDER_DB" "SELECT * FROM $table;" > "$output"
    echo "$output"
}

# Check database integrity
check_db_integrity() {
    sqlite3 "$SHELLDER_DB" "PRAGMA integrity_check;"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Auto-initialize database when this file is sourced
if ! check_shellder_db 2>/dev/null; then
    init_shellder_db 2>/dev/null
fi

