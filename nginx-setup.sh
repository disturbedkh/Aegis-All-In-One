#!/bin/bash

# Aegis All-in-One Nginx Reverse Proxy Setup Script
# This script sets up nginx reverse proxies for all Aegis services with optional SSL

set -e

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
    
    # Generate configs for each service
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
    if [ "$SETUP_AUTH" = true ]; then
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
    
    print_warning "SECURITY REMINDER:"
    echo "  - Change default passwords for Grafana (admin/admin)"
    echo "  - Keep your basic auth password secure"
    echo "  - Consider using a firewall (ufw) to restrict access"
    echo "  - Only expose necessary ports to the internet"
    echo ""
}

# Main execution
main() {
    clear
    echo "=============================================="
    echo "  Aegis All-in-One Nginx Reverse Proxy Setup"
    echo "=============================================="
    echo ""
    
    check_root
    detect_webserver
    get_user_config
    setup_basic_auth
    create_nginx_configs
    create_symlinks
    test_and_reload_nginx
    setup_rotom_device_port
    test_and_reload_nginx
    setup_ssl
    print_summary
}

# Run main function
main

