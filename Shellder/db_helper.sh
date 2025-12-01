#!/bin/bash

# =============================================================================
# Shellder Internal Database (SQLite) - NOT the same as dbsetup.sh!
# =============================================================================
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  IMPORTANT: This is NOT for your MariaDB/MySQL game databases!         │
# │                                                                         │
# │  • For MariaDB setup (Dragonite, Golbat, ReactMap databases):          │
# │    → Use dbsetup.sh (menu option 2 in Shellder)                        │
# │                                                                         │
# │  • This file (db_helper.sh) manages SHELLDER'S OWN SQLite database:    │
# │    → Stores: proxy stats, error stats, config values, container stats  │
# │    → File: Shellder/shellder.db                                         │
# │    → Purpose: Shellder's internal tracking and memory                  │
# └─────────────────────────────────────────────────────────────────────────┘
#
# WHAT THIS MANAGES (Shellder's internal SQLite):
#   • All-time proxy statistics (survives log clearing)
#   • Error tracking across sessions
#   • Container start/stop/crash counts
#   • Validated configuration values
#   • System events
#
# WHAT THIS DOES NOT MANAGE:
#   • MariaDB/MySQL databases (use dbsetup.sh)
#   • Game data (Pokemon, stops, gyms, raids)
#   • Account data
#   • Any service databases (Dragonite, Golbat, ReactMap, Koji, Poracle)
#
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

-- Configuration values table (stores user-entered config for cross-checking)
CREATE TABLE IF NOT EXISTS config_values (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    config_key TEXT UNIQUE NOT NULL,
    config_value TEXT NOT NULL,
    source_file TEXT,
    description TEXT,
    is_secret INTEGER DEFAULT 0,
    first_set DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_verified DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_mismatch DATETIME,
    mismatch_count INTEGER DEFAULT 0,
    verified_match INTEGER DEFAULT 1
);

-- Configuration discrepancy log
CREATE TABLE IF NOT EXISTS config_discrepancies (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    config_key TEXT NOT NULL,
    expected_value TEXT,
    found_value TEXT,
    source_file TEXT,
    detected_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    resolved INTEGER DEFAULT 0,
    resolved_at DATETIME
);

-- Insert or update database version
INSERT OR REPLACE INTO db_metadata (key, value, updated_at) 
VALUES ('version', '1.1', CURRENT_TIMESTAMP);

INSERT OR REPLACE INTO db_metadata (key, value, updated_at) 
VALUES ('created', COALESCE((SELECT value FROM db_metadata WHERE key='created'), CURRENT_TIMESTAMP), CURRENT_TIMESTAMP);

-- Create indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_error_stats_service ON error_stats(service_name);
CREATE INDEX IF NOT EXISTS idx_error_stats_last_seen ON error_stats(last_seen);
CREATE INDEX IF NOT EXISTS idx_log_summaries_date ON log_summaries(log_date);
CREATE INDEX IF NOT EXISTS idx_system_events_type ON system_events(event_type);
CREATE INDEX IF NOT EXISTS idx_system_events_created ON system_events(created_at);
CREATE INDEX IF NOT EXISTS idx_config_values_key ON config_values(config_key);
CREATE INDEX IF NOT EXISTS idx_config_discrepancies_key ON config_discrepancies(config_key);
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
# CONFIGURATION MANAGEMENT FUNCTIONS
# =============================================================================

# Default values from env-default and other template files (DO NOT SAVE THESE)
# These indicate a fresh install that hasn't been configured yet
declare -A DEFAULT_VALUES
DEFAULT_VALUES=(
    # Database defaults
    ["MYSQL_ROOT_PASSWORD"]="V3ryS3cUr3MYSQL_ROOT_P4ssw0rd"
    ["MYSQL_PASSWORD"]="SuperSecuredbuserPassword"
    ["MYSQL_USER"]="dbuser"
    # API secrets defaults
    ["KOJI_SECRET"]="SuperSecureKojiSecret"
    ["DRAGONITE_PASSWORD"]="SuperSecureDragoniteAdminPassword"
    ["DRAGONITE_API_SECRET"]="SuperSecureDragoniteApiSecret"
    ["GOLBAT_API_SECRET"]="SuperSecureGolbatApiSecret"
    ["GOLBAT_RAW_SECRET"]="SuperSecureGolbatRawSecret"
    # Common template placeholders
    ["DOMAIN"]="example.com"
    ["SERVER_IP"]="0.0.0.0"
    ["YOUR_DOMAIN"]="your.domain.com"
    ["YOUR_EMAIL"]="your@email.com"
    # Poracle defaults
    ["POKEMON_IMAGE_URL"]="https://raw.githubusercontent.com"
    ["WEATHER_TILE_URL"]=""
    # Bearer token defaults
    ["ROTOM_AUTH_BEARER"]="SuperSecretAuthBearerForAegisDevices"
)

# Check if a value is a default/template value (should not be saved)
is_default_value() {
    local key="$1"
    local value="$2"
    
    # Check against known defaults
    if [ -n "${DEFAULT_VALUES[$key]}" ]; then
        if [ "$value" = "${DEFAULT_VALUES[$key]}" ]; then
            return 0  # It's a default
        fi
    fi
    
    # Check for common template patterns
    if [[ "$value" =~ ^SuperSecure.*$ ]] || \
       [[ "$value" =~ ^V3ryS3cUr3.*$ ]] || \
       [[ "$value" =~ ^your.*$ ]] || \
       [[ "$value" =~ ^example\.com$ ]] || \
       [[ "$value" =~ ^YOUR_.*$ ]] || \
       [[ "$value" =~ ^CHANGE_ME.*$ ]] || \
       [[ "$value" =~ ^TODO.*$ ]] || \
       [[ "$value" =~ ^REPLACE.*$ ]] || \
       [[ "$value" = "0.0.0.0" ]] || \
       [[ "$value" = "localhost" && "$key" =~ DOMAIN|HOST|URL ]]; then
        return 0  # It's a default/template value
    fi
    
    return 1  # Not a default value
}

# =============================================================================
# CREDENTIAL VALIDATION FUNCTIONS
# =============================================================================

# Test MariaDB connection with given credentials
# Usage: validate_mariadb_credentials "user" "password" ["host"] ["port"]
# Returns: 0 = success, 1 = failed
validate_mariadb_credentials() {
    local user="$1"
    local password="$2"
    local host="${3:-localhost}"
    local port="${4:-3306}"
    
    [ -z "$user" ] || [ -z "$password" ] && return 1
    
    # Determine which mysql client to use
    local mysql_cmd=""
    if command -v mariadb &> /dev/null; then
        mysql_cmd="mariadb"
    elif command -v mysql &> /dev/null; then
        mysql_cmd="mysql"
    else
        # Try via Docker if no local client
        if docker ps --filter "name=database" --format "{{.Names}}" 2>/dev/null | grep -q "database"; then
            if docker exec database mariadb --version &>/dev/null; then
                mysql_cmd="docker exec database mariadb"
            elif docker exec database mysql --version &>/dev/null; then
                mysql_cmd="docker exec database mysql"
            fi
        fi
    fi
    
    if [ -z "$mysql_cmd" ]; then
        # No mysql client available - can't validate
        return 2  # Unknown (can't test)
    fi
    
    # Test connection
    if $mysql_cmd -u"$user" -p"$password" -h"$host" -P"$port" -e "SELECT 1" &>/dev/null; then
        return 0  # Success
    else
        return 1  # Failed
    fi
}

# Test MariaDB root credentials
validate_mariadb_root() {
    local password="$1"
    validate_mariadb_credentials "root" "$password"
    return $?
}

# Test if a database exists and is accessible
validate_database_exists() {
    local user="$1"
    local password="$2"
    local database="$3"
    local host="${4:-localhost}"
    
    [ -z "$database" ] && return 1
    
    local mysql_cmd=""
    if command -v mariadb &> /dev/null; then
        mysql_cmd="mariadb"
    elif command -v mysql &> /dev/null; then
        mysql_cmd="mysql"
    elif docker ps --filter "name=database" --format "{{.Names}}" 2>/dev/null | grep -q "database"; then
        if docker exec database mariadb --version &>/dev/null; then
            mysql_cmd="docker exec database mariadb"
        else
            mysql_cmd="docker exec database mysql"
        fi
    fi
    
    [ -z "$mysql_cmd" ] && return 2
    
    if $mysql_cmd -u"$user" -p"$password" -h"$host" -e "USE $database" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Validate a config value based on its key type
# Returns: 0 = valid, 1 = invalid, 2 = can't validate (no way to test)
validate_config_value_type() {
    local key="$1"
    local value="$2"
    local extra_param="$3"  # For some validations (e.g., user for password test)
    
    [ -z "$key" ] || [ -z "$value" ] && return 1
    
    case "$key" in
        MYSQL_ROOT_PASSWORD)
            validate_mariadb_root "$value"
            return $?
            ;;
        MYSQL_PASSWORD)
            # Need username to test - check if provided or use stored
            local db_user="${extra_param:-}"
            if [ -z "$db_user" ]; then
                db_user=$(get_config_value "MYSQL_USER" 2>/dev/null)
            fi
            if [ -n "$db_user" ]; then
                validate_mariadb_credentials "$db_user" "$value"
                return $?
            fi
            return 2  # Can't validate without user
            ;;
        MYSQL_USER)
            # Need password to test - check if provided or use stored
            local db_pass="${extra_param:-}"
            if [ -z "$db_pass" ]; then
                db_pass=$(get_config_value "MYSQL_PASSWORD" 2>/dev/null)
            fi
            if [ -n "$db_pass" ]; then
                validate_mariadb_credentials "$value" "$db_pass"
                return $?
            fi
            return 2  # Can't validate without password
            ;;
        PUID|PGID)
            # Validate it's a number
            if [[ "$value" =~ ^[0-9]+$ ]]; then
                return 0
            else
                return 1
            fi
            ;;
        *_SECRET|*_PASSWORD|*_TOKEN|*_BEARER)
            # These can't be validated without their respective services
            # Just check they're not empty and meet minimum length
            if [ ${#value} -ge 8 ]; then
                return 0
            else
                return 1  # Too short to be a real secret
            fi
            ;;
        *)
            # Unknown key type - can't validate
            return 2
            ;;
    esac
}

# Store config only if validation passes
# Usage: store_validated_config "key" "value" "source_file" "description" [is_secret] [extra_param]
# Returns: 0 = stored, 1 = validation failed, 2 = default value, 3 = store failed
store_validated_config() {
    local key="$1"
    local value="$2"
    local source_file="${3:-unknown}"
    local description="${4:-}"
    local is_secret="${5:-0}"
    local extra_param="${6:-}"
    
    [ -z "$key" ] || [ -z "$value" ] && return 3
    
    # Don't store default values
    if is_default_value "$key" "$value"; then
        return 2
    fi
    
    # Validate the value based on its type
    validate_config_value_type "$key" "$value" "$extra_param"
    local validation_result=$?
    
    if [ $validation_result -eq 1 ]; then
        # Validation failed
        return 1
    fi
    
    # Validation passed or couldn't be tested - store it
    store_config_value "$key" "$value" "$source_file" "$description" "$is_secret"
    return $?
}

# Prompt user for value with validation
# Usage: prompt_validated_config "key" "prompt_text" "source_file" "description" [is_secret] [validation_type]
# Returns the validated value or empty if user cancels
prompt_validated_config() {
    local key="$1"
    local prompt_text="$2"
    local source_file="${3:-unknown}"
    local description="${4:-}"
    local is_secret="${5:-0}"
    local extra_param="${6:-}"
    local max_attempts=3
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        ((attempt++))
        
        local value=""
        if [ "$is_secret" = "1" ]; then
            read -sp "$prompt_text: " value
            echo ""  # New line after hidden input
        else
            read -p "$prompt_text: " value
        fi
        
        # Check if empty
        if [ -z "$value" ]; then
            echo "  Value cannot be empty."
            continue
        fi
        
        # Check if default
        if is_default_value "$key" "$value"; then
            echo "  This appears to be a default/template value. Please enter a real value."
            continue
        fi
        
        # Validate
        validate_config_value_type "$key" "$value" "$extra_param"
        local result=$?
        
        if [ $result -eq 0 ]; then
            # Valid - store and return
            store_config_value "$key" "$value" "$source_file" "$description" "$is_secret"
            echo "$value"
            return 0
        elif [ $result -eq 1 ]; then
            # Invalid
            echo "  Validation failed for $key. Please try again."
            case "$key" in
                MYSQL_ROOT_PASSWORD)
                    echo "  Could not connect to MariaDB with this root password."
                    ;;
                MYSQL_PASSWORD|MYSQL_USER)
                    echo "  Could not authenticate with MariaDB using these credentials."
                    ;;
            esac
            continue
        else
            # Can't validate - accept it
            store_config_value "$key" "$value" "$source_file" "$description" "$is_secret"
            echo "$value"
            return 0
        fi
    done
    
    echo ""
    return 1  # Max attempts reached
}

# =============================================================================
# CONFIG STORAGE FUNCTIONS
# =============================================================================

# Store a configuration value (only if not a default)
# Usage: store_config_value "key" "value" "source_file" "description" [is_secret]
store_config_value() {
    local key="$1"
    local value="$2"
    local source_file="${3:-unknown}"
    local description="${4:-}"
    local is_secret="${5:-0}"
    
    [ -z "$key" ] || [ -z "$value" ] && return 1
    
    # Don't store default values
    if is_default_value "$key" "$value"; then
        return 2  # Indicates it was a default value
    fi
    
    # Escape single quotes
    value="${value//\'/\'\'}"
    description="${description//\'/\'\'}"
    
    sqlite3 "$SHELLDER_DB" <<EOF
INSERT INTO config_values (config_key, config_value, source_file, description, is_secret, last_verified, verified_match)
VALUES ('$key', '$value', '$source_file', '$description', $is_secret, CURRENT_TIMESTAMP, 1)
ON CONFLICT(config_key) DO UPDATE SET
    config_value = '$value',
    source_file = '$source_file',
    description = COALESCE(NULLIF('$description', ''), description),
    is_secret = $is_secret,
    last_verified = CURRENT_TIMESTAMP,
    verified_match = 1;
EOF
}

# Get a stored configuration value
# Usage: get_config_value "key"
get_config_value() {
    local key="$1"
    [ -z "$key" ] && return 1
    
    sqlite3 "$SHELLDER_DB" "SELECT config_value FROM config_values WHERE config_key = '$key';" 2>/dev/null
}

# Check if a config key exists in database
config_exists() {
    local key="$1"
    local count=$(sqlite3 "$SHELLDER_DB" "SELECT COUNT(*) FROM config_values WHERE config_key = '$key';" 2>/dev/null)
    [ "$count" -gt 0 ]
}

# Validate a config value against what's stored
# Returns: 0 = match, 1 = mismatch, 2 = not in database
validate_config_value() {
    local key="$1"
    local current_value="$2"
    local source_file="${3:-}"
    
    [ -z "$key" ] && return 1
    
    local stored_value=$(get_config_value "$key")
    
    if [ -z "$stored_value" ]; then
        return 2  # Not in database
    fi
    
    if [ "$current_value" = "$stored_value" ]; then
        # Update verification timestamp
        sqlite3 "$SHELLDER_DB" <<EOF
UPDATE config_values SET last_verified = CURRENT_TIMESTAMP, verified_match = 1 WHERE config_key = '$key';
EOF
        return 0  # Match
    else
        # Record discrepancy
        current_value="${current_value//\'/\'\'}"
        stored_value="${stored_value//\'/\'\'}"
        
        sqlite3 "$SHELLDER_DB" <<EOF
UPDATE config_values SET last_mismatch = CURRENT_TIMESTAMP, mismatch_count = mismatch_count + 1, verified_match = 0 WHERE config_key = '$key';
INSERT INTO config_discrepancies (config_key, expected_value, found_value, source_file)
VALUES ('$key', '$stored_value', '$current_value', '$source_file');
EOF
        return 1  # Mismatch
    fi
}

# Get all config discrepancies
get_config_discrepancies() {
    sqlite3 -header -column "$SHELLDER_DB" <<EOF
SELECT 
    config_key AS "Config Key",
    expected_value AS "Expected",
    found_value AS "Found",
    source_file AS "File",
    datetime(detected_at, 'localtime') AS "Detected"
FROM config_discrepancies
WHERE resolved = 0
ORDER BY detected_at DESC
LIMIT 50;
EOF
}

# Get all stored config values (masks secrets)
get_all_config_values() {
    sqlite3 -header -column "$SHELLDER_DB" <<EOF
SELECT 
    config_key AS "Key",
    CASE WHEN is_secret = 1 THEN '********' ELSE config_value END AS "Value",
    source_file AS "Source",
    CASE WHEN verified_match = 1 THEN 'OK' ELSE 'MISMATCH' END AS "Status",
    datetime(last_verified, 'localtime') AS "Last Check"
FROM config_values
ORDER BY config_key;
EOF
}

# Get config value for display (masks secrets)
get_config_display() {
    local key="$1"
    local is_secret=$(sqlite3 "$SHELLDER_DB" "SELECT is_secret FROM config_values WHERE config_key = '$key';" 2>/dev/null)
    
    if [ "$is_secret" = "1" ]; then
        local value=$(get_config_value "$key")
        if [ -n "$value" ]; then
            # Show first 2 and last 2 characters
            local len=${#value}
            if [ $len -gt 6 ]; then
                echo "${value:0:2}****${value: -2}"
            else
                echo "****"
            fi
        fi
    else
        get_config_value "$key"
    fi
}

# Check all configs from .env file against database
check_env_configs() {
    local env_file="${1:-.env}"
    local validate_before_store="${2:-true}"  # Whether to validate new configs before storing
    local discrepancies=0
    local new_configs=0
    local matched=0
    local rejected=0
    
    if [ ! -f "$env_file" ]; then
        echo "ENV_FILE_NOT_FOUND"
        return 1
    fi
    
    # First pass: load all values into an associative array
    declare -A env_values
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        [[ "$key" == "UID" || "$key" == "GID" ]] && continue
        
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        
        [ -z "$value" ] && continue
        env_values["$key"]="$value"
    done < "$env_file"
    
    # Process each config
    for key in "${!env_values[@]}"; do
        local value="${env_values[$key]}"
        
        # Skip default values
        if is_default_value "$key" "$value"; then
            continue
        fi
        
        # Check if config exists in database
        if config_exists "$key"; then
            validate_config_value "$key" "$value" "$env_file"
            local result=$?
            if [ $result -eq 0 ]; then
                ((matched++))
            elif [ $result -eq 1 ]; then
                ((discrepancies++))
            fi
        else
            # New config - validate before storing if enabled
            local should_store=true
            
            if [ "$validate_before_store" = "true" ]; then
                case "$key" in
                    MYSQL_ROOT_PASSWORD)
                        # Validate root password can connect
                        if ! validate_mariadb_root "$value" 2>/dev/null; then
                            should_store=false
                            ((rejected++))
                        fi
                        ;;
                    MYSQL_PASSWORD)
                        # Validate with user if available
                        local db_user="${env_values[MYSQL_USER]:-}"
                        if [ -n "$db_user" ]; then
                            if ! validate_mariadb_credentials "$db_user" "$value" 2>/dev/null; then
                                should_store=false
                                ((rejected++))
                            fi
                        fi
                        ;;
                    MYSQL_USER)
                        # Validate with password if available
                        local db_pass="${env_values[MYSQL_PASSWORD]:-}"
                        if [ -n "$db_pass" ]; then
                            if ! validate_mariadb_credentials "$value" "$db_pass" 2>/dev/null; then
                                should_store=false
                                ((rejected++))
                            fi
                        fi
                        ;;
                    PUID|PGID)
                        # Must be a number
                        if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                            should_store=false
                            ((rejected++))
                        fi
                        ;;
                    *_SECRET|*_PASSWORD|*_TOKEN|*_BEARER)
                        # Must be at least 8 characters
                        if [ ${#value} -lt 8 ]; then
                            should_store=false
                            ((rejected++))
                        fi
                        ;;
                esac
            fi
            
            if [ "$should_store" = "true" ]; then
                local is_secret=0
                if [[ "$key" =~ PASSWORD|SECRET|TOKEN|KEY|BEARER ]]; then
                    is_secret=1
                fi
                store_config_value "$key" "$value" "$env_file" "" "$is_secret"
                ((new_configs++))
            fi
        fi
    done
    
    echo "$matched|$discrepancies|$new_configs|$rejected"
}

# Parse and store configs from a specific file type
parse_and_store_configs() {
    local file="$1"
    local file_type="${2:-auto}"
    
    [ ! -f "$file" ] && return 1
    
    case "$file_type" in
        env|auto)
            if [[ "$file" =~ \.env$ ]] || [[ "$file" == "env-default" ]]; then
                while IFS='=' read -r key value; do
                    [[ "$key" =~ ^#.*$ ]] && continue
                    [[ -z "$key" ]] && continue
                    value="${value%\"}"
                    value="${value#\"}"
                    [ -z "$value" ] && continue
                    
                    if ! is_default_value "$key" "$value"; then
                        local is_secret=0
                        [[ "$key" =~ PASSWORD|SECRET|TOKEN|KEY|BEARER ]] && is_secret=1
                        store_config_value "$key" "$value" "$file" "" "$is_secret"
                    fi
                done < "$file"
            fi
            ;;
        json)
            # For JSON files - extract key values (basic parsing)
            if command -v jq &> /dev/null; then
                # Use jq if available
                jq -r 'to_entries | .[] | "\(.key)=\(.value)"' "$file" 2>/dev/null | while IFS='=' read -r key value; do
                    [ -z "$key" ] && continue
                    if ! is_default_value "$key" "$value"; then
                        store_config_value "$key" "$value" "$file" ""
                    fi
                done
            fi
            ;;
        toml)
            # For TOML files - basic key=value extraction
            grep -E "^[a-zA-Z_]+\s*=" "$file" 2>/dev/null | while IFS='=' read -r key value; do
                key=$(echo "$key" | tr -d ' ')
                value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"'"'")
                [ -z "$key" ] && continue
                if ! is_default_value "$key" "$value"; then
                    store_config_value "$key" "$value" "$file" ""
                fi
            done
            ;;
    esac
}

# Resolve a discrepancy (mark as resolved)
resolve_discrepancy() {
    local id="$1"
    sqlite3 "$SHELLDER_DB" "UPDATE config_discrepancies SET resolved = 1, resolved_at = CURRENT_TIMESTAMP WHERE id = $id;"
}

# Resolve all discrepancies for a key
resolve_discrepancies_for_key() {
    local key="$1"
    sqlite3 "$SHELLDER_DB" "UPDATE config_discrepancies SET resolved = 1, resolved_at = CURRENT_TIMESTAMP WHERE config_key = '$key' AND resolved = 0;"
}

# Update stored config value (when user confirms a change)
update_stored_config() {
    local key="$1"
    local new_value="$2"
    local source_file="${3:-}"
    
    if is_default_value "$key" "$new_value"; then
        return 2  # Don't store defaults
    fi
    
    new_value="${new_value//\'/\'\'}"
    
    sqlite3 "$SHELLDER_DB" <<EOF
UPDATE config_values SET 
    config_value = '$new_value',
    source_file = COALESCE(NULLIF('$source_file', ''), source_file),
    last_verified = CURRENT_TIMESTAMP,
    verified_match = 1
WHERE config_key = '$key';
EOF

    # Resolve any pending discrepancies
    resolve_discrepancies_for_key "$key"
}

# Delete a stored config value
delete_config_value() {
    local key="$1"
    sqlite3 "$SHELLDER_DB" "DELETE FROM config_values WHERE config_key = '$key';"
}

# Clear all config discrepancies
clear_config_discrepancies() {
    sqlite3 "$SHELLDER_DB" "DELETE FROM config_discrepancies;"
}

# Get count of unresolved discrepancies
get_discrepancy_count() {
    sqlite3 "$SHELLDER_DB" "SELECT COUNT(*) FROM config_discrepancies WHERE resolved = 0;" 2>/dev/null
}

# Get count of stored configs
get_config_count() {
    sqlite3 "$SHELLDER_DB" "SELECT COUNT(*) FROM config_values;" 2>/dev/null
}

# Run full config validation on all known files
run_full_config_check() {
    local total_discrepancies=0
    
    # Check .env file
    if [ -f ".env" ]; then
        local result=$(check_env_configs ".env")
        local disc=$(echo "$result" | cut -d'|' -f2)
        total_discrepancies=$((total_discrepancies + disc))
    fi
    
    # Can add more file checks here as needed
    
    echo "$total_discrepancies"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Auto-initialize database when this file is sourced
if ! check_shellder_db 2>/dev/null; then
    init_shellder_db 2>/dev/null
fi

