#!/bin/bash

# Aegis All-in-One Nginx Reverse Proxy Setup Script
# This script sets up nginx reverse proxies for all Aegis services with optional SSL
# Includes Fail2Ban configuration for brute-force and bot protection
# Includes optional Authelia setup for SSO and 2FA authentication

set -e

# Global variables
AUTHELIA_ENABLED=false
AUTHELIA_SUBDOMAIN="auth"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored messages
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run this script as root (e.g., sudo bash nginx-setup.sh)"
        exit 1
    fi
}

# Check and install fail2ban
setup_fail2ban() {
    echo ""
    print_info "=== Fail2Ban Setup ==="
    
    # Check if fail2ban is installed
    if command -v fail2ban-client &> /dev/null; then
        print_success "Fail2Ban is already installed"
        FAIL2BAN_INSTALLED=true
    else
        print_warning "Fail2Ban is not installed"
        read -p "Would you like to install Fail2Ban for brute-force protection? (y/n) [y]: " INSTALL_F2B
        INSTALL_F2B=${INSTALL_F2B:-y}
        
        if [ "$INSTALL_F2B" = "y" ] || [ "$INSTALL_F2B" = "Y" ]; then
            install_fail2ban
            FAIL2BAN_INSTALLED=true
        else
            print_warning "Skipping Fail2Ban installation"
            FAIL2BAN_INSTALLED=false
            return
        fi
    fi
    
    # Configure fail2ban for nginx
    if [ "$FAIL2BAN_INSTALLED" = true ]; then
        read -p "Would you like to configure Fail2Ban jails for Nginx protection? (y/n) [y]: " CONFIGURE_F2B
        CONFIGURE_F2B=${CONFIGURE_F2B:-y}
        
        if [ "$CONFIGURE_F2B" = "y" ] || [ "$CONFIGURE_F2B" = "Y" ]; then
            configure_fail2ban_jails
        fi
    fi
}

# Install fail2ban
install_fail2ban() {
    print_info "Installing Fail2Ban..."
    
    if command -v apt-get &> /dev/null; then
        apt-get update -y
        apt-get install -y fail2ban
    elif command -v yum &> /dev/null; then
        yum install -y epel-release
        yum install -y fail2ban
    elif command -v dnf &> /dev/null; then
        dnf install -y fail2ban
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm fail2ban
    else
        print_error "Could not detect package manager. Please install Fail2Ban manually."
        return
    fi
    
    # Enable and start fail2ban
    systemctl enable fail2ban
    systemctl start fail2ban
    
    print_success "Fail2Ban installed and started"
}

# Configure fail2ban jails for nginx
configure_fail2ban_jails() {
    print_info "Configuring Fail2Ban jails for Nginx..."
    
    # Get ban settings from user
    read -p "Enter ban time in seconds [3600] (1 hour): " BAN_TIME
    BAN_TIME=${BAN_TIME:-3600}
    
    read -p "Enter find time in seconds [600] (10 minutes): " FIND_TIME
    FIND_TIME=${FIND_TIME:-600}
    
    read -p "Enter max retry attempts before ban [5]: " MAX_RETRY
    MAX_RETRY=${MAX_RETRY:-5}
    
    # Create custom filter for nginx bad requests
    print_info "Creating Nginx filters..."
    
    # Filter for nginx authentication failures
    cat > /etc/fail2ban/filter.d/nginx-http-auth.conf << 'EOF'
# Fail2Ban filter for nginx basic auth failures
[Definition]
failregex = ^ \[error\] \d+#\d+: \*\d+ user ".*":? (password mismatch|was not found in ".*"), client: <HOST>, server: \S+, request: "\S+ \S+ HTTP/\d+\.\d+", host: "\S+"
            ^ \[error\] \d+#\d+: \*\d+ no user/password was provided for basic authentication, client: <HOST>, server: \S+, request: "\S+ \S+ HTTP/\d+\.\d+", host: "\S+"
ignoreregex =
EOF

    # Filter for nginx forbidden/denied requests
    cat > /etc/fail2ban/filter.d/nginx-forbidden.conf << 'EOF'
# Fail2Ban filter for nginx forbidden requests
[Definition]
failregex = ^ \[error\] \d+#\d+: \*\d+ access forbidden by rule, client: <HOST>
            ^ \[error\] \d+#\d+: \*\d+ directory index of ".*" is forbidden, client: <HOST>
ignoreregex =
EOF

    # Filter for nginx bad bots and scanners
    cat > /etc/fail2ban/filter.d/nginx-badbots.conf << 'EOF'
# Fail2Ban filter for bad bots and vulnerability scanners
[Definition]
failregex = ^<HOST> -.*"(GET|POST|HEAD).*HTTP.*" (404|444|403|400) .*".*(?i)(nikto|sqlmap|nmap|masscan|zgrab|curl|wget|python-requests|go-http-client|libwww|lwp-trivial|HTTrack|harvest|extract|grab|miner).*"$
            ^<HOST> -.*"(GET|POST|HEAD).*(wp-login|wp-admin|xmlrpc|\.env|\.git|phpmyadmin|admin|shell|eval).*HTTP.*"
            ^<HOST> -.*".*(?:SELECT|UNION|INSERT|DROP|UPDATE|DELETE|WHERE|FROM).*"
ignoreregex =
EOF

    # Filter for nginx limit req (rate limiting)
    cat > /etc/fail2ban/filter.d/nginx-limit-req.conf << 'EOF'
# Fail2Ban filter for nginx rate limit violations
[Definition]
failregex = limiting requests, excess:.* by zone.*client: <HOST>
ignoreregex =
EOF

    # Filter for nginx botsearch (common attack patterns)
    cat > /etc/fail2ban/filter.d/nginx-botsearch.conf << 'EOF'
# Fail2Ban filter for common attack URL patterns
[Definition]
failregex = ^<HOST> - .* "(GET|POST|HEAD) /(cgi-bin|scripts|admin|wp-content|wp-includes)/.*" (404|403|400)
            ^<HOST> - .* "(GET|POST|HEAD) /\.(env|git|svn|htaccess|htpasswd).*" (404|403|400)
            ^<HOST> - .* "(GET|POST|HEAD) /(phpmyadmin|pma|mysql|myadmin|phpMyAdmin)/.*" (404|403|400)
            ^<HOST> - .* "(GET|POST|HEAD) /.*\.(asp|aspx|jsp|cgi|pl).*" (404|403|400)
ignoreregex =
EOF

    # Create jail.local configuration
    print_info "Creating Fail2Ban jail configuration..."
    
    cat > /etc/fail2ban/jail.local << EOF
# Fail2Ban Local Configuration for Aegis
# Generated by nginx-setup.sh

[DEFAULT]
# Ban settings
bantime = ${BAN_TIME}
findtime = ${FIND_TIME}
maxretry = ${MAX_RETRY}

# Action to take (ban IP using iptables/nftables)
banaction = iptables-multiport
banaction_allports = iptables-allports

# Ignore local IPs
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16

# Backend
backend = systemd

#
# JAILS
#

# SSH Protection (if sshd is running)
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3

# Nginx HTTP Basic Auth Protection
[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 3

# Nginx Forbidden Requests
[nginx-forbidden]
enabled = true
port = http,https
filter = nginx-forbidden
logpath = /var/log/nginx/error.log
maxretry = 5

# Nginx Bad Bots & Scanners
[nginx-badbots]
enabled = true
port = http,https
filter = nginx-badbots
logpath = /var/log/nginx/access.log
maxretry = 2
bantime = 86400

# Nginx Botsearch (common attack patterns)
[nginx-botsearch]
enabled = true
port = http,https
filter = nginx-botsearch
logpath = /var/log/nginx/access.log
maxretry = 5

# Nginx Rate Limit Violations
[nginx-limit-req]
enabled = true
port = http,https
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
maxretry = 10

# Recidive - ban repeat offenders for longer
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = iptables-allports
bantime = 604800
findtime = 86400
maxretry = 3
EOF

    # Restart fail2ban to apply changes
    print_info "Restarting Fail2Ban..."
    systemctl restart fail2ban
    
    # Wait a moment for fail2ban to start
    sleep 2
    
    # Check status
    if systemctl is-active --quiet fail2ban; then
        print_success "Fail2Ban configured and running"
        
        # Show active jails
        print_info "Active Fail2Ban jails:"
        fail2ban-client status 2>/dev/null | grep "Jail list" || echo "  (checking jails...)"
    else
        print_error "Fail2Ban failed to start. Check: journalctl -u fail2ban"
    fi
}

# Setup Authelia SSO
setup_authelia() {
    echo ""
    print_info "=== Authelia SSO Setup ==="
    echo ""
    print_info "Authelia provides Single Sign-On (SSO) with:"
    echo "  - Two-Factor Authentication (2FA/MFA)"
    echo "  - Time-based One-Time Passwords (TOTP)"
    echo "  - Universal 2nd Factor (U2F/WebAuthn)"
    echo "  - Access control policies"
    echo "  - Session management"
    echo ""
    
    read -p "Would you like to setup Authelia for advanced authentication? (y/n) [n]: " SETUP_AUTHELIA
    SETUP_AUTHELIA=${SETUP_AUTHELIA:-n}
    
    if [ "$SETUP_AUTHELIA" != "y" ] && [ "$SETUP_AUTHELIA" != "Y" ]; then
        print_warning "Skipping Authelia setup. Basic auth will be used if enabled."
        return
    fi
    
    AUTHELIA_ENABLED=true
    
    # Check for Docker
    if ! command -v docker &> /dev/null; then
        print_error "Docker is required for Authelia. Please install Docker first."
        AUTHELIA_ENABLED=false
        return
    fi
    
    # Get Authelia subdomain
    read -p "Enter subdomain for Authelia portal [auth]: " AUTHELIA_SUBDOMAIN
    AUTHELIA_SUBDOMAIN=${AUTHELIA_SUBDOMAIN:-auth}
    
    # Get admin user details
    echo ""
    print_info "Configure Authelia admin user:"
    read -p "Enter admin username [admin]: " AUTHELIA_USER
    AUTHELIA_USER=${AUTHELIA_USER:-admin}
    
    read -p "Enter admin display name [Administrator]: " AUTHELIA_DISPLAY_NAME
    AUTHELIA_DISPLAY_NAME=${AUTHELIA_DISPLAY_NAME:-Administrator}
    
    read -p "Enter admin email: " AUTHELIA_EMAIL
    if [ -z "$AUTHELIA_EMAIL" ]; then
        AUTHELIA_EMAIL="${AUTHELIA_USER}@${BASE_DOMAIN}"
        print_warning "Using default email: $AUTHELIA_EMAIL"
    fi
    
    read -s -p "Enter admin password: " AUTHELIA_PASSWORD
    echo ""
    if [ -z "$AUTHELIA_PASSWORD" ]; then
        AUTHELIA_PASSWORD=$(openssl rand -base64 16)
        print_warning "Generated random password: $AUTHELIA_PASSWORD"
    fi
    
    # Generate secrets
    print_info "Generating secure secrets..."
    JWT_SECRET=$(openssl rand -hex 32)
    SESSION_SECRET=$(openssl rand -hex 32)
    STORAGE_ENCRYPTION_KEY=$(openssl rand -hex 32)
    
    # Hash the password using argon2
    print_info "Hashing password..."
    if command -v argon2 &> /dev/null; then
        HASHED_PASSWORD=$(echo -n "$AUTHELIA_PASSWORD" | argon2 "$(openssl rand -hex 16)" -id -e -k 65536 -t 3 -p 4)
    else
        # Use Docker to hash if argon2 not installed
        HASHED_PASSWORD=$(docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password "$AUTHELIA_PASSWORD" 2>/dev/null | grep "Digest:" | awk '{print $2}')
        if [ -z "$HASHED_PASSWORD" ]; then
            # Fallback to a known hash format placeholder
            print_warning "Could not hash password. Using bcrypt fallback..."
            HASHED_PASSWORD=$(docker run --rm httpd:2.4-alpine htpasswd -nbB "" "$AUTHELIA_PASSWORD" | cut -d: -f2)
        fi
    fi
    
    # Create Authelia directory structure
    create_authelia_config
    
    # Create nginx snippets for Authelia
    create_authelia_nginx_snippets
    
    # Create Authelia nginx config
    create_authelia_nginx_config
    
    # Start Authelia container
    start_authelia_container
    
    print_success "Authelia setup complete"
}

# Create Authelia configuration files
create_authelia_config() {
    print_info "Creating Authelia configuration..."
    
    AUTHELIA_DIR="/opt/authelia"
    mkdir -p "$AUTHELIA_DIR/config"
    mkdir -p "$AUTHELIA_DIR/data"
    
    # Create users database
    cat > "$AUTHELIA_DIR/config/users_database.yml" << EOF
# Authelia Users Database
# Generated by Aegis nginx-setup.sh

users:
  ${AUTHELIA_USER}:
    disabled: false
    displayname: "${AUTHELIA_DISPLAY_NAME}"
    password: "${HASHED_PASSWORD}"
    email: ${AUTHELIA_EMAIL}
    groups:
      - admins
      - users
EOF

    # Create main configuration
    cat > "$AUTHELIA_DIR/config/configuration.yml" << EOF
# Authelia Configuration
# Generated by Aegis nginx-setup.sh
# Documentation: https://www.authelia.com/configuration/

# Theme (light, dark, grey, auto)
theme: dark

# JWT Secret for identity verification
jwt_secret: ${JWT_SECRET}

# Default redirection URL
default_redirection_url: https://${BASE_DOMAIN}

# Server configuration
server:
  host: 0.0.0.0
  port: 9091
  path: ""
  buffers:
    read: 4096
    write: 4096
  timeouts:
    read: 6s
    write: 6s
    idle: 30s

# Logging
log:
  level: info
  format: text
  file_path: /config/authelia.log
  keep_stdout: true

# TOTP Configuration (for 2FA)
totp:
  disable: false
  issuer: ${BASE_DOMAIN}
  algorithm: sha1
  digits: 6
  period: 30
  skew: 1
  secret_size: 32

# WebAuthn/U2F Configuration (for hardware keys)
webauthn:
  disable: false
  display_name: Aegis Auth
  attestation_conveyance_preference: indirect
  user_verification: preferred
  timeout: 60s

# Authentication Backend (file-based for simplicity)
authentication_backend:
  password_reset:
    disable: false
  file:
    path: /config/users_database.yml
    password:
      algorithm: argon2id
      iterations: 3
      memory: 65536
      parallelism: 4
      key_length: 32
      salt_length: 16

# Access Control Rules
access_control:
  default_policy: deny
  
  rules:
    # Public access to ReactMap
    - domain: "${SUBDOMAIN_REACTMAP}.${BASE_DOMAIN}"
      policy: bypass
    
    # Public access to Poracle webhooks
    - domain: "${SUBDOMAIN_PORACLE}.${BASE_DOMAIN}"
      policy: bypass
    
    # Grafana has its own auth
    - domain: "${SUBDOMAIN_GRAFANA}.${BASE_DOMAIN}"
      policy: bypass
    
    # Require 2FA for admin services
    - domain: "${SUBDOMAIN_ADMIN}.${BASE_DOMAIN}"
      policy: two_factor
      subject:
        - "group:admins"
    
    - domain: "${SUBDOMAIN_ROTOM}.${BASE_DOMAIN}"
      policy: two_factor
      subject:
        - "group:admins"
    
    - domain: "${SUBDOMAIN_KOJI}.${BASE_DOMAIN}"
      policy: two_factor
      subject:
        - "group:admins"
    
    - domain: "${SUBDOMAIN_PMA}.${BASE_DOMAIN}"
      policy: two_factor
      subject:
        - "group:admins"
    
    # Auth portal itself
    - domain: "${AUTHELIA_SUBDOMAIN}.${BASE_DOMAIN}"
      policy: bypass

# Session Configuration
session:
  name: aegis_authelia_session
  domain: ${BASE_DOMAIN}
  same_site: lax
  secret: ${SESSION_SECRET}
  expiration: 1h
  inactivity: 5m
  remember_me_duration: 1M

# Regulation (brute-force protection)
regulation:
  max_retries: 3
  find_time: 2m
  ban_time: 5m

# Storage (SQLite for simplicity)
storage:
  encryption_key: ${STORAGE_ENCRYPTION_KEY}
  local:
    path: /data/db.sqlite3

# Notifier (filesystem for basic setup)
notifier:
  disable_startup_check: false
  filesystem:
    filename: /config/notification.txt
EOF

    # Set permissions
    chmod 600 "$AUTHELIA_DIR/config/configuration.yml"
    chmod 600 "$AUTHELIA_DIR/config/users_database.yml"
    
    print_success "Authelia configuration created at $AUTHELIA_DIR"
}

# Create nginx snippets for Authelia
create_authelia_nginx_snippets() {
    print_info "Creating Nginx snippets for Authelia..."
    
    mkdir -p /etc/nginx/snippets
    
    # Authelia location snippet
    cat > /etc/nginx/snippets/authelia-location.conf << 'EOF'
# Authelia Authentication Location
# Include this in protected server blocks

internal;
set $upstream_authelia http://127.0.0.1:9091/api/verify;
proxy_pass $upstream_authelia;

proxy_pass_request_body off;
proxy_set_header Content-Length "";

# Timeout if the real server is dead
proxy_connect_timeout 3s;
proxy_read_timeout 5s;
proxy_send_timeout 5s;

# Pass request info to Authelia
proxy_set_header Host $host;
proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $http_host;
proxy_set_header X-Forwarded-Uri $request_uri;
proxy_set_header X-Forwarded-Ssl on;

# Response headers from Authelia
proxy_set_header X-Authelia-Redirect $scheme://$http_host$request_uri;

# Cache auth status for performance
proxy_cache_bypass $cookie_session;
proxy_no_cache $cookie_session;
EOF

    # Authelia auth request snippet
    cat > /etc/nginx/snippets/authelia-authrequest.conf << EOF
# Authelia Auth Request Configuration
# Include this in location blocks that need protection

auth_request /authelia;
auth_request_set \$target_url \$scheme://\$http_host\$request_uri;
auth_request_set \$user \$upstream_http_remote_user;
auth_request_set \$groups \$upstream_http_remote_groups;
auth_request_set \$name \$upstream_http_remote_name;
auth_request_set \$email \$upstream_http_remote_email;

proxy_set_header Remote-User \$user;
proxy_set_header Remote-Groups \$groups;
proxy_set_header Remote-Name \$name;
proxy_set_header Remote-Email \$email;

error_page 401 =302 https://${AUTHELIA_SUBDOMAIN}.${BASE_DOMAIN}/?rd=\$target_url;
EOF

    print_success "Nginx snippets created"
}

# Create Authelia nginx config
create_authelia_nginx_config() {
    print_info "Creating Authelia nginx configuration..."
    
    cat > "/etc/nginx/sites-available/aegis-authelia" << EOF
# Authelia Authentication Portal
# Generated by Aegis nginx-setup.sh

server {
    listen 80;
    server_name ${AUTHELIA_SUBDOMAIN}.${BASE_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:9091;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Uri \$request_uri;
        proxy_set_header X-Forwarded-Ssl on;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }
}
EOF

    # Enable the config
    ln -sf /etc/nginx/sites-available/aegis-authelia /etc/nginx/sites-enabled/aegis-authelia
    
    print_success "Authelia nginx config created"
}

# Start Authelia container
start_authelia_container() {
    print_info "Starting Authelia container..."
    
    # Stop existing container if running
    docker stop authelia 2>/dev/null || true
    docker rm authelia 2>/dev/null || true
    
    # Create Docker Compose file for Authelia
    cat > /opt/authelia/docker-compose.yml << EOF
version: '3.8'

services:
  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    restart: unless-stopped
    volumes:
      - ./config:/config:ro
      - ./data:/data
    ports:
      - "9091:9091"
    environment:
      - TZ=UTC
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9091/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
EOF

    # Start with Docker Compose
    cd /opt/authelia
    
    if command -v docker-compose &> /dev/null; then
        docker-compose up -d
    else
        docker compose up -d
    fi
    
    # Wait for Authelia to start
    print_info "Waiting for Authelia to start..."
    sleep 5
    
    # Check if running
    if docker ps | grep -q authelia; then
        print_success "Authelia container started successfully"
    else
        print_error "Authelia container failed to start. Check logs: docker logs authelia"
    fi
    
    cd - > /dev/null
}

# Generate Authelia-protected nginx config
generate_authelia_service_config() {
    local SERVICE_NAME=$1
    local SUBDOMAIN=$2
    local PORT=$3
    local WEBSOCKET=$4
    
    SERVER_NAME="${SUBDOMAIN}.${BASE_DOMAIN}"
    
    # WebSocket support
    WS_BLOCK=""
    if [ "$WEBSOCKET" = true ]; then
        WS_BLOCK="
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";"
    fi
    
    cat > "/etc/nginx/sites-available/${SERVICE_NAME}" << EOF
# Nginx reverse proxy configuration for ${SERVICE_NAME}
# Protected by Authelia SSO
# Generated by Aegis All-in-One nginx-setup.sh

server {
    listen 80;
    server_name ${SERVER_NAME};

    # Authelia authentication endpoint
    location /authelia {
        include /etc/nginx/snippets/authelia-location.conf;
    }

    location / {
        # Authelia protection
        include /etc/nginx/snippets/authelia-authrequest.conf;
        
        proxy_pass http://127.0.0.1:${PORT}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        ${WS_BLOCK}
    }
}
EOF
    
    print_success "Created Authelia-protected config for ${SERVICE_NAME} -> ${SERVER_NAME}"
}

# Generate bypass (public) nginx config
generate_bypass_service_config() {
    local SERVICE_NAME=$1
    local SUBDOMAIN=$2
    local PORT=$3
    local WEBSOCKET=$4
    
    SERVER_NAME="${SUBDOMAIN}.${BASE_DOMAIN}"
    
    # WebSocket support
    WS_BLOCK=""
    if [ "$WEBSOCKET" = true ]; then
        WS_BLOCK="
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";"
    fi
    
    cat > "/etc/nginx/sites-available/${SERVICE_NAME}" << EOF
# Nginx reverse proxy configuration for ${SERVICE_NAME}
# Public access (no authentication required)
# Generated by Aegis All-in-One nginx-setup.sh

server {
    listen 80;
    server_name ${SERVER_NAME};

    location / {
        proxy_pass http://127.0.0.1:${PORT}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        ${WS_BLOCK}
    }
}
EOF
    
    print_success "Created public config for ${SERVICE_NAME} -> ${SERVER_NAME}"
}

# Detect installed web server
detect_webserver() {
    print_info "Checking for existing web servers..."
    
    NGINX_INSTALLED=false
    APACHE_INSTALLED=false
    
    if command -v nginx &> /dev/null; then
        NGINX_INSTALLED=true
        print_success "Nginx is installed"
    fi
    
    if command -v apache2 &> /dev/null || command -v httpd &> /dev/null; then
        APACHE_INSTALLED=true
        print_warning "Apache is installed"
    fi
    
    if [ "$APACHE_INSTALLED" = true ] && [ "$NGINX_INSTALLED" = false ]; then
        print_warning "Apache is installed but Nginx is not."
        print_warning "This script is designed for Nginx. Apache may conflict on port 80/443."
        read -p "Would you like to stop Apache and install Nginx? (y/n): " STOP_APACHE
        if [ "$STOP_APACHE" = "y" ] || [ "$STOP_APACHE" = "Y" ]; then
            print_info "Stopping Apache..."
            systemctl stop apache2 2>/dev/null || systemctl stop httpd 2>/dev/null || true
            systemctl disable apache2 2>/dev/null || systemctl disable httpd 2>/dev/null || true
            install_nginx
        else
            print_error "Cannot proceed with Apache running. Please configure manually or stop Apache."
            exit 1
        fi
    elif [ "$NGINX_INSTALLED" = false ]; then
        read -p "Nginx is not installed. Would you like to install it now? (y/n): " INSTALL_NGINX
        if [ "$INSTALL_NGINX" = "y" ] || [ "$INSTALL_NGINX" = "Y" ]; then
            install_nginx
        else
            print_error "Nginx is required for this script. Exiting."
            exit 1
        fi
    fi
}

# Install Nginx
install_nginx() {
    print_info "Installing Nginx..."
    
    # Detect package manager
    if command -v apt-get &> /dev/null; then
        apt-get update -y
        apt-get install -y nginx
    elif command -v yum &> /dev/null; then
        yum install -y epel-release
        yum install -y nginx
    elif command -v dnf &> /dev/null; then
        dnf install -y nginx
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm nginx
    else
        print_error "Could not detect package manager. Please install Nginx manually."
        exit 1
    fi
    
    # Start and enable nginx
    systemctl start nginx
    systemctl enable nginx
    
    print_success "Nginx installed and started successfully"
}

# Get user configuration
get_user_config() {
    echo ""
    print_info "=== Configuration Setup ==="
    echo ""
    
    # Get base domain
    read -p "Enter your base domain (e.g., example.com): " BASE_DOMAIN
    if [ -z "$BASE_DOMAIN" ]; then
        print_error "Domain cannot be empty"
        exit 1
    fi
    
    # Ask about subdomain structure
    echo ""
    print_info "How would you like to configure your services?"
    echo "1) Subdomains (e.g., map.example.com, admin.example.com)"
    echo "2) Subdirectories (e.g., example.com/map, example.com/admin)"
    read -p "Choose option (1 or 2) [default: 1]: " STRUCTURE_CHOICE
    STRUCTURE_CHOICE=${STRUCTURE_CHOICE:-1}
    
    if [ "$STRUCTURE_CHOICE" = "1" ]; then
        USE_SUBDOMAINS=true
        echo ""
        print_info "Configure subdomain names for each service (press Enter for defaults):"
        
        read -p "ReactMap subdomain [map]: " SUBDOMAIN_REACTMAP
        SUBDOMAIN_REACTMAP=${SUBDOMAIN_REACTMAP:-map}
        
        read -p "Dragonite Admin subdomain [admin]: " SUBDOMAIN_ADMIN
        SUBDOMAIN_ADMIN=${SUBDOMAIN_ADMIN:-admin}
        
        read -p "Rotom subdomain [rotom]: " SUBDOMAIN_ROTOM
        SUBDOMAIN_ROTOM=${SUBDOMAIN_ROTOM:-rotom}
        
        read -p "Koji subdomain [koji]: " SUBDOMAIN_KOJI
        SUBDOMAIN_KOJI=${SUBDOMAIN_KOJI:-koji}
        
        read -p "phpMyAdmin subdomain [pma]: " SUBDOMAIN_PMA
        SUBDOMAIN_PMA=${SUBDOMAIN_PMA:-pma}
        
        read -p "Grafana subdomain [grafana]: " SUBDOMAIN_GRAFANA
        SUBDOMAIN_GRAFANA=${SUBDOMAIN_GRAFANA:-grafana}
        
        read -p "Poracle subdomain [poracle]: " SUBDOMAIN_PORACLE
        SUBDOMAIN_PORACLE=${SUBDOMAIN_PORACLE:-poracle}
    else
        USE_SUBDOMAINS=false
    fi
    
    # Ask about basic auth
    echo ""
    read -p "Would you like to enable basic authentication for sensitive services? (y/n) [y]: " ENABLE_AUTH
    ENABLE_AUTH=${ENABLE_AUTH:-y}
    
    if [ "$ENABLE_AUTH" = "y" ] || [ "$ENABLE_AUTH" = "Y" ]; then
        SETUP_AUTH=true
        read -p "Enter username for basic auth [admin]: " AUTH_USER
        AUTH_USER=${AUTH_USER:-admin}
        read -s -p "Enter password for basic auth: " AUTH_PASS
        echo ""
        if [ -z "$AUTH_PASS" ]; then
            AUTH_PASS=$(openssl rand -base64 12)
            print_warning "Generated random password: $AUTH_PASS"
        fi
    else
        SETUP_AUTH=false
    fi
}

# Setup basic authentication
setup_basic_auth() {
    if [ "$SETUP_AUTH" = true ]; then
        print_info "Setting up basic authentication..."
        
        # Install apache2-utils for htpasswd if not present
        if ! command -v htpasswd &> /dev/null; then
            if command -v apt-get &> /dev/null; then
                apt-get install -y apache2-utils
            elif command -v yum &> /dev/null; then
                yum install -y httpd-tools
            elif command -v dnf &> /dev/null; then
                dnf install -y httpd-tools
            fi
        fi
        
        # Create htpasswd file
        htpasswd -cb /etc/nginx/.htpasswd "$AUTH_USER" "$AUTH_PASS"
        chmod 644 /etc/nginx/.htpasswd
        
        print_success "Basic auth configured for user: $AUTH_USER"
    fi
}

# Generate nginx config for a service
generate_service_config() {
    local SERVICE_NAME=$1
    local SUBDOMAIN=$2
    local PORT=$3
    local REQUIRE_AUTH=$4
    local WEBSOCKET=$5
    
    if [ "$USE_SUBDOMAINS" = true ]; then
        SERVER_NAME="${SUBDOMAIN}.${BASE_DOMAIN}"
        LOCATION="/"
    else
        SERVER_NAME="${BASE_DOMAIN}"
        LOCATION="/${SUBDOMAIN}/"
    fi
    
    # Auth block
    AUTH_BLOCK=""
    if [ "$SETUP_AUTH" = true ] && [ "$REQUIRE_AUTH" = true ]; then
        AUTH_BLOCK="
        auth_basic \"Restricted Access\";
        auth_basic_user_file /etc/nginx/.htpasswd;"
    fi
    
    # WebSocket support
    WS_BLOCK=""
    if [ "$WEBSOCKET" = true ]; then
        WS_BLOCK="
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";"
    fi
    
    # Generate config
    cat > "/etc/nginx/sites-available/${SERVICE_NAME}" << EOF
# Nginx reverse proxy configuration for ${SERVICE_NAME}
# Generated by Aegis All-in-One nginx-setup.sh

server {
    listen 80;
    server_name ${SERVER_NAME};

    location ${LOCATION} {
        proxy_pass http://127.0.0.1:${PORT}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        ${AUTH_BLOCK}
        ${WS_BLOCK}
    }
}
EOF
    
    print_success "Created config for ${SERVICE_NAME} -> ${SERVER_NAME}"
}

# Create all nginx configurations
create_nginx_configs() {
    print_info "Creating Nginx configurations..."
    
    # Ensure directories exist
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    
    # Check if nginx.conf includes sites-enabled
    if ! grep -q "sites-enabled" /etc/nginx/nginx.conf; then
        print_warning "Adding sites-enabled include to nginx.conf..."
        # Add include directive before the last closing brace
        sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
    fi
    
    # Remove default site if exists
    rm -f /etc/nginx/sites-enabled/default
    
    # Generate configs based on whether Authelia is enabled
    if [ "$AUTHELIA_ENABLED" = true ]; then
        print_info "Using Authelia for authentication..."
        
        # Public services (bypass Authelia)
        generate_bypass_service_config "aegis-reactmap" "$SUBDOMAIN_REACTMAP" "6001" true
        generate_bypass_service_config "aegis-grafana" "$SUBDOMAIN_GRAFANA" "6006" true
        generate_bypass_service_config "aegis-poracle" "$SUBDOMAIN_PORACLE" "6007" true
        
        # Protected services (require Authelia)
        generate_authelia_service_config "aegis-admin" "$SUBDOMAIN_ADMIN" "6002" true
        generate_authelia_service_config "aegis-rotom" "$SUBDOMAIN_ROTOM" "6003" true
        generate_authelia_service_config "aegis-koji" "$SUBDOMAIN_KOJI" "6004" true
        generate_authelia_service_config "aegis-pma" "$SUBDOMAIN_PMA" "6005" false
    else
        # Use basic auth or no auth
        # Service: ReactMap (port 6001) - public facing, no auth needed typically
        generate_service_config "aegis-reactmap" "$SUBDOMAIN_REACTMAP" "6001" false true
        
        # Service: Dragonite Admin (port 6002) - requires auth
        generate_service_config "aegis-admin" "$SUBDOMAIN_ADMIN" "6002" true true
        
        # Service: Rotom (port 6003) - requires auth
        generate_service_config "aegis-rotom" "$SUBDOMAIN_ROTOM" "6003" true true
        
        # Service: Koji (port 6004) - requires auth
        generate_service_config "aegis-koji" "$SUBDOMAIN_KOJI" "6004" true true
        
        # Service: phpMyAdmin (port 6005) - requires auth
        generate_service_config "aegis-pma" "$SUBDOMAIN_PMA" "6005" true false
        
        # Service: Grafana (port 6006) - has its own auth
        generate_service_config "aegis-grafana" "$SUBDOMAIN_GRAFANA" "6006" false true
        
        # Service: Poracle (port 6007) - webhook receiver
        generate_service_config "aegis-poracle" "$SUBDOMAIN_PORACLE" "6007" false true
    fi
    
    print_success "All Nginx configurations created"
}

# Create symlinks
create_symlinks() {
    print_info "Creating symlinks in sites-enabled..."
    
    for config in /etc/nginx/sites-available/aegis-*; do
        if [ -f "$config" ]; then
            config_name=$(basename "$config")
            ln -sf "$config" "/etc/nginx/sites-enabled/${config_name}"
            print_success "Enabled: ${config_name}"
        fi
    done
}

# Test and reload nginx
test_and_reload_nginx() {
    print_info "Testing Nginx configuration..."
    
    if nginx -t; then
        print_success "Nginx configuration is valid"
        print_info "Reloading Nginx..."
        systemctl reload nginx
        print_success "Nginx reloaded successfully"
    else
        print_error "Nginx configuration test failed. Please check the configs."
        exit 1
    fi
}

# Setup SSL with Certbot
setup_ssl() {
    echo ""
    read -p "Would you like to setup SSL certificates using Let's Encrypt (Certbot)? (y/n) [y]: " SETUP_SSL
    SETUP_SSL=${SETUP_SSL:-y}
    
    if [ "$SETUP_SSL" != "y" ] && [ "$SETUP_SSL" != "Y" ]; then
        print_warning "Skipping SSL setup. Your services will be available over HTTP only."
        return
    fi
    
    print_info "Setting up SSL with Certbot..."
    
    # Install certbot if not present
    if ! command -v certbot &> /dev/null; then
        print_info "Installing Certbot..."
        
        if command -v apt-get &> /dev/null; then
            apt-get update -y
            apt-get install -y certbot python3-certbot-nginx
        elif command -v yum &> /dev/null; then
            yum install -y certbot python3-certbot-nginx
        elif command -v dnf &> /dev/null; then
            dnf install -y certbot python3-certbot-nginx
        elif command -v pacman &> /dev/null; then
            pacman -Sy --noconfirm certbot certbot-nginx
        else
            print_error "Could not install certbot. Please install manually."
            return
        fi
        
        print_success "Certbot installed"
    fi
    
    # Get email for Let's Encrypt
    read -p "Enter your email address for Let's Encrypt notifications: " LE_EMAIL
    if [ -z "$LE_EMAIL" ]; then
        print_error "Email is required for Let's Encrypt"
        return
    fi
    
    # Build domain list
    DOMAIN_LIST=""
    if [ "$USE_SUBDOMAINS" = true ]; then
        DOMAIN_LIST="-d ${SUBDOMAIN_REACTMAP}.${BASE_DOMAIN}"
        DOMAIN_LIST="$DOMAIN_LIST -d ${SUBDOMAIN_ADMIN}.${BASE_DOMAIN}"
        DOMAIN_LIST="$DOMAIN_LIST -d ${SUBDOMAIN_ROTOM}.${BASE_DOMAIN}"
        DOMAIN_LIST="$DOMAIN_LIST -d ${SUBDOMAIN_KOJI}.${BASE_DOMAIN}"
        DOMAIN_LIST="$DOMAIN_LIST -d ${SUBDOMAIN_PMA}.${BASE_DOMAIN}"
        DOMAIN_LIST="$DOMAIN_LIST -d ${SUBDOMAIN_GRAFANA}.${BASE_DOMAIN}"
        DOMAIN_LIST="$DOMAIN_LIST -d ${SUBDOMAIN_PORACLE}.${BASE_DOMAIN}"
        # Add Authelia domain if enabled
        if [ "$AUTHELIA_ENABLED" = true ]; then
            DOMAIN_LIST="$DOMAIN_LIST -d ${AUTHELIA_SUBDOMAIN}.${BASE_DOMAIN}"
        fi
    else
        DOMAIN_LIST="-d ${BASE_DOMAIN}"
    fi
    
    echo ""
    print_info "The following domains will be configured for SSL:"
    if [ "$USE_SUBDOMAINS" = true ]; then
        echo "  - ${SUBDOMAIN_REACTMAP}.${BASE_DOMAIN}"
        echo "  - ${SUBDOMAIN_ADMIN}.${BASE_DOMAIN}"
        echo "  - ${SUBDOMAIN_ROTOM}.${BASE_DOMAIN}"
        echo "  - ${SUBDOMAIN_KOJI}.${BASE_DOMAIN}"
        echo "  - ${SUBDOMAIN_PMA}.${BASE_DOMAIN}"
        echo "  - ${SUBDOMAIN_GRAFANA}.${BASE_DOMAIN}"
        echo "  - ${SUBDOMAIN_PORACLE}.${BASE_DOMAIN}"
        if [ "$AUTHELIA_ENABLED" = true ]; then
            echo "  - ${AUTHELIA_SUBDOMAIN}.${BASE_DOMAIN} (Authelia SSO)"
        fi
    else
        echo "  - ${BASE_DOMAIN}"
    fi
    echo ""
    
    print_warning "Make sure all domains are pointing to this server's IP address!"
    read -p "Continue with SSL setup? (y/n) [y]: " CONFIRM_SSL
    CONFIRM_SSL=${CONFIRM_SSL:-y}
    
    if [ "$CONFIRM_SSL" = "y" ] || [ "$CONFIRM_SSL" = "Y" ]; then
        print_info "Running Certbot..."
        
        # Run certbot
        certbot --nginx --non-interactive --agree-tos --email "$LE_EMAIL" $DOMAIN_LIST --redirect
        
        if [ $? -eq 0 ]; then
            print_success "SSL certificates installed successfully!"
            print_success "Auto-renewal is enabled via systemd timer or cron"
        else
            print_error "Certbot encountered an error. Please check the output above."
            print_info "You can try running certbot manually: certbot --nginx"
        fi
    else
        print_warning "SSL setup cancelled"
    fi
}

# Setup Rotom device port (7070)
setup_rotom_device_port() {
    echo ""
    print_info "Rotom requires port 7070 for device connections."
    read -p "Would you like to configure nginx stream proxy for Rotom devices on port 7070? (y/n) [n]: " SETUP_ROTOM_STREAM
    SETUP_ROTOM_STREAM=${SETUP_ROTOM_STREAM:-n}
    
    if [ "$SETUP_ROTOM_STREAM" = "y" ] || [ "$SETUP_ROTOM_STREAM" = "Y" ]; then
        print_info "Setting up stream proxy for Rotom device connections..."
        
        # Check if stream module is available
        if ! nginx -V 2>&1 | grep -q "with-stream"; then
            print_warning "Nginx stream module may not be available. Skipping stream config."
            print_info "Devices should connect directly to port 7070 on this server."
            return
        fi
        
        # Create stream config
        mkdir -p /etc/nginx/stream.d
        
        cat > "/etc/nginx/stream.d/rotom-devices.conf" << EOF
# Stream proxy for Rotom device connections
# This allows devices to connect via nginx on port 7070

upstream rotom_devices {
    server 127.0.0.1:7070;
}

server {
    listen 7070;
    proxy_pass rotom_devices;
    proxy_connect_timeout 60s;
    proxy_timeout 300s;
}
EOF
        
        # Add stream include to nginx.conf if not present
        if ! grep -q "stream.d" /etc/nginx/nginx.conf; then
            echo "" >> /etc/nginx/nginx.conf
            echo "stream {" >> /etc/nginx/nginx.conf
            echo "    include /etc/nginx/stream.d/*.conf;" >> /etc/nginx/nginx.conf
            echo "}" >> /etc/nginx/nginx.conf
        fi
        
        print_success "Stream proxy configured for Rotom devices on port 7070"
    else
        print_info "Skipping stream proxy setup. Devices will connect directly to port 7070."
    fi
}

# Print summary
print_summary() {
    echo ""
    echo "=============================================="
    print_success "Nginx Reverse Proxy Setup Complete!"
    echo "=============================================="
    echo ""
    print_info "Your services are now available at:"
    echo ""
    
    if [ "$USE_SUBDOMAINS" = true ]; then
        PROTO="http"
        if [ "$SETUP_SSL" = "y" ] || [ "$SETUP_SSL" = "Y" ]; then
            PROTO="https"
        fi
        echo "  ReactMap:        ${PROTO}://${SUBDOMAIN_REACTMAP}.${BASE_DOMAIN}"
        echo "  Dragonite Admin: ${PROTO}://${SUBDOMAIN_ADMIN}.${BASE_DOMAIN}"
        echo "  Rotom:           ${PROTO}://${SUBDOMAIN_ROTOM}.${BASE_DOMAIN}"
        echo "  Koji:            ${PROTO}://${SUBDOMAIN_KOJI}.${BASE_DOMAIN}"
        echo "  phpMyAdmin:      ${PROTO}://${SUBDOMAIN_PMA}.${BASE_DOMAIN}"
        echo "  Grafana:         ${PROTO}://${SUBDOMAIN_GRAFANA}.${BASE_DOMAIN}"
        echo "  Poracle:         ${PROTO}://${SUBDOMAIN_PORACLE}.${BASE_DOMAIN}"
    else
        echo "  ReactMap:        http://${BASE_DOMAIN}/map/"
        echo "  Dragonite Admin: http://${BASE_DOMAIN}/admin/"
        echo "  Rotom:           http://${BASE_DOMAIN}/rotom/"
        echo "  Koji:            http://${BASE_DOMAIN}/koji/"
        echo "  phpMyAdmin:      http://${BASE_DOMAIN}/pma/"
        echo "  Grafana:         http://${BASE_DOMAIN}/grafana/"
        echo "  Poracle:         http://${BASE_DOMAIN}/poracle/"
    fi
    
    echo ""
    if [ "$AUTHELIA_ENABLED" = true ]; then
        print_info "Authelia SSO Portal:"
        echo "  URL:      ${PROTO}://${AUTHELIA_SUBDOMAIN}.${BASE_DOMAIN}"
        echo "  Username: $AUTHELIA_USER"
        echo "  Password: $AUTHELIA_PASSWORD"
        echo "  Email:    $AUTHELIA_EMAIL"
        echo ""
        print_info "Authelia Protected Services (require 2FA):"
        echo "  - Dragonite Admin: ${PROTO}://${SUBDOMAIN_ADMIN}.${BASE_DOMAIN}"
        echo "  - Rotom:           ${PROTO}://${SUBDOMAIN_ROTOM}.${BASE_DOMAIN}"
        echo "  - Koji:            ${PROTO}://${SUBDOMAIN_KOJI}.${BASE_DOMAIN}"
        echo "  - phpMyAdmin:      ${PROTO}://${SUBDOMAIN_PMA}.${BASE_DOMAIN}"
        echo ""
        print_info "2FA Setup:"
        echo "  1. Login to ${PROTO}://${AUTHELIA_SUBDOMAIN}.${BASE_DOMAIN}"
        echo "  2. Click 'Register device' to setup TOTP"
        echo "  3. Scan QR code with authenticator app"
        echo "  4. Enter code to verify"
        echo ""
        print_info "Authelia Commands:"
        echo "  View logs:    docker logs -f authelia"
        echo "  Restart:      docker restart authelia"
        echo "  Config:       /opt/authelia/config/"
        echo ""
    elif [ "$SETUP_AUTH" = true ]; then
        print_info "Basic Auth Credentials (for protected services):"
        echo "  Username: $AUTH_USER"
        echo "  Password: $AUTH_PASS"
        echo ""
    fi
    
    print_info "Rotom Device Connection:"
    echo "  Devices should connect to: your-server-ip:7070"
    echo ""
    
    print_info "Configuration files location:"
    echo "  /etc/nginx/sites-available/aegis-*"
    echo "  /etc/nginx/sites-enabled/aegis-*"
    echo ""
    
    print_info "Useful commands:"
    echo "  Test config:  sudo nginx -t"
    echo "  Reload:       sudo systemctl reload nginx"
    echo "  Status:       sudo systemctl status nginx"
    echo "  Logs:         sudo tail -f /var/log/nginx/error.log"
    echo ""
    
    if [ "$SETUP_SSL" = "y" ] || [ "$SETUP_SSL" = "Y" ]; then
        print_info "SSL Certificate Renewal:"
        echo "  Test renewal: sudo certbot renew --dry-run"
        echo "  Certificates auto-renew via systemd timer"
        echo ""
    fi
    
    if [ "$FAIL2BAN_INSTALLED" = true ]; then
        print_info "Fail2Ban Protection:"
        echo "  Status:       sudo fail2ban-client status"
        echo "  Check jail:   sudo fail2ban-client status nginx-http-auth"
        echo "  Unban IP:     sudo fail2ban-client set <jail> unbanip <IP>"
        echo "  Banned IPs:   sudo fail2ban-client status <jail>"
        echo ""
        echo "  Active jails: sshd, nginx-http-auth, nginx-forbidden,"
        echo "                nginx-badbots, nginx-botsearch, nginx-limit-req,"
        echo "                recidive (repeat offender protection)"
        echo ""
        echo "  Ban settings: ${BAN_TIME}s ban, ${MAX_RETRY} attempts in ${FIND_TIME}s"
        echo ""
    fi
    
    print_warning "SECURITY REMINDER:"
    echo "  - Change default passwords for Grafana (admin/admin)"
    echo "  - Keep your basic auth password secure"
    echo "  - Consider using a firewall (ufw) to restrict access"
    echo "  - Only expose necessary ports to the internet"
    if [ "$FAIL2BAN_INSTALLED" = true ]; then
        echo "  - Monitor Fail2Ban logs: /var/log/fail2ban.log"
    fi
    echo ""
}

# Main execution
main() {
    clear
    echo "=============================================="
    echo "  Aegis All-in-One Nginx Reverse Proxy Setup"
    echo "  By The Pokemod Group"
    echo "  https://pokemod.dev/"
    echo "=============================================="
    echo ""
    
    check_root
    detect_webserver
    get_user_config
    setup_authelia
    if [ "$AUTHELIA_ENABLED" != true ]; then
        setup_basic_auth
    fi
    create_nginx_configs
    create_symlinks
    test_and_reload_nginx
    setup_rotom_device_port
    test_and_reload_nginx
    setup_ssl
    setup_fail2ban
    print_summary
}

# Run main function
main

