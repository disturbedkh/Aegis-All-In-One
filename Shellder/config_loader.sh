#!/bin/bash
# =============================================================================
# Shellder Configuration Loader (Shell)
# =============================================================================
# Sources configuration from shellder_config.toml and exports as shell variables.
#
# Usage in scripts:
#   source "$(dirname "$0")/config_loader.sh"
#   
#   # Then use variables like:
#   echo "Aegis root: $AEGIS_ROOT"
#   echo "Dragonite container: $DRAGONITE_CONTAINER_NAME"
#   echo "Golbat config: $GOLBAT_CONFIG_FILE"
#
# All variables are prefixed with the component name in UPPERCASE.
# =============================================================================

# Determine script directory and Aegis root
SHELLDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEGIS_ROOT="$(dirname "$SHELLDER_DIR")"

# Config file path
SHELLDER_CONFIG_FILE="${SHELLDER_DIR}/shellder_config.toml"

# =============================================================================
# TOML PARSER FUNCTION
# =============================================================================
# Simple TOML parser - handles basic key=value pairs and sections
# Does not handle arrays, multi-line strings, or complex TOML features

parse_toml() {
    local file="$1"
    local current_section=""
    
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Remove leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        
        # Check for section header [section] or [section.subsection]
        if [[ "$line" =~ ^\[([a-zA-Z0-9_.]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            # Convert dots to underscores for variable names
            current_section="${current_section//./_}"
            continue
        fi
        
        # Parse key = value
        if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)\ *=\ *(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # Remove quotes from value
            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"
            
            # Handle boolean values
            [[ "$value" == "true" ]] && value="1"
            [[ "$value" == "false" ]] && value="0"
            
            # Create variable name: SECTION_KEY (uppercase)
            local var_name
            if [[ -n "$current_section" ]]; then
                var_name="${current_section^^}_${key^^}"
            else
                var_name="${key^^}"
            fi
            
            # Export the variable
            export "$var_name"="$value"
        fi
    done < "$file"
}

# =============================================================================
# SET DEFAULTS
# =============================================================================
# These defaults match the TOML file and are used if the file is missing

set_defaults() {
    # General
    export GENERAL_AEGIS_ROOT=""
    export GENERAL_SHELLDER_DATA_DIR="Shellder/data"
    export GENERAL_DOCKER_COMPOSE_FILE="docker-compose.yaml"
    export GENERAL_ENV_FILE=".env"
    
    # Database
    export DATABASE_ENABLED="1"
    export DATABASE_LOCAL="1"
    export DATABASE_CONTAINER_NAME="database"
    export DATABASE_HOST="localhost"
    export DATABASE_PORT="3306"
    export DATABASE_USERNAME=""
    export DATABASE_PASSWORD=""
    export DATABASE_ROOT_PASSWORD=""
    export DATABASE_DB_GOLBAT="golbat"
    export DATABASE_DB_DRAGONITE="dragonite"
    export DATABASE_DB_REACTMAP="reactmap"
    export DATABASE_DB_KOJI="koji"
    export DATABASE_DB_PORACLE="poracle"
    
    # Dragonite
    export DRAGONITE_ENABLED="1"
    export DRAGONITE_LOCAL="1"
    export DRAGONITE_CONTAINER_NAME="dragonite"
    export DRAGONITE_HOST="localhost"
    export DRAGONITE_API_PORT="7272"
    export DRAGONITE_ADMIN_PORT="6002"
    export DRAGONITE_CONFIG_FILE="unown/dragonite_config.toml"
    export DRAGONITE_CONFIG_DEFAULT="unown/dragonite_config-default.toml"
    export DRAGONITE_ADMIN_CONTAINER_NAME="admin"
    
    # Golbat
    export GOLBAT_ENABLED="1"
    export GOLBAT_LOCAL="1"
    export GOLBAT_CONTAINER_NAME="golbat"
    export GOLBAT_HOST="localhost"
    export GOLBAT_API_PORT="9001"
    export GOLBAT_GRPC_PORT="50001"
    export GOLBAT_CONFIG_FILE="unown/golbat_config.toml"
    export GOLBAT_CONFIG_DEFAULT="unown/golbat_config-default.toml"
    export GOLBAT_CACHE_DIR="unown/golbat_cache"
    
    # Rotom
    export ROTOM_ENABLED="1"
    export ROTOM_LOCAL="1"
    export ROTOM_CONTAINER_NAME="rotom"
    export ROTOM_HOST="localhost"
    export ROTOM_DEVICE_PORT="7070"
    export ROTOM_CONTROLLER_PORT="7071"
    export ROTOM_WEB_PORT="6003"
    export ROTOM_CONFIG_FILE="unown/rotom_config.json"
    export ROTOM_CONFIG_DEFAULT="unown/rotom_config-default.json"
    export ROTOM_JOBS_DIR="unown/rotom_jobs"
    
    # Xilriws
    export XILRIWS_ENABLED="1"
    export XILRIWS_LOCAL="1"
    export XILRIWS_CONTAINER_NAME="xilriws"
    export XILRIWS_HOST="localhost"
    export XILRIWS_PORT="5090"
    export XILRIWS_PROXIES_FILE="unown/proxies.txt"
    
    # ReactMap
    export REACTMAP_ENABLED="1"
    export REACTMAP_LOCAL="1"
    export REACTMAP_CONTAINER_NAME="reactmap"
    export REACTMAP_HOST="localhost"
    export REACTMAP_PORT="6001"
    export REACTMAP_CONFIG_FILE="reactmap/local.json"
    export REACTMAP_CONFIG_DEFAULT="reactmap/local-default.json"
    export REACTMAP_ENV_FILE="reactmap/env"
    
    # Koji
    export KOJI_ENABLED="1"
    export KOJI_LOCAL="1"
    export KOJI_CONTAINER_NAME="koji"
    export KOJI_HOST="localhost"
    export KOJI_PORT="6004"
    
    # Poracle
    export PORACLE_ENABLED="0"
    export PORACLE_LOCAL="1"
    export PORACLE_CONTAINER_NAME="poracle"
    export PORACLE_HOST="localhost"
    export PORACLE_PORT="6007"
    export PORACLE_CONFIG_DIR="Poracle/config"
    export PORACLE_CONFIG_FILE="Poracle/config/local.json"
    export PORACLE_GEOFENCE_DIR="Poracle/geofence"
    
    # Fletchling
    export FLETCHLING_ENABLED="0"
    export FLETCHLING_LOCAL="1"
    export FLETCHLING_CONTAINER_NAME="fletchling"
    export FLETCHLING_CONFIG_FILE="fletchling.toml"
    export FLETCHLING_DATA_DIR="fletchling"
    
    # Grafana
    export GRAFANA_ENABLED="1"
    export GRAFANA_LOCAL="1"
    export GRAFANA_CONTAINER_NAME="grafana"
    export GRAFANA_HOST="localhost"
    export GRAFANA_PORT="6006"
    export GRAFANA_DASHBOARDS_DIR="grafana"
    
    # VictoriaMetrics
    export VICTORIAMETRICS_ENABLED="1"
    export VICTORIAMETRICS_LOCAL="1"
    export VICTORIAMETRICS_CONTAINER_NAME="victoriametrics"
    export VICTORIAMETRICS_HOST="localhost"
    export VICTORIAMETRICS_PORT="8428"
    export VICTORIAMETRICS_DATA_DIR="victoriametrics/data"
    export VICTORIAMETRICS_VMAGENT_CONTAINER_NAME="vmagent"
    export VICTORIAMETRICS_VMAGENT_CONFIG_FILE="vmagent/prometheus.yml"
    export VICTORIAMETRICS_VMAGENT_DATA_DIR="vmagent/data"
    
    # phpMyAdmin
    export PHPMYADMIN_ENABLED="1"
    export PHPMYADMIN_LOCAL="1"
    export PHPMYADMIN_CONTAINER_NAME="pma"
    export PHPMYADMIN_HOST="localhost"
    export PHPMYADMIN_PORT="6005"
    
    # Shellder
    export SHELLDER_WEB_PORT="5000"
    export SHELLDER_API_PORT="5050"
    export SHELLDER_LOG_FILE="Shellder/shellder.log"
    export SHELLDER_LOG_LEVEL="INFO"
    export SHELLDER_DB_FILE="Shellder/shellder.db"
    
    # Nginx
    export NGINX_ENABLED="1"
    export NGINX_CONFIG_DIR="/etc/nginx"
    export NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
    export NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
    export NGINX_SSL_DIR="/etc/letsencrypt/live"
    
    # Remote
    export REMOTE_SSH_ENABLED="0"
    export REMOTE_SSH_USER=""
    export REMOTE_SSH_KEY_FILE=""
    export REMOTE_API_KEY=""
    export REMOTE_ALLOWED_HOSTS=""
    
    # Paths
    export PATHS_MYSQL_DATA="mysql_data"
    export PATHS_INIT_DIR="init"
    export PATHS_SCANNER_LOGS="unown/logs"
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Resolve a path relative to AEGIS_ROOT
resolve_path() {
    local path="$1"
    if [[ "$path" == /* ]]; then
        echo "$path"
    else
        echo "${AEGIS_ROOT}/${path}"
    fi
}

# Check if component is enabled
is_enabled() {
    local component="${1^^}"
    local var_name="${component}_ENABLED"
    [[ "${!var_name}" == "1" ]]
}

# Check if component is local (vs remote)
is_local() {
    local component="${1^^}"
    local var_name="${component}_LOCAL"
    [[ "${!var_name}" == "1" ]]
}

# Get container name for component
get_container() {
    local component="${1^^}"
    local var_name="${component}_CONTAINER_NAME"
    echo "${!var_name}"
}

# Get host for component
get_host() {
    local component="${1^^}"
    if is_local "$1"; then
        echo "localhost"
    else
        local var_name="${component}_HOST"
        echo "${!var_name:-localhost}"
    fi
}

# Get port for component
get_port() {
    local component="${1^^}"
    local port_type="${2:-PORT}"
    local var_name="${component}_${port_type^^}"
    echo "${!var_name}"
}

# Get config file path for component
get_config_file() {
    local component="${1^^}"
    local var_name="${component}_CONFIG_FILE"
    local path="${!var_name}"
    if [[ -n "$path" ]]; then
        resolve_path "$path"
    fi
}

# Get all enabled local container names
get_local_containers() {
    local containers=()
    local components=(database dragonite golbat rotom xilriws reactmap koji poracle fletchling grafana victoriametrics phpmyadmin)
    
    for comp in "${components[@]}"; do
        if is_enabled "$comp" && is_local "$comp"; then
            containers+=("$(get_container "$comp")")
            # Handle special cases
            if [[ "$comp" == "dragonite" ]]; then
                containers+=("$DRAGONITE_ADMIN_CONTAINER_NAME")
            elif [[ "$comp" == "victoriametrics" ]]; then
                containers+=("$VICTORIAMETRICS_VMAGENT_CONTAINER_NAME")
            fi
        fi
    done
    
    echo "${containers[@]}"
}

# =============================================================================
# LOAD CONFIGURATION
# =============================================================================

# Set defaults first
set_defaults

# Parse config file (overrides defaults)
if [[ -f "$SHELLDER_CONFIG_FILE" ]]; then
    parse_toml "$SHELLDER_CONFIG_FILE"
fi

# Apply custom aegis root if specified
if [[ -n "$GENERAL_AEGIS_ROOT" ]]; then
    AEGIS_ROOT="$GENERAL_AEGIS_ROOT"
fi

# Export key paths
export AEGIS_ROOT
export SHELLDER_DIR
export SHELLDER_CONFIG_FILE

# Export resolved paths for common files
export DOCKER_COMPOSE_FILE="$(resolve_path "$GENERAL_DOCKER_COMPOSE_FILE")"
export ENV_FILE="$(resolve_path "$GENERAL_ENV_FILE")"

# =============================================================================
# SCRIPT INFO (when run directly)
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Shellder Configuration Loader"
    echo "=============================="
    echo ""
    echo "AEGIS_ROOT: $AEGIS_ROOT"
    echo "SHELLDER_DIR: $SHELLDER_DIR"
    echo "Config File: $SHELLDER_CONFIG_FILE"
    echo ""
    echo "Enabled Components:"
    for comp in database dragonite golbat rotom xilriws reactmap koji poracle fletchling grafana victoriametrics phpmyadmin; do
        if is_enabled "$comp"; then
            local_status="local"
            is_local "$comp" || local_status="remote"
            echo "  ✓ $comp ($local_status)"
        else
            echo "  ✗ $comp (disabled)"
        fi
    done
    echo ""
    echo "Local Containers:"
    get_local_containers
fi

