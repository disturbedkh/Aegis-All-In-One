#!/bin/bash

# Aegis All-in-One Nginx Security & Management Script
# =============================================================================
# This script provides:
#   - SETUP MODE: Full nginx reverse proxy setup with SSL, Fail2Ban, UFW
#   - MAINTENANCE MODE: Status dashboard, service management, configuration
# =============================================================================
# Includes Fail2Ban configuration for brute-force and bot protection
# Includes optional Authelia setup for SSO and 2FA authentication

# NOTE: We intentionally do NOT use 'set -e' because we need to handle nginx test
# failures gracefully and continue to SSL setup even if there are warnings

# Global variables
AUTHELIA_ENABLED=false
AUTHELIA_SUBDOMAIN="auth"
SCRIPT_MODE=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m' # No Color

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
        chown "$REAL_USER:$REAL_GROUP" docker-compose.yaml *.sh *.yaml *.yml *.md 2>/dev/null || true
    fi
}
trap cleanup_on_exit EXIT

# Print colored messages
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Helper function for press enter
press_enter() {
    echo ""
    read -p "  Press Enter to continue..."
}

# Draw box functions for nice UI
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
    local text="$1"
    printf "${CYAN}║${NC} %-74s ${CYAN}║${NC}\n" "$text"
}

# =============================================================================
# MAINTENANCE MODE - STATUS DASHBOARD
# =============================================================================

# Get service status with color
get_service_status() {
    local service=$1
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "${GREEN}● Running${NC}"
    elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
        echo -e "${YELLOW}○ Stopped${NC}"
    else
        echo -e "${DIM}○ Not Installed${NC}"
    fi
}

# Get simple status (for logic)
get_service_status_simple() {
    local service=$1
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "running"
    elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
        echo "stopped"
    elif command -v "$service" &>/dev/null || [ -f "/etc/init.d/$service" ]; then
        echo "stopped"
    else
        echo "not_installed"
    fi
}

# Count nginx sites
count_nginx_sites() {
    local enabled=0
    local available=0
    
    if [ -d "/etc/nginx/sites-enabled" ]; then
        enabled=$(ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | wc -l)
    fi
    if [ -d "/etc/nginx/sites-available" ]; then
        available=$(ls -1 /etc/nginx/sites-available/ 2>/dev/null | wc -l)
    fi
    
    echo "$enabled/$available"
}

# Get SSL certificate info
get_ssl_status() {
    if command -v certbot &>/dev/null; then
        local cert_count=$(certbot certificates 2>/dev/null | grep -c "Certificate Name:" || echo "0")
        if [ "$cert_count" -gt 0 ]; then
            echo -e "${GREEN}$cert_count certificate(s)${NC}"
        else
            echo -e "${YELLOW}No certificates${NC}"
        fi
    else
        echo -e "${DIM}Certbot not installed${NC}"
    fi
}

# Get fail2ban jail count
get_fail2ban_status() {
    if command -v fail2ban-client &>/dev/null; then
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            local jail_count=$(fail2ban-client status 2>/dev/null | grep "Number of jail:" | awk '{print $NF}')
            local banned=$(fail2ban-client status 2>/dev/null | grep -A100 "Jail list:" | tail -n+2 | while read jail; do
                fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned:" | awk '{print $NF}'
            done | paste -sd+ | bc 2>/dev/null || echo "0")
            echo -e "${GREEN}$jail_count jails, ${banned:-0} banned${NC}"
        else
            echo -e "${YELLOW}Stopped${NC}"
        fi
    else
        echo -e "${DIM}Not installed${NC}"
    fi
}

# Get UFW status
get_ufw_status() {
    if command -v ufw &>/dev/null; then
        local status=$(ufw status 2>/dev/null | head -1)
        if echo "$status" | grep -q "active"; then
            local rule_count=$(ufw status numbered 2>/dev/null | grep -c "^\[" || echo "0")
            echo -e "${GREEN}Active ($rule_count rules)${NC}"
        else
            echo -e "${YELLOW}Inactive${NC}"
        fi
    else
        echo -e "${DIM}Not installed${NC}"
    fi
}

# Show maintenance status dashboard
show_status_dashboard() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              NGINX SECURITY & MANAGEMENT - STATUS DASHBOARD"
    draw_box_bottom
    echo ""
    
    # Service Status Section
    echo -e "${WHITE}${BOLD}Service Status${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
    
    local nginx_status=$(get_service_status "nginx")
    local fail2ban_status=$(get_service_status "fail2ban")
    local certbot_timer=$(systemctl is-active --quiet "certbot.timer" 2>/dev/null && echo -e "${GREEN}● Active${NC}" || echo -e "${DIM}○ Inactive${NC}")
    
    printf "  %-20s %s\n" "Nginx:" "$nginx_status"
    printf "  %-20s %s\n" "Fail2Ban:" "$fail2ban_status"
    printf "  %-20s %s\n" "Certbot Timer:" "$certbot_timer"
    printf "  %-20s %s\n" "UFW Firewall:" "$(get_ufw_status)"
    echo ""
    
    # Configuration Section
    echo -e "${WHITE}${BOLD}Configuration${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
    
    local sites_count=$(count_nginx_sites)
    local ssl_status=$(get_ssl_status)
    local f2b_status=$(get_fail2ban_status)
    
    printf "  %-20s %s\n" "Nginx Sites:" "$sites_count (enabled/available)"
    printf "  %-20s %s\n" "SSL Certificates:" "$ssl_status"
    printf "  %-20s %s\n" "Fail2Ban:" "$f2b_status"
    echo ""
    
    # Quick Health Check
    echo -e "${WHITE}${BOLD}Quick Health Check${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
    
    # Test nginx config
    if command -v nginx &>/dev/null; then
        if nginx -t 2>&1 | grep -q "test is successful"; then
            echo -e "  Nginx Config:      ${GREEN}✓ Valid${NC}"
        else
            echo -e "  Nginx Config:      ${RED}✗ Errors detected${NC}"
        fi
    else
        echo -e "  Nginx Config:      ${DIM}N/A${NC}"
    fi
    
    # Check if ports are listening
    if command -v ss &>/dev/null; then
        local http_listening=$(ss -tlnp 2>/dev/null | grep -q ":80 " && echo "yes" || echo "no")
        local https_listening=$(ss -tlnp 2>/dev/null | grep -q ":443 " && echo "yes" || echo "no")
        
        if [ "$http_listening" = "yes" ]; then
            echo -e "  Port 80 (HTTP):    ${GREEN}✓ Listening${NC}"
        else
            echo -e "  Port 80 (HTTP):    ${YELLOW}○ Not listening${NC}"
        fi
        
        if [ "$https_listening" = "yes" ]; then
            echo -e "  Port 443 (HTTPS):  ${GREEN}✓ Listening${NC}"
        else
            echo -e "  Port 443 (HTTPS):  ${YELLOW}○ Not listening${NC}"
        fi
    fi
    echo ""
}

# =============================================================================
# MAINTENANCE MODE - SERVICE MANAGEMENT
# =============================================================================

service_management_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "                    SERVICE MANAGEMENT"
        draw_box_bottom
        echo ""
        
        echo -e "${WHITE}${BOLD}Current Service Status${NC}"
        echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
        printf "  %-20s %s\n" "Nginx:" "$(get_service_status nginx)"
        printf "  %-20s %s\n" "Fail2Ban:" "$(get_service_status fail2ban)"
        echo ""
        
        echo -e "${WHITE}${BOLD}Actions${NC}"
        echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo "  ${WHITE}Nginx${NC}"
        echo "    1) Start Nginx"
        echo "    2) Stop Nginx"
        echo "    3) Restart Nginx"
        echo "    4) Reload Nginx (graceful)"
        echo "    5) Test Nginx Configuration"
        echo ""
        echo "  ${WHITE}Fail2Ban${NC}"
        echo "    6) Start Fail2Ban"
        echo "    7) Stop Fail2Ban"
        echo "    8) Restart Fail2Ban"
        echo "    9) Reload Fail2Ban"
        echo ""
        echo "  ${WHITE}All Services${NC}"
        echo "    a) Start All"
        echo "    x) Stop All"
        echo "    r) Restart All"
        echo ""
        echo "    0) Back to maintenance menu"
        echo ""
        read -p "  Select option: " choice
        
        case $choice in
            1) systemctl start nginx && print_success "Nginx started" || print_error "Failed to start Nginx"; press_enter ;;
            2) systemctl stop nginx && print_success "Nginx stopped" || print_error "Failed to stop Nginx"; press_enter ;;
            3) systemctl restart nginx && print_success "Nginx restarted" || print_error "Failed to restart Nginx"; press_enter ;;
            4) systemctl reload nginx && print_success "Nginx reloaded" || print_error "Failed to reload Nginx"; press_enter ;;
            5)
                echo ""
                echo -e "${CYAN}Testing Nginx configuration...${NC}"
                nginx -t
                press_enter
                ;;
            6) systemctl start fail2ban && print_success "Fail2Ban started" || print_error "Failed to start Fail2Ban"; press_enter ;;
            7) systemctl stop fail2ban && print_success "Fail2Ban stopped" || print_error "Failed to stop Fail2Ban"; press_enter ;;
            8) systemctl restart fail2ban && print_success "Fail2Ban restarted" || print_error "Failed to restart Fail2Ban"; press_enter ;;
            9) systemctl reload fail2ban && print_success "Fail2Ban reloaded" || print_error "Failed to reload Fail2Ban"; press_enter ;;
            a|A)
                echo ""
                echo -e "${CYAN}Starting all services...${NC}"
                systemctl start nginx 2>/dev/null && echo -e "  ${GREEN}✓${NC} Nginx started" || echo -e "  ${RED}✗${NC} Nginx failed"
                systemctl start fail2ban 2>/dev/null && echo -e "  ${GREEN}✓${NC} Fail2Ban started" || echo -e "  ${RED}✗${NC} Fail2Ban failed"
                press_enter
                ;;
            x|X)
                echo ""
                echo -e "${CYAN}Stopping all services...${NC}"
                systemctl stop nginx 2>/dev/null && echo -e "  ${GREEN}✓${NC} Nginx stopped" || echo -e "  ${RED}✗${NC} Nginx failed"
                systemctl stop fail2ban 2>/dev/null && echo -e "  ${GREEN}✓${NC} Fail2Ban stopped" || echo -e "  ${RED}✗${NC} Fail2Ban failed"
                press_enter
                ;;
            r|R)
                echo ""
                echo -e "${CYAN}Restarting all services...${NC}"
                systemctl restart nginx 2>/dev/null && echo -e "  ${GREEN}✓${NC} Nginx restarted" || echo -e "  ${RED}✗${NC} Nginx failed"
                systemctl restart fail2ban 2>/dev/null && echo -e "  ${GREEN}✓${NC} Fail2Ban restarted" || echo -e "  ${RED}✗${NC} Fail2Ban failed"
                press_enter
                ;;
            0|"") return ;;
        esac
    done
}

# =============================================================================
# MAINTENANCE MODE - SITE MANAGEMENT
# =============================================================================

site_management_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "                    NGINX SITE MANAGEMENT"
        draw_box_bottom
        echo ""
        
        # List enabled sites
        echo -e "${WHITE}${BOLD}Enabled Sites${NC}"
        echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
        if [ -d "/etc/nginx/sites-enabled" ]; then
            local i=1
            for site in /etc/nginx/sites-enabled/*; do
                if [ -f "$site" ]; then
                    local name=$(basename "$site")
                    printf "  ${GREEN}●${NC} %d) %s\n" "$i" "$name"
                    ((i++))
                fi
            done
            [ "$i" -eq 1 ] && echo -e "  ${DIM}No sites enabled${NC}"
        else
            echo -e "  ${DIM}sites-enabled directory not found${NC}"
        fi
        echo ""
        
        # List available (disabled) sites
        echo -e "${WHITE}${BOLD}Available (Disabled) Sites${NC}"
        echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
        if [ -d "/etc/nginx/sites-available" ]; then
            local has_disabled=false
            for site in /etc/nginx/sites-available/*; do
                if [ -f "$site" ]; then
                    local name=$(basename "$site")
                    if [ ! -L "/etc/nginx/sites-enabled/$name" ]; then
                        echo -e "  ${YELLOW}○${NC} $name"
                        has_disabled=true
                    fi
                fi
            done
            [ "$has_disabled" = false ] && echo -e "  ${DIM}All sites are enabled${NC}"
        fi
        echo ""
        
        echo -e "${WHITE}${BOLD}Actions${NC}"
        echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo "    1) Enable a site"
        echo "    2) Disable a site"
        echo "    3) View site configuration"
        echo "    4) Edit site configuration"
        echo "    5) Add new Aegis site (runs setup for single site)"
        echo "    6) Delete site"
        echo ""
        echo "    t) Test configuration"
        echo "    r) Reload Nginx"
        echo ""
        echo "    0) Back to maintenance menu"
        echo ""
        read -p "  Select option: " choice
        
        case $choice in
            1) enable_site ;;
            2) disable_site ;;
            3) view_site_config ;;
            4) edit_site_config ;;
            5) add_new_site ;;
            6) delete_site ;;
            t|T)
                echo ""
                nginx -t
                press_enter
                ;;
            r|R)
                echo ""
                systemctl reload nginx && print_success "Nginx reloaded" || print_error "Reload failed"
                press_enter
                ;;
            0|"") return ;;
        esac
    done
}

enable_site() {
    echo ""
    echo -e "${WHITE}Available sites to enable:${NC}"
    
    local sites=()
    local i=1
    for site in /etc/nginx/sites-available/*; do
        if [ -f "$site" ]; then
            local name=$(basename "$site")
            if [ ! -L "/etc/nginx/sites-enabled/$name" ]; then
                printf "  %d) %s\n" "$i" "$name"
                sites+=("$name")
                ((i++))
            fi
        fi
    done
    
    if [ ${#sites[@]} -eq 0 ]; then
        echo -e "  ${DIM}No sites available to enable${NC}"
        press_enter
        return
    fi
    
    echo ""
    read -p "  Enter site number to enable (0 to cancel): " num
    
    if [ "$num" -gt 0 ] 2>/dev/null && [ "$num" -le ${#sites[@]} ] 2>/dev/null; then
        local site="${sites[$((num-1))]}"
        ln -sf "/etc/nginx/sites-available/$site" "/etc/nginx/sites-enabled/$site"
        print_success "Site '$site' enabled"
        
        echo ""
        read -p "  Test and reload Nginx? (y/n) [y]: " reload
        reload=${reload:-y}
        if [ "$reload" = "y" ] || [ "$reload" = "Y" ]; then
            nginx -t && systemctl reload nginx && print_success "Nginx reloaded"
        fi
    fi
    press_enter
}

disable_site() {
    echo ""
    echo -e "${WHITE}Enabled sites to disable:${NC}"
    
    local sites=()
    local i=1
    for site in /etc/nginx/sites-enabled/*; do
        if [ -L "$site" ] || [ -f "$site" ]; then
            local name=$(basename "$site")
            printf "  %d) %s\n" "$i" "$name"
            sites+=("$name")
            ((i++))
        fi
    done
    
    if [ ${#sites[@]} -eq 0 ]; then
        echo -e "  ${DIM}No sites to disable${NC}"
        press_enter
        return
    fi
    
    echo ""
    read -p "  Enter site number to disable (0 to cancel): " num
    
    if [ "$num" -gt 0 ] 2>/dev/null && [ "$num" -le ${#sites[@]} ] 2>/dev/null; then
        local site="${sites[$((num-1))]}"
        
        if [ "$site" = "default" ]; then
            echo -e "${YELLOW}Warning: Disabling the default site${NC}"
            read -p "  Are you sure? (y/n) [n]: " confirm
            [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return
        fi
        
        rm -f "/etc/nginx/sites-enabled/$site"
        print_success "Site '$site' disabled"
        
        echo ""
        read -p "  Reload Nginx? (y/n) [y]: " reload
        reload=${reload:-y}
        if [ "$reload" = "y" ] || [ "$reload" = "Y" ]; then
            nginx -t && systemctl reload nginx && print_success "Nginx reloaded"
        fi
    fi
    press_enter
}

view_site_config() {
    echo ""
    echo -e "${WHITE}Select site to view:${NC}"
    
    local sites=()
    local i=1
    for site in /etc/nginx/sites-available/*; do
        if [ -f "$site" ]; then
            local name=$(basename "$site")
            printf "  %d) %s\n" "$i" "$name"
            sites+=("$name")
            ((i++))
        fi
    done
    
    if [ ${#sites[@]} -eq 0 ]; then
        echo -e "  ${DIM}No sites found${NC}"
        press_enter
        return
    fi
    
    echo ""
    read -p "  Enter site number (0 to cancel): " num
    
    if [ "$num" -gt 0 ] 2>/dev/null && [ "$num" -le ${#sites[@]} ] 2>/dev/null; then
        local site="${sites[$((num-1))]}"
        clear
        echo ""
        echo -e "${CYAN}━━━ /etc/nginx/sites-available/$site ━━━${NC}"
        echo ""
        
        # Show with less for scrolling
        if command -v less &>/dev/null; then
            echo -e "${DIM}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${DIM}║${NC}  ${WHITE}Navigation:${NC} Press ${GREEN}q${NC} to quit, ${GREEN}arrows${NC} to scroll                       ${DIM}║${NC}"
            echo -e "${DIM}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
            sleep 1
            less "/etc/nginx/sites-available/$site"
        else
            cat "/etc/nginx/sites-available/$site"
            press_enter
        fi
    fi
}

edit_site_config() {
    echo ""
    echo -e "${WHITE}Select site to edit:${NC}"
    
    local sites=()
    local i=1
    for site in /etc/nginx/sites-available/*; do
        if [ -f "$site" ]; then
            local name=$(basename "$site")
            printf "  %d) %s\n" "$i" "$name"
            sites+=("$name")
            ((i++))
        fi
    done
    
    if [ ${#sites[@]} -eq 0 ]; then
        echo -e "  ${DIM}No sites found${NC}"
        press_enter
        return
    fi
    
    echo ""
    read -p "  Enter site number (0 to cancel): " num
    
    if [ "$num" -gt 0 ] 2>/dev/null && [ "$num" -le ${#sites[@]} ] 2>/dev/null; then
        local site="${sites[$((num-1))]}"
        local editor="${EDITOR:-nano}"
        
        # Check for available editors
        if ! command -v "$editor" &>/dev/null; then
            if command -v nano &>/dev/null; then
                editor="nano"
            elif command -v vim &>/dev/null; then
                editor="vim"
            elif command -v vi &>/dev/null; then
                editor="vi"
            else
                print_error "No text editor found. Install nano: apt install nano"
                press_enter
                return
            fi
        fi
        
        echo ""
        echo -e "${CYAN}Opening $site with $editor...${NC}"
        echo -e "${DIM}Save and exit to return to menu${NC}"
        sleep 1
        
        $editor "/etc/nginx/sites-available/$site"
        
        echo ""
        read -p "  Test Nginx configuration? (y/n) [y]: " test_it
        test_it=${test_it:-y}
        if [ "$test_it" = "y" ] || [ "$test_it" = "Y" ]; then
            nginx -t
            if [ $? -eq 0 ]; then
                read -p "  Reload Nginx? (y/n) [y]: " reload
                reload=${reload:-y}
                if [ "$reload" = "y" ] || [ "$reload" = "Y" ]; then
                    systemctl reload nginx && print_success "Nginx reloaded"
                fi
            fi
        fi
    fi
    press_enter
}

add_new_site() {
    clear
    echo ""
    draw_box_top
    draw_box_line "                    ADD NEW NGINX SITE"
    draw_box_bottom
    echo ""
    
    echo -e "${WHITE}This will run the site creation wizard for a new Aegis service.${NC}"
    echo ""
    echo "  Available site templates:"
    echo "    1) Aegis service proxy (ReactMap, Dragonite, etc.)"
    echo "    2) Custom reverse proxy"
    echo "    3) Static file site"
    echo ""
    echo "    0) Cancel"
    echo ""
    read -p "  Select template: " template
    
    case $template in
        1)
            echo ""
            echo -e "${WHITE}${BOLD}Aegis Service Proxy Setup${NC}"
            echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
            echo ""
            
            read -p "  Site name (e.g., 'map', 'admin'): " site_name
            [ -z "$site_name" ] && return
            
            read -p "  Backend port (e.g., 6001 for ReactMap): " backend_port
            [ -z "$backend_port" ] && return
            
            read -p "  Domain or subdomain (e.g., map.example.com): " domain
            [ -z "$domain" ] && return
            
            echo ""
            echo -e "${CYAN}Creating site configuration...${NC}"
            
            create_simple_proxy_site "$site_name" "$backend_port" "$domain"
            ;;
        2)
            echo ""
            read -p "  Site name: " site_name
            [ -z "$site_name" ] && return
            
            read -p "  Backend URL (e.g., http://localhost:8080): " backend_url
            [ -z "$backend_url" ] && return
            
            read -p "  Server name/domain: " domain
            [ -z "$domain" ] && return
            
            create_custom_proxy_site "$site_name" "$backend_url" "$domain"
            ;;
        3)
            echo ""
            read -p "  Site name: " site_name
            [ -z "$site_name" ] && return
            
            read -p "  Document root path: " doc_root
            [ -z "$doc_root" ] && return
            
            read -p "  Server name/domain: " domain
            [ -z "$domain" ] && return
            
            create_static_site "$site_name" "$doc_root" "$domain"
            ;;
        0|"") return ;;
    esac
    
    press_enter
}

create_simple_proxy_site() {
    local name=$1
    local port=$2
    local domain=$3
    
    cat > "/etc/nginx/sites-available/aegis-$name" << EOF
# Aegis $name site - Auto-generated
server {
    listen 80;
    server_name $domain;
    
    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_connect_timeout 300;
    }
}
EOF
    
    print_success "Site configuration created: /etc/nginx/sites-available/aegis-$name"
    
    echo ""
    read -p "  Enable this site now? (y/n) [y]: " enable_it
    enable_it=${enable_it:-y}
    if [ "$enable_it" = "y" ] || [ "$enable_it" = "Y" ]; then
        ln -sf "/etc/nginx/sites-available/aegis-$name" "/etc/nginx/sites-enabled/aegis-$name"
        nginx -t && systemctl reload nginx && print_success "Site enabled and Nginx reloaded"
    fi
    
    echo ""
    read -p "  Set up SSL with Let's Encrypt? (y/n) [n]: " setup_ssl
    if [ "$setup_ssl" = "y" ] || [ "$setup_ssl" = "Y" ]; then
        if command -v certbot &>/dev/null; then
            certbot --nginx -d "$domain"
        else
            print_warning "Certbot not installed. Install with: apt install certbot python3-certbot-nginx"
        fi
    fi
}

create_custom_proxy_site() {
    local name=$1
    local backend=$2
    local domain=$3
    
    cat > "/etc/nginx/sites-available/$name" << EOF
# Custom proxy site - $name
server {
    listen 80;
    server_name $domain;
    
    location / {
        proxy_pass $backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    
    print_success "Site configuration created: /etc/nginx/sites-available/$name"
    
    read -p "  Enable this site now? (y/n) [y]: " enable_it
    enable_it=${enable_it:-y}
    if [ "$enable_it" = "y" ] || [ "$enable_it" = "Y" ]; then
        ln -sf "/etc/nginx/sites-available/$name" "/etc/nginx/sites-enabled/$name"
        nginx -t && systemctl reload nginx && print_success "Site enabled and Nginx reloaded"
    fi
}

create_static_site() {
    local name=$1
    local root=$2
    local domain=$3
    
    cat > "/etc/nginx/sites-available/$name" << EOF
# Static site - $name
server {
    listen 80;
    server_name $domain;
    root $root;
    index index.html index.htm;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    
    print_success "Site configuration created: /etc/nginx/sites-available/$name"
    
    read -p "  Enable this site now? (y/n) [y]: " enable_it
    enable_it=${enable_it:-y}
    if [ "$enable_it" = "y" ] || [ "$enable_it" = "Y" ]; then
        ln -sf "/etc/nginx/sites-available/$name" "/etc/nginx/sites-enabled/$name"
        nginx -t && systemctl reload nginx && print_success "Site enabled and Nginx reloaded"
    fi
}

delete_site() {
    echo ""
    echo -e "${RED}${BOLD}DELETE SITE${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "${WHITE}Select site to delete:${NC}"
    
    local sites=()
    local i=1
    for site in /etc/nginx/sites-available/*; do
        if [ -f "$site" ]; then
            local name=$(basename "$site")
            printf "  %d) %s\n" "$i" "$name"
            sites+=("$name")
            ((i++))
        fi
    done
    
    if [ ${#sites[@]} -eq 0 ]; then
        echo -e "  ${DIM}No sites found${NC}"
        press_enter
        return
    fi
    
    echo ""
    read -p "  Enter site number to DELETE (0 to cancel): " num
    
    if [ "$num" -gt 0 ] 2>/dev/null && [ "$num" -le ${#sites[@]} ] 2>/dev/null; then
        local site="${sites[$((num-1))]}"
        
        echo ""
        echo -e "${RED}WARNING: This will permanently delete '$site'${NC}"
        read -p "  Type 'DELETE' to confirm: " confirm
        
        if [ "$confirm" = "DELETE" ]; then
            rm -f "/etc/nginx/sites-enabled/$site"
            rm -f "/etc/nginx/sites-available/$site"
            print_success "Site '$site' deleted"
            nginx -t && systemctl reload nginx
        else
            echo -e "${DIM}Cancelled${NC}"
        fi
    fi
    press_enter
}

# =============================================================================
# MAINTENANCE MODE - SSL/CERTIFICATE MANAGEMENT
# =============================================================================

ssl_management_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "                    SSL CERTIFICATE MANAGEMENT"
        draw_box_bottom
        echo ""
        
        # Show current certificates
        echo -e "${WHITE}${BOLD}Current Certificates${NC}"
        echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
        
        if command -v certbot &>/dev/null; then
            certbot certificates 2>/dev/null | grep -E "Certificate Name:|Domains:|Expiry Date:" | while read line; do
                echo "  $line"
            done
            [ -z "$(certbot certificates 2>/dev/null | grep 'Certificate Name:')" ] && echo -e "  ${DIM}No certificates found${NC}"
        else
            echo -e "  ${YELLOW}Certbot not installed${NC}"
        fi
        echo ""
        
        echo -e "${WHITE}${BOLD}Actions${NC}"
        echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo "    1) Request new certificate"
        echo "    2) Renew all certificates"
        echo "    3) Test renewal (dry-run)"
        echo "    4) Revoke certificate"
        echo "    5) Delete certificate"
        echo "    6) Install Certbot (if not installed)"
        echo ""
        echo "    0) Back to maintenance menu"
        echo ""
        read -p "  Select option: " choice
        
        case $choice in
            1)
                echo ""
                read -p "  Enter domain name: " domain
                if [ -n "$domain" ]; then
                    certbot --nginx -d "$domain"
                fi
                press_enter
                ;;
            2)
                echo ""
                certbot renew
                press_enter
                ;;
            3)
                echo ""
                certbot renew --dry-run
                press_enter
                ;;
            4)
                echo ""
                read -p "  Enter certificate name to revoke: " cert_name
                if [ -n "$cert_name" ]; then
                    certbot revoke --cert-name "$cert_name"
                fi
                press_enter
                ;;
            5)
                echo ""
                read -p "  Enter certificate name to delete: " cert_name
                if [ -n "$cert_name" ]; then
                    certbot delete --cert-name "$cert_name"
                fi
                press_enter
                ;;
            6)
                echo ""
                if command -v apt-get &>/dev/null; then
                    apt-get update && apt-get install -y certbot python3-certbot-nginx
                elif command -v yum &>/dev/null; then
                    yum install -y certbot python3-certbot-nginx
                fi
                press_enter
                ;;
            0|"") return ;;
        esac
    done
}

# =============================================================================
# MAINTENANCE MODE - FAIL2BAN MANAGEMENT
# =============================================================================

fail2ban_management_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "                    FAIL2BAN MANAGEMENT"
        draw_box_bottom
        echo ""
        
        if ! command -v fail2ban-client &>/dev/null; then
            echo -e "  ${YELLOW}Fail2Ban is not installed${NC}"
            echo ""
            read -p "  Install Fail2Ban? (y/n): " install_it
            if [ "$install_it" = "y" ] || [ "$install_it" = "Y" ]; then
                install_fail2ban
            fi
            press_enter
            return
        fi
        
        # Show jail status
        echo -e "${WHITE}${BOLD}Jail Status${NC}"
        echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
        
        fail2ban-client status 2>/dev/null | head -20
        echo ""
        
        echo -e "${WHITE}${BOLD}Actions${NC}"
        echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo "    1) View jail details"
        echo "    2) Unban IP address"
        echo "    3) Ban IP address"
        echo "    4) View banned IPs"
        echo "    5) Reload Fail2Ban"
        echo "    6) View Fail2Ban log"
        echo ""
        echo "    0) Back to maintenance menu"
        echo ""
        read -p "  Select option: " choice
        
        case $choice in
            1)
                echo ""
                echo "  Available jails:"
                fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*://; s/,/\n/g' | while read jail; do
                    echo "    - $jail"
                done
                echo ""
                read -p "  Enter jail name: " jail_name
                if [ -n "$jail_name" ]; then
                    fail2ban-client status "$jail_name"
                fi
                press_enter
                ;;
            2)
                echo ""
                read -p "  Enter IP to unban: " ip_addr
                read -p "  Enter jail name (or 'all'): " jail_name
                if [ -n "$ip_addr" ]; then
                    if [ "$jail_name" = "all" ]; then
                        fail2ban-client unban "$ip_addr"
                    else
                        fail2ban-client set "$jail_name" unbanip "$ip_addr"
                    fi
                fi
                press_enter
                ;;
            3)
                echo ""
                read -p "  Enter IP to ban: " ip_addr
                read -p "  Enter jail name: " jail_name
                if [ -n "$ip_addr" ] && [ -n "$jail_name" ]; then
                    fail2ban-client set "$jail_name" banip "$ip_addr"
                fi
                press_enter
                ;;
            4)
                echo ""
                echo -e "${WHITE}Banned IPs by jail:${NC}"
                fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*://; s/,/\n/g' | while read jail; do
                    jail=$(echo "$jail" | tr -d ' ')
                    [ -z "$jail" ] && continue
                    local banned=$(fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list:" | sed 's/.*://')
                    if [ -n "$banned" ] && [ "$banned" != " " ]; then
                        echo "  $jail: $banned"
                    fi
                done
                press_enter
                ;;
            5)
                fail2ban-client reload && print_success "Fail2Ban reloaded"
                press_enter
                ;;
            6)
                echo ""
                echo -e "${DIM}Press q to quit viewer${NC}"
                sleep 1
                less /var/log/fail2ban.log
                ;;
            0|"") return ;;
        esac
    done
}

# =============================================================================
# MAINTENANCE MODE - FIREWALL MANAGEMENT
# =============================================================================

firewall_management_menu() {
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "                    UFW FIREWALL MANAGEMENT"
        draw_box_bottom
        echo ""
        
        if ! command -v ufw &>/dev/null; then
            echo -e "  ${YELLOW}UFW is not installed${NC}"
            echo ""
            read -p "  Install UFW? (y/n): " install_it
            if [ "$install_it" = "y" ] || [ "$install_it" = "Y" ]; then
                apt-get install -y ufw 2>/dev/null || yum install -y ufw 2>/dev/null
            fi
            press_enter
            return
        fi
        
        # Show current status
        echo -e "${WHITE}${BOLD}Current Status${NC}"
        echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
        ufw status verbose 2>/dev/null | head -20
        echo ""
        
        echo -e "${WHITE}${BOLD}Actions${NC}"
        echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo "    1) Enable firewall"
        echo "    2) Disable firewall"
        echo "    3) Allow port"
        echo "    4) Deny port"
        echo "    5) Delete rule"
        echo "    6) View numbered rules"
        echo "    7) Reset firewall (removes all rules)"
        echo ""
        echo "    0) Back to maintenance menu"
        echo ""
        read -p "  Select option: " choice
        
        case $choice in
            1)
                echo ""
                echo -e "${YELLOW}WARNING: Make sure SSH is allowed before enabling!${NC}"
                read -p "  Enable UFW? (y/n): " confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    ufw --force enable
                fi
                press_enter
                ;;
            2)
                ufw disable
                press_enter
                ;;
            3)
                echo ""
                read -p "  Enter port to allow (e.g., 80, 443, 22): " port
                if [ -n "$port" ]; then
                    ufw allow "$port"
                fi
                press_enter
                ;;
            4)
                echo ""
                read -p "  Enter port to deny: " port
                if [ -n "$port" ]; then
                    ufw deny "$port"
                fi
                press_enter
                ;;
            5)
                echo ""
                ufw status numbered
                echo ""
                read -p "  Enter rule number to delete: " rule_num
                if [ -n "$rule_num" ]; then
                    ufw delete "$rule_num"
                fi
                press_enter
                ;;
            6)
                echo ""
                ufw status numbered
                press_enter
                ;;
            7)
                echo ""
                echo -e "${RED}WARNING: This will remove ALL firewall rules!${NC}"
                read -p "  Type 'RESET' to confirm: " confirm
                if [ "$confirm" = "RESET" ]; then
                    ufw reset
                fi
                press_enter
                ;;
            0|"") return ;;
        esac
    done
}

# =============================================================================
# MAINTENANCE MODE - MAIN MENU
# =============================================================================

maintenance_mode() {
    while true; do
        show_status_dashboard
        
        echo -e "${WHITE}${BOLD}Maintenance Options${NC}"
        echo -e "${DIM}────────────────────────────────────────────────────────────────────────────${NC}"
        echo ""
        echo "    1) Service Management      - Start, stop, restart services"
        echo "    2) Site Management         - Enable, disable, add, edit sites"
        echo "    3) SSL Certificates        - Manage Let's Encrypt certificates"
        echo "    4) Fail2Ban Management     - Manage bans and jails"
        echo "    5) Firewall (UFW)          - Manage firewall rules"
        echo ""
        echo "    v) View Nginx Error Log"
        echo "    t) Test Nginx Configuration"
        echo "    r) Refresh Status"
        echo ""
        echo "    0) Exit / Return to Main Menu"
        echo ""
        read -p "  Select option: " choice
        
        case $choice in
            1) service_management_menu ;;
            2) site_management_menu ;;
            3) ssl_management_menu ;;
            4) fail2ban_management_menu ;;
            5) firewall_management_menu ;;
            v|V)
                clear
                echo ""
                echo -e "${CYAN}━━━ Nginx Error Log (last 50 lines) ━━━${NC}"
                echo -e "${DIM}Press q to quit viewer${NC}"
                sleep 1
                tail -50 /var/log/nginx/error.log 2>/dev/null | less -R
                ;;
            t|T)
                echo ""
                nginx -t
                press_enter
                ;;
            r|R) continue ;;
            0|"")
                return_to_main
                ;;
        esac
    done
}

# =============================================================================
# MODE SELECTION
# =============================================================================

show_mode_selection() {
    clear
    echo ""
    draw_box_top
    draw_box_line "          AEGIS NGINX SECURITY & MANAGEMENT SCRIPT"
    draw_box_divider
    draw_box_line "  Choose how you want to use this script:"
    draw_box_bottom
    echo ""
    
    echo -e "  ${WHITE}${BOLD}1) Setup Mode${NC}"
    echo -e "     ${DIM}First-time setup of Nginx reverse proxy, SSL, Fail2Ban, UFW${NC}"
    echo -e "     ${DIM}Run this for initial configuration of your Aegis stack${NC}"
    echo ""
    echo -e "  ${WHITE}${BOLD}2) Maintenance Mode${NC}"
    echo -e "     ${DIM}Manage existing Nginx configuration, services, and security${NC}"
    echo -e "     ${DIM}Status dashboard, service control, site management${NC}"
    echo ""
    echo -e "  ${WHITE}${BOLD}0) Exit${NC}"
    echo ""
    read -p "  Select mode: " mode_choice
    
    case $mode_choice in
        1)
            SCRIPT_MODE="setup"
            ;;
        2)
            SCRIPT_MODE="maintenance"
            ;;
        0|"")
            return_to_main
            ;;
        *)
            show_mode_selection
            ;;
    esac
}

# Return to main menu function
return_to_main() {
    # Restore ownership of modified files
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        chown "$REAL_USER:$REAL_GROUP" docker-compose.yaml 2>/dev/null || true
    fi
    
    if [ "$AEGIS_LAUNCHER" = "1" ]; then
        echo ""
        echo -e "${CYAN}Returning to Aegis Control Panel...${NC}"
        sleep 1
    fi
    exit 0
}

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
        # Add include directive inside http block
        sed -i '/http {/a \    include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
    fi
    
    # Remove default site if exists
    rm -f /etc/nginx/sites-enabled/default
    
    # Check for existing configs that might conflict
    print_info "Checking for existing nginx configurations..."
    EXISTING_CONFIGS=()
    
    # Check sites-available and sites-enabled for any configs with our subdomains
    for conf_dir in /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d; do
        if [ -d "$conf_dir" ]; then
            for conf in "$conf_dir"/*; do
                if [ -f "$conf" ]; then
                    # Check if config contains any of our subdomains
                    if grep -q "${BASE_DOMAIN}" "$conf" 2>/dev/null; then
                        conf_name=$(basename "$conf")
                        # Skip if it's an aegis config we created
                        if [[ "$conf_name" != aegis-* ]]; then
                            EXISTING_CONFIGS+=("$conf")
                        fi
                    fi
                fi
            done
        fi
    done
    
    if [ ${#EXISTING_CONFIGS[@]} -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║           CONFLICTING NGINX CONFIGS DETECTED                   ║${NC}"
        echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        print_warning "Found existing nginx configs that may conflict with Aegis:"
        echo ""
        for conf in "${EXISTING_CONFIGS[@]}"; do
            echo -e "  ${RED}→${NC} $conf"
        done
        echo ""
        print_info "These configs contain references to '${BASE_DOMAIN}' and may cause:"
        echo "  • 'conflicting server name' errors"
        echo "  • nginx failing to start or reload"
        echo "  • SSL certificate issues"
        echo ""
        
        read -p "Would you like to remove these conflicting configs? (y/n) [y]: " REMOVE_CONFLICTS
        REMOVE_CONFLICTS=${REMOVE_CONFLICTS:-y}
        
        if [ "$REMOVE_CONFLICTS" = "y" ] || [ "$REMOVE_CONFLICTS" = "Y" ]; then
            print_info "Removing conflicting configs..."
            for conf in "${EXISTING_CONFIGS[@]}"; do
                # Remove from sites-enabled (symlink)
                conf_name=$(basename "$conf")
                if [ -L "/etc/nginx/sites-enabled/$conf_name" ]; then
                    rm -f "/etc/nginx/sites-enabled/$conf_name"
                    print_success "Disabled: /etc/nginx/sites-enabled/$conf_name"
                fi
                # Remove the actual config file
                if [ -f "$conf" ]; then
                    rm -f "$conf"
                    print_success "Removed: $conf"
                fi
            done
            echo ""
        else
            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║                         WARNING                                ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            print_error "Conflicting configs were NOT removed!"
            print_warning "This may cause nginx to fail with 'conflicting server name' errors."
            print_warning "You may need to manually resolve conflicts after setup."
            echo ""
            print_info "To fix manually later, remove or rename these files:"
            for conf in "${EXISTING_CONFIGS[@]}"; do
                echo "  rm $conf"
            done
            echo ""
            
            read -p "Continue with setup anyway? (y/n) [n]: " CONTINUE_SETUP
            CONTINUE_SETUP=${CONTINUE_SETUP:-n}
            
            if [ "$CONTINUE_SETUP" != "y" ] && [ "$CONTINUE_SETUP" != "Y" ]; then
                print_error "Setup cancelled. Please remove conflicting configs and try again."
                exit 1
            fi
            
            print_warning "Continuing despite conflicts..."
        fi
    fi
    
    # Clean up any existing Aegis configs to prevent duplicates
    print_info "Removing any existing Aegis configurations..."
    rm -f /etc/nginx/sites-available/aegis-*
    rm -f /etc/nginx/sites-enabled/aegis-*
    
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
    
    # Run nginx -t and capture output
    NGINX_TEST_OUTPUT=$(nginx -t 2>&1) || true
    NGINX_TEST_EXIT=$?
    
    # Show the output
    echo "$NGINX_TEST_OUTPUT"
    echo ""
    
    # Check if test passed (exit code 0 and no "test failed" in output)
    if [ $NGINX_TEST_EXIT -eq 0 ] && ! echo "$NGINX_TEST_OUTPUT" | grep -q "test failed"; then
        print_success "Nginx configuration is valid"
        print_info "Reloading Nginx..."
        
        if systemctl reload nginx 2>/dev/null; then
            print_success "Nginx reloaded successfully"
        else
            print_warning "Nginx reload may have had issues, but continuing..."
        fi
    else
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║              NGINX SYNTAX ERROR DETECTED!                      ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        print_error "Nginx configuration test failed!"
        echo ""
        print_error "Error details:"
        echo "$NGINX_TEST_OUTPUT" | grep -i "emerg\|error\|failed" | while read line; do
            echo -e "  ${RED}→${NC} $line"
        done
        echo ""
        
        # Check for common issues and provide guidance
        if echo "$NGINX_TEST_OUTPUT" | grep -q "conflicting server name"; then
            print_warning "Duplicate server names detected!"
            print_info "You may have existing nginx configs for these domains."
            print_info "Check these locations for conflicting configs:"
            echo "  - /etc/nginx/sites-enabled/"
            echo "  - /etc/nginx/conf.d/"
            echo ""
            print_info "Remove or rename conflicting configs, then run: nginx -t && systemctl reload nginx"
        fi
        
        if echo "$NGINX_TEST_OUTPUT" | grep -q "unknown directive.*stream"; then
            print_warning "Stream directive error detected!"
            print_info "The 'stream' block may be in the wrong location in nginx.conf"
            print_info "The stream block must be at ROOT level, not inside http{} block."
            echo ""
            print_info "Edit /etc/nginx/nginx.conf and ensure stream{} is at the same level as http{}"
            echo ""
            print_info "Or remove the stream config if you don't need TCP proxying:"
            echo "  rm /etc/nginx/stream.d/rotom-devices.conf"
            echo "  # Remove 'stream { ... }' block from /etc/nginx/nginx.conf"
        fi
        
        echo ""
        print_warning "SSL setup will likely fail if nginx config has errors!"
        print_info "It is recommended to fix the errors above before continuing."
        echo ""
        read -p "Would you like to continue to SSL setup anyway? (y/n) [n]: " CONTINUE_ANYWAY
        CONTINUE_ANYWAY=${CONTINUE_ANYWAY:-n}
        if [ "$CONTINUE_ANYWAY" != "y" ] && [ "$CONTINUE_ANYWAY" != "Y" ]; then
            print_error "Setup aborted. Please fix nginx configuration errors first."
            print_info "After fixing, run: sudo nginx -t && sudo systemctl reload nginx"
            exit 1
        fi
        print_warning "Continuing to SSL setup despite nginx syntax errors..."
        print_warning "You will need to fix nginx config manually after SSL certificates are obtained."
    fi
    
    echo ""
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

# Setup Rotom device port (7070) and web interface
setup_rotom_device_port() {
    echo ""
    print_info "Rotom Configuration"
    echo ""
    
    # =========================================================================
    # Part 1: Rotom Web Interface (HTTP - port 6003)
    # =========================================================================
    
    # Check if Rotom web interface config already exists
    if [ ! -f "/etc/nginx/sites-available/aegis-rotom" ]; then
        print_warning "Rotom web interface (port 6003) is not configured in nginx."
        echo ""
        read -p "Would you like to configure Rotom web interface access? (y/n) [y]: " SETUP_ROTOM_WEB
        SETUP_ROTOM_WEB=${SETUP_ROTOM_WEB:-y}
        
        if [ "$SETUP_ROTOM_WEB" = "y" ] || [ "$SETUP_ROTOM_WEB" = "Y" ]; then
            echo ""
            echo "  How would you like to access Rotom web interface?"
            echo ""
            echo "  1) Subdomain (e.g., rotom.yourdomain.com)"
            echo "  2) Path-based (e.g., yourdomain.com/rotom)"
            echo ""
            read -p "  Select option [1-2, default: 1]: " ROTOM_ACCESS_TYPE
            ROTOM_ACCESS_TYPE=${ROTOM_ACCESS_TYPE:-1}
            
            # Get the base domain if not already set
            if [ -z "$BASE_DOMAIN" ]; then
                read -p "  Enter your base domain (e.g., example.com): " BASE_DOMAIN
                if [ -z "$BASE_DOMAIN" ]; then
                    print_error "Base domain is required."
                    return
                fi
            fi
            
            if [ "$ROTOM_ACCESS_TYPE" = "1" ]; then
                # Subdomain setup
                read -p "  Enter subdomain for Rotom [rotom]: " ROTOM_SUBDOMAIN
                ROTOM_SUBDOMAIN=${ROTOM_SUBDOMAIN:-rotom}
                
                print_info "Creating Rotom subdomain config: ${ROTOM_SUBDOMAIN}.${BASE_DOMAIN}"
                
                cat > "/etc/nginx/sites-available/aegis-rotom" << EOF
# Nginx reverse proxy configuration for Rotom Web Interface
# Generated by Aegis All-in-One nginx-setup.sh

server {
    listen 80;
    server_name ${ROTOM_SUBDOMAIN}.${BASE_DOMAIN};
    
    location / {
        proxy_pass http://127.0.0.1:6003;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF
            else
                # Path-based setup
                print_info "Creating Rotom path-based config: ${BASE_DOMAIN}/rotom"
                
                cat > "/etc/nginx/sites-available/aegis-rotom" << EOF
# Nginx reverse proxy configuration for Rotom Web Interface (path-based)
# Generated by Aegis All-in-One nginx-setup.sh
# Add this location block to your main server config for ${BASE_DOMAIN}

# Path-based Rotom access
location /rotom/ {
    proxy_pass http://127.0.0.1:6003/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
}
EOF
                print_warning "Path-based config created. You may need to include this in your main server block."
                print_info "File: /etc/nginx/sites-available/aegis-rotom"
            fi
            
            # Create symlink to sites-enabled
            if [ ! -L "/etc/nginx/sites-enabled/aegis-rotom" ]; then
                ln -sf /etc/nginx/sites-available/aegis-rotom /etc/nginx/sites-enabled/aegis-rotom
                print_success "Created symlink: /etc/nginx/sites-enabled/aegis-rotom"
            fi
            
            print_success "Rotom web interface config created"
            
            # Test nginx config
            if nginx -t 2>&1 | grep -q "test is successful"; then
                systemctl reload nginx 2>/dev/null || true
                print_success "Nginx reloaded with Rotom config"
            else
                print_warning "Nginx config test failed - check the configuration"
            fi
        fi
    else
        print_success "Rotom web interface config already exists"
    fi
    
    echo ""
    
    # =========================================================================
    # Part 2: Rotom Device Connections (WebSocket - port 7070)
    # =========================================================================
    
    print_info "Rotom Device Port Configuration (WebSocket port 7070)"
    print_info "Port 7070 is used for device WebSocket connections to Rotom backend."
    echo ""
    echo "  How would you like to handle device connections?"
    echo ""
    echo "  1) Direct connection - Devices connect directly to port 7070 (recommended)"
    echo "     - Simpler setup, no nginx proxy needed"
    echo "     - Requires port 7070 to be open in firewall"
    echo ""
    echo "  2) WebSocket proxy - Nginx proxies WebSocket connections"
    echo "     - Devices connect via subdomain (e.g., devices.yourdomain.com)"
    echo "     - Can use SSL/TLS with Let's Encrypt"
    echo "     - Uses standard HTTP/WebSocket (no stream module needed)"
    echo ""
    echo "  3) TCP Stream proxy - Raw TCP proxying (advanced)"
    echo "     - Requires nginx stream module"
    echo "     - Lower level proxying"
    echo ""
    read -p "  Select option [1-3, default: 1]: " ROTOM_DEVICE_OPTION
    ROTOM_DEVICE_OPTION=${ROTOM_DEVICE_OPTION:-1}
    
    case "$ROTOM_DEVICE_OPTION" in
        2)
            # WebSocket proxy setup (HTTP-based, no stream module needed)
            print_info "Setting up WebSocket proxy for Rotom device connections..."
            
            if [ -z "$BASE_DOMAIN" ]; then
                read -p "  Enter your base domain (e.g., example.com): " BASE_DOMAIN
            fi
            
            read -p "  Enter subdomain for device connections [devices]: " ROTOM_DEVICES_SUBDOMAIN
            ROTOM_DEVICES_SUBDOMAIN=${ROTOM_DEVICES_SUBDOMAIN:-devices}
            
            print_info "Creating WebSocket proxy config: ${ROTOM_DEVICES_SUBDOMAIN}.${BASE_DOMAIN}"
            
            cat > "/etc/nginx/sites-available/aegis-rotom-devices" << EOF
# Nginx WebSocket proxy for Rotom Device Connections
# Generated by Aegis All-in-One nginx-setup.sh
# Devices connect via WebSocket to this subdomain

server {
    listen 80;
    server_name ${ROTOM_DEVICES_SUBDOMAIN}.${BASE_DOMAIN};
    
    location / {
        proxy_pass http://127.0.0.1:7070;
        proxy_http_version 1.1;
        
        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Timeouts for long-lived WebSocket connections
        proxy_connect_timeout 7d;
        proxy_send_timeout 7d;
        proxy_read_timeout 7d;
    }
}
EOF
            
            # Create symlink
            ln -sf /etc/nginx/sites-available/aegis-rotom-devices /etc/nginx/sites-enabled/aegis-rotom-devices
            
            print_success "WebSocket proxy config created"
            print_success "Symlink created: /etc/nginx/sites-enabled/aegis-rotom-devices"
            
            # Test and reload
            if nginx -t 2>&1 | grep -q "test is successful"; then
                systemctl reload nginx 2>/dev/null || true
                print_success "Nginx reloaded"
                echo ""
                print_info "Devices can now connect via: ws://${ROTOM_DEVICES_SUBDOMAIN}.${BASE_DOMAIN}"
                print_info "After SSL setup: wss://${ROTOM_DEVICES_SUBDOMAIN}.${BASE_DOMAIN}"
            else
                print_warning "Nginx config test failed"
                nginx -t 2>&1 | head -5
            fi
            
            return
            ;;
        3)
            # TCP Stream proxy (original behavior)
            print_info "Setting up TCP stream proxy for Rotom device connections..."
            SETUP_ROTOM_STREAM="y"
            ;;
        *)
            # Direct connection (no proxy)
            print_info "Using direct connection mode."
            print_info "Devices will connect directly to port 7070."
            print_warning "Make sure port 7070 is open in your firewall!"
            echo ""
            print_info "Firewall commands:"
            echo "  sudo ufw allow 7070/tcp"
            echo "  # or"
            echo "  sudo iptables -A INPUT -p tcp --dport 7070 -j ACCEPT"
            return
            ;;
    esac
    
    # Continue with TCP stream setup only if option 3 was selected
    SETUP_ROTOM_STREAM=${SETUP_ROTOM_STREAM:-n}
    
    if [ "$SETUP_ROTOM_STREAM" = "y" ] || [ "$SETUP_ROTOM_STREAM" = "Y" ]; then
        print_info "Setting up stream proxy for Rotom device connections..."
        
        # PRE-CHECK: Fix any existing broken stream configuration
        if nginx -t 2>&1 | grep -q "unknown directive.*stream"; then
            print_warning "Detected existing broken stream configuration in nginx.conf"
            print_info "Attempting to fix by removing incorrectly placed stream block..."
            
            # Backup first
            cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d_%H%M%S)
            
            # Remove any stream blocks (they're in the wrong place or module not loaded)
            # Use a temporary file approach for safer multi-line removal
            awk '
                /stream[[:space:]]*\{/ { in_stream=1; brace_count=1; next }
                in_stream && /\{/ { brace_count++ }
                in_stream && /\}/ { brace_count--; if(brace_count==0) { in_stream=0; next } }
                !in_stream { print }
            ' /etc/nginx/nginx.conf > /etc/nginx/nginx.conf.tmp
            mv /etc/nginx/nginx.conf.tmp /etc/nginx/nginx.conf
            
            # Also remove any leftover stream-related lines
            sed -i '/include.*stream/d' /etc/nginx/nginx.conf
            sed -i '/# Stream configuration/d' /etc/nginx/nginx.conf
            sed -i '/# Include stream configuration/d' /etc/nginx/nginx.conf
            
            # Test if fix worked
            if nginx -t 2>&1 | grep -q "test is successful"; then
                print_success "Fixed broken nginx configuration"
            else
                print_warning "Config still has issues, but continuing with stream setup..."
            fi
        fi
        
        # Check if stream module is ACTUALLY available (not just compile flags)
        # We need to find the actual .so file or confirm it works
        STREAM_AVAILABLE=false
        STREAM_MODULE_FILE=""
        
        # Search for the stream module .so file
        for path in \
            "/usr/lib/nginx/modules/ngx_stream_module.so" \
            "/usr/share/nginx/modules/ngx_stream_module.so" \
            "/usr/lib64/nginx/modules/ngx_stream_module.so" \
            "/usr/local/nginx/modules/ngx_stream_module.so"; do
            if [ -f "$path" ]; then
                STREAM_MODULE_FILE="$path"
                STREAM_AVAILABLE=true
                break
            fi
        done
        
        # Also search with find
        if [ -z "$STREAM_MODULE_FILE" ]; then
            STREAM_MODULE_FILE=$(find /usr /lib -name "ngx_stream_module.so" 2>/dev/null | head -1)
            if [ -n "$STREAM_MODULE_FILE" ]; then
                STREAM_AVAILABLE=true
            fi
        fi
        
        # Check modules-enabled
        if [ -f "/etc/nginx/modules-enabled/50-mod-stream.conf" ]; then
            if grep -q "ngx_stream_module" /etc/nginx/modules-enabled/50-mod-stream.conf 2>/dev/null; then
                STREAM_AVAILABLE=true
                if [ -z "$STREAM_MODULE_FILE" ]; then
                    STREAM_MODULE_FILE=$(grep -oP 'load_module\s+\K[^;]+' /etc/nginx/modules-enabled/50-mod-stream.conf 2>/dev/null | head -1)
                fi
            fi
        fi
        
        if [ "$STREAM_AVAILABLE" = false ]; then
            print_warning "Nginx stream module is NOT installed."
            print_info "The stream module .so file was not found on this system."
            echo ""
            
            # Offer to install stream module
            if command -v apt-get &> /dev/null; then
                read -p "Would you like to install the nginx stream module now? (y/n) [y]: " INSTALL_STREAM
                INSTALL_STREAM=${INSTALL_STREAM:-y}
                
                if [ "$INSTALL_STREAM" = "y" ] || [ "$INSTALL_STREAM" = "Y" ]; then
                    print_info "Installing nginx stream module..."
                    apt-get update -y
                    
                    # Try libnginx-mod-stream first (for nginx from Ubuntu repos)
                    if apt-get install -y libnginx-mod-stream 2>/dev/null; then
                        print_success "Stream module installed (libnginx-mod-stream)"
                        STREAM_AVAILABLE=true
                        # Find the newly installed module
                        STREAM_MODULE_FILE=$(find /usr /lib -name "ngx_stream_module.so" 2>/dev/null | head -1)
                    else
                        print_warning "libnginx-mod-stream not available, trying nginx-extras..."
                        if apt-get install -y nginx-extras 2>/dev/null; then
                            print_success "Stream module installed (nginx-extras)"
                            STREAM_AVAILABLE=true
                            STREAM_MODULE_FILE=$(find /usr /lib -name "ngx_stream_module.so" 2>/dev/null | head -1)
                        else
                            print_error "Could not install stream module."
                            print_info "You may need to install a different nginx package or compile nginx with stream support."
                        fi
                    fi
                fi
            elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
                PKG_MGR=$(command -v dnf || command -v yum)
                read -p "Would you like to install nginx-mod-stream? (y/n) [y]: " INSTALL_STREAM
                INSTALL_STREAM=${INSTALL_STREAM:-y}
                if [ "$INSTALL_STREAM" = "y" ] || [ "$INSTALL_STREAM" = "Y" ]; then
                    $PKG_MGR install -y nginx-mod-stream && STREAM_AVAILABLE=true
                    STREAM_MODULE_FILE=$(find /usr /lib -name "ngx_stream_module.so" 2>/dev/null | head -1)
                fi
            fi
            
            if [ "$STREAM_AVAILABLE" = false ]; then
                print_warning "Stream module not available. Skipping stream proxy setup."
                print_info "Devices should connect directly to port 7070 on this server."
                print_info "Make sure port 7070 is open in your firewall."
                return
            fi
        else
            print_success "Stream module is available at: $STREAM_MODULE_FILE"
        fi
        
        # Find the stream module .so file
        # Check common locations and also search for it
        STREAM_MODULE_PATH=""
        
        # Check common paths first
        for path in \
            "/usr/lib/nginx/modules/ngx_stream_module.so" \
            "/usr/share/nginx/modules/ngx_stream_module.so" \
            "/usr/lib64/nginx/modules/ngx_stream_module.so" \
            "/usr/local/nginx/modules/ngx_stream_module.so" \
            "/opt/nginx/modules/ngx_stream_module.so"; do
            if [ -f "$path" ]; then
                STREAM_MODULE_PATH="$path"
                break
            fi
        done
        
        # If not found, search for it
        if [ -z "$STREAM_MODULE_PATH" ]; then
            print_info "Searching for stream module..."
            FOUND_MODULE=$(find /usr -name "ngx_stream_module.so" 2>/dev/null | head -1)
            if [ -n "$FOUND_MODULE" ]; then
                STREAM_MODULE_PATH="$FOUND_MODULE"
                print_success "Found stream module at: $STREAM_MODULE_PATH"
            fi
        fi
        
        # Check if it's referenced in modules-enabled
        if [ -z "$STREAM_MODULE_PATH" ] && [ -f "/etc/nginx/modules-enabled/50-mod-stream.conf" ]; then
            # Extract the path from the modules-enabled file
            STREAM_MODULE_PATH=$(grep -oP 'load_module\s+\K[^;]+' /etc/nginx/modules-enabled/50-mod-stream.conf 2>/dev/null | head -1)
            if [ -n "$STREAM_MODULE_PATH" ] && [ -f "$STREAM_MODULE_PATH" ]; then
                print_success "Found stream module path from modules-enabled: $STREAM_MODULE_PATH"
            else
                STREAM_MODULE_PATH=""
            fi
        fi
        
        # Check if module is already loaded via modules-enabled (installed by package)
        # This is the preferred method - don't add duplicate load_module
        if [ -f "/etc/nginx/modules-enabled/50-mod-stream.conf" ]; then
            print_success "Stream module already configured via modules-enabled"
            # Remove any duplicate load_module from nginx.conf to avoid "already loaded" error
            if grep -q "load_module.*ngx_stream_module" /etc/nginx/nginx.conf 2>/dev/null; then
                print_info "Removing duplicate load_module from nginx.conf..."
                sed -i '/load_module.*ngx_stream_module/d' /etc/nginx/nginx.conf
                print_success "Removed duplicate load_module directive"
            fi
        elif [ -n "$STREAM_MODULE_PATH" ]; then
            # Module file exists but not configured via modules-enabled
            # Check if load_module is already in nginx.conf
            if ! grep -q "load_module.*ngx_stream_module" /etc/nginx/nginx.conf 2>/dev/null; then
                print_info "Adding load_module directive for stream module..."
                
                # Add the load_module directive at line 1 (must be first)
                sed -i "1i load_module $STREAM_MODULE_PATH;" /etc/nginx/nginx.conf
                print_success "Added: load_module $STREAM_MODULE_PATH;"
            else
                print_success "Stream module load directive already present in nginx.conf"
            fi
        else
            # No .so file found - check if stream is truly compiled in statically
            # Create a test to see if stream directive actually works
            print_info "No stream module .so found, testing if stream is built-in..."
            
            # Backup current config
            cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.stream_test_backup
            
            # Add a minimal stream block to test
            echo -e "\nstream { }" >> /etc/nginx/nginx.conf
            
            if nginx -t 2>&1 | grep -q "test is successful"; then
                print_success "Stream is built into nginx (works without load_module)"
                # Remove the test block
                sed -i '/^stream { }$/d' /etc/nginx/nginx.conf
            else
                # Restore and fail
                cp /etc/nginx/nginx.conf.stream_test_backup /etc/nginx/nginx.conf
                rm -f /etc/nginx/nginx.conf.stream_test_backup
                print_error "Stream module is not available and no .so file found."
                print_info "Try installing: sudo apt install libnginx-mod-stream"
                return
            fi
            rm -f /etc/nginx/nginx.conf.stream_test_backup
        fi
        
        # Verify nginx config is valid
        if ! nginx -t 2>&1 | grep -q "test is successful"; then
            print_warning "Nginx config test failed - checking for issues..."
            # Show what went wrong
            nginx -t 2>&1 | head -5
        fi
        
        # Create stream config directory
        mkdir -p /etc/nginx/stream.d
        
        # Create stream config file
        cat > "/etc/nginx/stream.d/rotom-devices.conf" << 'EOF'
# Stream proxy for Rotom device connections
# This allows devices to connect via nginx on port 7070

upstream rotom_devices {
    server 127.0.0.1:17070;
}

server {
    listen 7070;
    proxy_pass rotom_devices;
    proxy_connect_timeout 60s;
    proxy_timeout 300s;
}
EOF
        
        # Backup nginx.conf
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d_%H%M%S)
        
        # First, clean up any incorrectly placed stream blocks from previous runs
        print_info "Checking for incorrectly placed stream configurations..."
        
        # Check if there's a stream block that's causing errors (not at root level)
        # The stream block at root level should have NO leading whitespace
        if grep -q "[[:space:]]stream[[:space:]]*{" /etc/nginx/nginx.conf || \
           grep -q "^[[:space:]]\+stream" /etc/nginx/nginx.conf; then
            print_warning "Found incorrectly indented stream block - removing it..."
            # Remove indented stream blocks (these are inside http{} block)
            # This is a multi-line removal - remove from "stream {" to its closing "}"
            # Using perl for multi-line regex
            if command -v perl &> /dev/null; then
                perl -i -0pe 's/\n\s+stream\s*\{[^}]*\}//gs' /etc/nginx/nginx.conf
            else
                # Fallback: remove lines containing stream directive that are indented
                sed -i '/^[[:space:]]\+stream[[:space:]]*{/d' /etc/nginx/nginx.conf
                sed -i '/^[[:space:]]\+include.*stream/d' /etc/nginx/nginx.conf
            fi
            print_success "Removed incorrectly placed stream block"
        fi
        
        # Also check for stream block WITHOUT proper closing (broken config)
        # If stream { exists but the config is broken, remove the whole stream section
        if grep -q "stream[[:space:]]*{" /etc/nginx/nginx.conf; then
            # Test if nginx config is valid
            if ! nginx -t 2>&1 | grep -q "test is successful"; then
                if nginx -t 2>&1 | grep -q "unknown directive.*stream"; then
                    print_warning "Stream block is causing errors - removing it..."
                    # Remove all stream-related content
                    sed -i '/stream[[:space:]]*{/,/^}/d' /etc/nginx/nginx.conf
                    # Also try removing just the stream lines
                    sed -i '/^stream/d' /etc/nginx/nginx.conf
                    sed -i '/stream\.d/d' /etc/nginx/nginx.conf
                    print_success "Removed broken stream configuration"
                fi
            fi
        fi
        
        # Remove any stream-related lines that might have been added incorrectly
        sed -i '/# Stream configuration for TCP proxying/d' /etc/nginx/nginx.conf
        sed -i '/include \/etc\/nginx\/nginx-stream.conf/d' /etc/nginx/nginx.conf
        sed -i '/# Include stream configuration/d' /etc/nginx/nginx.conf
        
        # Clean up the separate stream config file if it exists
        rm -f /etc/nginx/nginx-stream.conf
        
        # Check if stream block already exists at ROOT level (not inside http{})
        # A properly placed stream block should start at column 0
        if grep -q "^stream[[:space:]]*{" /etc/nginx/nginx.conf; then
            print_info "Stream block already exists in nginx.conf"
            # Check if our include is there
            if ! grep -q "stream.d" /etc/nginx/nginx.conf; then
                # Add include inside existing stream block
                sed -i '/^stream[[:space:]]*{/a\    include /etc/nginx/stream.d/*.conf;' /etc/nginx/nginx.conf
                print_success "Added stream.d include to existing stream block"
            fi
        else
            # Need to add stream block at root level (OUTSIDE http block)
            print_info "Adding stream block to nginx.conf..."
            
            # DO NOT use include for stream - add the block directly to nginx.conf
            # The stream directive must be at root level, and includes don't always work
            
            # Clean up any previous attempts
            rm -f /etc/nginx/nginx-stream.conf
            sed -i '/include.*nginx-stream/d' /etc/nginx/nginx.conf
            
            # First ensure the file ends with a newline
            sed -i -e '$a\' /etc/nginx/nginx.conf
            
            # Add the stream block DIRECTLY at the end of nginx.conf
            # This ensures it's at root level (after http{} block closes)
            cat >> /etc/nginx/nginx.conf << 'STREAMEOF'

# Stream configuration for TCP proxying (Rotom devices)
# Added by Aegis All-in-One nginx-setup.sh
# This block must be at root level (same level as http{})
stream {
    include /etc/nginx/stream.d/*.conf;
}
STREAMEOF
            
            print_success "Stream block added directly to nginx.conf"
        fi
        
        # Test the configuration
        print_info "Testing nginx configuration..."
        if nginx -t 2>&1; then
            print_success "Nginx configuration is valid"
        else
            print_error "Nginx configuration test failed!"
            echo ""
            print_info "The stream block may have been added incorrectly."
            print_info "You may need to manually edit /etc/nginx/nginx.conf"
            echo ""
            print_info "The stream block should be at the ROOT level, like this:"
            echo ""
            echo "  events { ... }"
            echo "  http { ... }"
            echo "  stream {"
            echo "      include /etc/nginx/stream.d/*.conf;"
            echo "  }"
            echo ""
            print_info "Restoring backup..."
            LATEST_BACKUP=$(ls -t /etc/nginx/nginx.conf.backup.* 2>/dev/null | head -1)
            if [ -n "$LATEST_BACKUP" ]; then
                cp "$LATEST_BACKUP" /etc/nginx/nginx.conf
                print_success "Backup restored"
            fi
            
            # Clean up stream config files
            rm -f /etc/nginx/stream.d/rotom-devices.conf
            rm -f /etc/nginx/nginx-stream.conf
            
            # Also remove any stream block we may have added
            sed -i '/# Stream configuration for TCP proxying/,/^}$/d' /etc/nginx/nginx.conf 2>/dev/null || true
            
            print_warning "Stream proxy setup failed. Devices should connect directly to port 7070."
            return
        fi
        
        # Instructions for docker-compose
        echo ""
        print_warning "IMPORTANT: Update docker-compose.yaml to use a different internal port:"
        echo ""
        echo "  Change this line in the 'rotom' service:"
        echo "    ports:"
        echo "      - 7070:7070"
        echo ""
        echo "  To:"
        echo "    ports:"
        echo "      - 17070:7070"
        echo ""
        print_info "This allows nginx to listen on 7070 and forward to Docker on 17070."
        echo ""
        
        print_success "Stream proxy configured for Rotom devices on port 7070"
    else
        print_info "Skipping stream proxy setup. Devices will connect directly to port 7070."
    fi
}

# Setup UFW Firewall
setup_firewall() {
    echo ""
    print_info "Firewall Configuration (UFW)"
    echo ""
    
    # Check if UFW is installed
    if ! command -v ufw &> /dev/null; then
        print_warning "UFW is not installed."
        read -p "Would you like to install UFW? (y/n) [y]: " INSTALL_UFW
        INSTALL_UFW=${INSTALL_UFW:-y}
        
        if [ "$INSTALL_UFW" = "y" ] || [ "$INSTALL_UFW" = "Y" ]; then
            apt-get update -y
            apt-get install -y ufw
            print_success "UFW installed"
        else
            print_warning "Skipping firewall configuration"
            return
        fi
    fi
    
    # Check if UFW is enabled
    UFW_STATUS=$(ufw status | head -1)
    if echo "$UFW_STATUS" | grep -q "inactive"; then
        print_warning "UFW firewall is currently DISABLED"
        echo ""
        echo -e "  ${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${YELLOW}║  WARNING: Your server has no firewall protection!             ║${NC}"
        echo -e "  ${YELLOW}║  Enabling UFW is strongly recommended for security.           ║${NC}"
        echo -e "  ${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -p "Would you like to enable UFW firewall? (y/n) [y]: " ENABLE_UFW
        ENABLE_UFW=${ENABLE_UFW:-y}
        
        if [ "$ENABLE_UFW" = "y" ] || [ "$ENABLE_UFW" = "Y" ]; then
            UFW_WILL_ENABLE=true
        else
            print_warning "Skipping firewall configuration - server will remain unprotected"
            return
        fi
    else
        print_success "UFW firewall is active"
        UFW_WILL_ENABLE=false
    fi
    
    echo ""
    print_info "Configuring essential ports..."
    echo ""
    
    # =========================================================================
    # SSH Configuration
    # =========================================================================
    print_info "SSH Port Configuration"
    
    # Try to detect current SSH port
    CURRENT_SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    if [ -z "$CURRENT_SSH_PORT" ]; then
        CURRENT_SSH_PORT="22"
    fi
    
    echo "  Current SSH port: $CURRENT_SSH_PORT"
    
    if [ "$CURRENT_SSH_PORT" = "22" ]; then
        print_warning "SSH is using default port 22 (commonly targeted by attackers)"
        read -p "  Would you like to change SSH port? (y/n) [n]: " CHANGE_SSH
        CHANGE_SSH=${CHANGE_SSH:-n}
        
        if [ "$CHANGE_SSH" = "y" ] || [ "$CHANGE_SSH" = "Y" ]; then
            read -p "  Enter new SSH port [2222]: " NEW_SSH_PORT
            NEW_SSH_PORT=${NEW_SSH_PORT:-2222}
            
            # Validate port number
            if [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_SSH_PORT" -ge 1024 ] && [ "$NEW_SSH_PORT" -le 65535 ]; then
                print_info "Changing SSH port to $NEW_SSH_PORT..."
                
                # Backup sshd_config
                cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
                
                # Update SSH port
                if grep -q "^Port " /etc/ssh/sshd_config; then
                    sed -i "s/^Port .*/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
                else
                    echo "Port $NEW_SSH_PORT" >> /etc/ssh/sshd_config
                fi
                
                SSH_PORT="$NEW_SSH_PORT"
                print_success "SSH port changed to $NEW_SSH_PORT"
                print_warning "Remember to reconnect using: ssh -p $NEW_SSH_PORT user@server"
                RESTART_SSH=true
            else
                print_error "Invalid port number. Using current port $CURRENT_SSH_PORT"
                SSH_PORT="$CURRENT_SSH_PORT"
            fi
        else
            SSH_PORT="$CURRENT_SSH_PORT"
        fi
    else
        SSH_PORT="$CURRENT_SSH_PORT"
        print_success "SSH is already using non-default port: $SSH_PORT"
    fi
    
    # Allow SSH port
    ufw allow "$SSH_PORT/tcp" comment 'SSH' >/dev/null 2>&1
    print_success "Allowed SSH on port $SSH_PORT"
    
    echo ""
    
    # =========================================================================
    # VNC Configuration
    # =========================================================================
    print_info "VNC Port Configuration"
    read -p "  Do you use VNC for remote desktop? (y/n) [n]: " USE_VNC
    USE_VNC=${USE_VNC:-n}
    
    if [ "$USE_VNC" = "y" ] || [ "$USE_VNC" = "Y" ]; then
        read -p "  Enter VNC port [5900]: " VNC_PORT
        VNC_PORT=${VNC_PORT:-5900}
        
        if [ "$VNC_PORT" = "5900" ]; then
            print_warning "VNC using default port 5900"
            read -p "  Would you like to use a different port? (y/n) [n]: " CHANGE_VNC
            CHANGE_VNC=${CHANGE_VNC:-n}
            
            if [ "$CHANGE_VNC" = "y" ] || [ "$CHANGE_VNC" = "Y" ]; then
                read -p "  Enter new VNC port: " VNC_PORT
            fi
        fi
        
        ufw allow "$VNC_PORT/tcp" comment 'VNC' >/dev/null 2>&1
        print_success "Allowed VNC on port $VNC_PORT"
    fi
    
    echo ""
    
    # =========================================================================
    # RDP Configuration
    # =========================================================================
    print_info "RDP Port Configuration"
    read -p "  Do you use RDP (xrdp) for remote desktop? (y/n) [n]: " USE_RDP
    USE_RDP=${USE_RDP:-n}
    
    if [ "$USE_RDP" = "y" ] || [ "$USE_RDP" = "Y" ]; then
        read -p "  Enter RDP port [3389]: " RDP_PORT
        RDP_PORT=${RDP_PORT:-3389}
        
        if [ "$RDP_PORT" = "3389" ]; then
            print_warning "RDP using default port 3389"
            read -p "  Would you like to use a different port? (y/n) [n]: " CHANGE_RDP
            CHANGE_RDP=${CHANGE_RDP:-n}
            
            if [ "$CHANGE_RDP" = "y" ] || [ "$CHANGE_RDP" = "Y" ]; then
                read -p "  Enter new RDP port: " RDP_PORT
            fi
        fi
        
        ufw allow "$RDP_PORT/tcp" comment 'RDP' >/dev/null 2>&1
        print_success "Allowed RDP on port $RDP_PORT"
    fi
    
    echo ""
    
    # =========================================================================
    # Nginx and Rotom
    # =========================================================================
    print_info "Configuring Nginx and Rotom ports..."
    
    # Allow Nginx Full (HTTP + HTTPS)
    ufw allow 'Nginx Full' >/dev/null 2>&1
    print_success "Allowed Nginx Full (ports 80, 443)"
    
    # Allow Rotom device port
    ufw allow 7070/tcp comment 'Rotom Devices' >/dev/null 2>&1
    print_success "Allowed Rotom devices on port 7070"
    
    echo ""
    
    # =========================================================================
    # Common Ports
    # =========================================================================
    print_info "Additional commonly used ports"
    echo ""
    echo "  Would you like to open any of these common ports?"
    echo ""
    
    read -p "  Allow DNS (53)? (y/n) [n]: " ALLOW_DNS
    if [ "$ALLOW_DNS" = "y" ] || [ "$ALLOW_DNS" = "Y" ]; then
        ufw allow 53 comment 'DNS' >/dev/null 2>&1
        print_success "Allowed DNS (port 53)"
    fi
    
    read -p "  Allow FTP (21)? (y/n) [n]: " ALLOW_FTP
    if [ "$ALLOW_FTP" = "y" ] || [ "$ALLOW_FTP" = "Y" ]; then
        ufw allow 21/tcp comment 'FTP' >/dev/null 2>&1
        print_success "Allowed FTP (port 21)"
    fi
    
    read -p "  Allow SMTP (25, 587)? (y/n) [n]: " ALLOW_SMTP
    if [ "$ALLOW_SMTP" = "y" ] || [ "$ALLOW_SMTP" = "Y" ]; then
        ufw allow 25/tcp comment 'SMTP' >/dev/null 2>&1
        ufw allow 587/tcp comment 'SMTP Submission' >/dev/null 2>&1
        print_success "Allowed SMTP (ports 25, 587)"
    fi
    
    read -p "  Allow IMAP/POP3 (143, 993, 110, 995)? (y/n) [n]: " ALLOW_MAIL
    if [ "$ALLOW_MAIL" = "y" ] || [ "$ALLOW_MAIL" = "Y" ]; then
        ufw allow 143/tcp comment 'IMAP' >/dev/null 2>&1
        ufw allow 993/tcp comment 'IMAPS' >/dev/null 2>&1
        ufw allow 110/tcp comment 'POP3' >/dev/null 2>&1
        ufw allow 995/tcp comment 'POP3S' >/dev/null 2>&1
        print_success "Allowed IMAP/POP3 (ports 143, 993, 110, 995)"
    fi
    
    echo ""
    
    # =========================================================================
    # Enable UFW if needed
    # =========================================================================
    if [ "$UFW_WILL_ENABLE" = true ]; then
        print_info "Enabling UFW firewall..."
        echo "y" | ufw enable >/dev/null 2>&1
        print_success "UFW firewall enabled"
    fi
    
    # Restart SSH if port was changed
    if [ "$RESTART_SSH" = true ]; then
        print_info "Restarting SSH service..."
        systemctl restart sshd
        print_success "SSH service restarted on port $SSH_PORT"
    fi
    
    # Show UFW status
    echo ""
    print_info "Current UFW rules:"
    ufw status numbered
    
    FIREWALL_CONFIGURED=true
}

# Secure Docker Compose ports (bind to localhost only)
secure_docker_ports() {
    echo ""
    print_info "Docker Port Security"
    echo ""
    
    echo -e "  ${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${YELLOW}║  IMPORTANT: Docker bypasses UFW firewall rules!               ║${NC}"
    echo -e "  ${YELLOW}║  Exposed Docker ports are accessible even with UFW enabled.   ║${NC}"
    echo -e "  ${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    print_info "To properly secure your services, Docker ports should be bound to"
    print_info "localhost (127.0.0.1) only, forcing all traffic through nginx."
    echo ""
    print_info "This will change docker-compose.yaml ports from:"
    echo "    - 6001:8080    → 127.0.0.1:6001:8080"
    echo ""
    print_info "Benefits:"
    echo "  • Services only accessible via nginx (with SSL and auth)"
    echo "  • Closes UFW holes created by Docker"
    echo "  • Hides actual ports from external access"
    echo "  • Only port 7070 remains externally accessible for devices"
    echo ""
    
    read -p "Would you like to secure Docker ports now? (y/n) [y]: " SECURE_DOCKER
    SECURE_DOCKER=${SECURE_DOCKER:-y}
    
    if [ "$SECURE_DOCKER" = "y" ] || [ "$SECURE_DOCKER" = "Y" ]; then
        COMPOSE_FILE="docker-compose.yaml"
        
        if [ ! -f "$COMPOSE_FILE" ]; then
            # Try common locations
            if [ -f "../docker-compose.yaml" ]; then
                COMPOSE_FILE="../docker-compose.yaml"
            elif [ -f "../../docker-compose.yaml" ]; then
                COMPOSE_FILE="../../docker-compose.yaml"
            else
                print_error "docker-compose.yaml not found"
                print_info "Please run this from the Aegis directory or manually edit docker-compose.yaml"
                return
            fi
        fi
        
        print_info "Backing up docker-compose.yaml..."
        cp "$COMPOSE_FILE" "${COMPOSE_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        
        print_info "Securing Docker ports..."
        
        # Bind web service ports to localhost only (except 7070 for devices)
        # Match patterns like "- 6001:8080" or "- "6001:8080"" and convert to "127.0.0.1:port:port"
        
        # Port 6001 - ReactMap
        sed -i 's/- "\{0,1\}6001:8080"\{0,1\}/- "127.0.0.1:6001:8080"/' "$COMPOSE_FILE"
        
        # Port 6002 - Admin
        sed -i 's/- "\{0,1\}6002:7273"\{0,1\}/- "127.0.0.1:6002:7273"/' "$COMPOSE_FILE"
        
        # Port 6003 - Rotom Web
        sed -i 's/- "\{0,1\}6003:7072"\{0,1\}/- "127.0.0.1:6003:7072"/' "$COMPOSE_FILE"
        
        # Port 6004 - Koji
        sed -i 's/- "\{0,1\}6004:8080"\{0,1\}/- "127.0.0.1:6004:8080"/' "$COMPOSE_FILE"
        
        # Port 6005 - phpMyAdmin
        sed -i 's/- "\{0,1\}6005:80"\{0,1\}/- "127.0.0.1:6005:80"/' "$COMPOSE_FILE"
        
        # Port 6006 - Grafana
        sed -i 's/- "\{0,1\}6006:3000"\{0,1\}/- "127.0.0.1:6006:3000"/' "$COMPOSE_FILE"
        
        # Port 6007 - Poracle
        sed -i 's/- "\{0,1\}6007:3030"\{0,1\}/- "127.0.0.1:6007:3030"/' "$COMPOSE_FILE"
        
        # Keep port 7070 externally accessible for devices
        # (Don't modify 7070)
        
        print_success "Docker ports secured to localhost only"
        print_success "Port 7070 remains externally accessible for devices"
        echo ""
        print_warning "You need to restart Docker containers for changes to take effect:"
        echo "    cd $(dirname $COMPOSE_FILE) && docker compose down && docker compose up -d"
        
        DOCKER_PORTS_SECURED=true
    else
        print_info "Skipping Docker port security"
        DOCKER_PORTS_SECURED=false
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
    
    if [ "$FIREWALL_CONFIGURED" = true ]; then
        print_info "UFW Firewall:"
        echo "  Status:       sudo ufw status"
        echo "  Status (num): sudo ufw status numbered"
        echo "  Allow port:   sudo ufw allow <port>/tcp"
        echo "  Delete rule:  sudo ufw delete <rule_number>"
        echo ""
    fi
    
    if [ "$DOCKER_PORTS_SECURED" = true ]; then
        print_info "Docker Port Security:"
        echo "  All service ports now bound to 127.0.0.1 (localhost only)"
        echo "  Traffic must go through Nginx (with SSL/auth)"
        echo "  Only port 7070 accessible externally for device connections"
        echo ""
        print_warning "Restart Docker containers for port changes to take effect:"
        echo "  cd $(pwd) && docker compose down && docker compose up -d"
        echo ""
    fi
    
    print_warning "SECURITY REMINDER:"
    echo "  - Change default passwords for Grafana (admin/admin)"
    echo "  - Keep your basic auth password secure"
    if [ "$FIREWALL_CONFIGURED" != true ]; then
        echo "  - Consider using a firewall (ufw) to restrict access"
    fi
    echo "  - Only expose necessary ports to the internet"
    if [ "$FAIL2BAN_INSTALLED" = true ]; then
        echo "  - Monitor Fail2Ban logs: /var/log/fail2ban.log"
    fi
    echo ""
}

# Setup mode execution (original main function renamed)
run_setup_mode() {
    clear
    echo "=============================================="
    echo "  Aegis Nginx Reverse Proxy Setup"
    echo "  By The Pokemod Group"
    echo "  https://pokemod.dev/"
    echo "=============================================="
    echo ""
    
    # Step 1: Check root
    print_info "Step 1/11: Checking permissions..."
    check_root
    
    # Step 2: Detect/install webserver
    print_info "Step 2/11: Detecting web server..."
    detect_webserver
    
    # Pre-flight check: Fix any broken nginx configuration
    if command -v nginx &> /dev/null; then
        # Check for "module already loaded" error (duplicate load_module)
        if nginx -t 2>&1 | grep -q "already loaded"; then
            echo ""
            echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${YELLOW}║     DUPLICATE MODULE LOAD DETECTED - AUTO-FIXING               ║${NC}"
            echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            print_warning "Module is being loaded twice (modules-enabled + nginx.conf)"
            print_info "Removing duplicate load_module directive from nginx.conf..."
            
            # Backup
            cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d_%H%M%S)
            
            # Remove duplicate load_module lines from nginx.conf
            sed -i '/^load_module.*ngx_stream_module/d' /etc/nginx/nginx.conf
            
            if nginx -t 2>&1 | grep -q "test is successful"; then
                print_success "Fixed duplicate module load error"
                systemctl reload nginx 2>/dev/null || true
            else
                print_warning "Other issues remain, continuing..."
            fi
            echo ""
        fi
        
        if nginx -t 2>&1 | grep -q "unknown directive.*stream"; then
            echo ""
            echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${YELLOW}║     BROKEN NGINX CONFIGURATION DETECTED - AUTO-FIXING         ║${NC}"
            echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            print_warning "Found incorrectly placed 'stream' block in nginx.conf"
            print_info "This was likely caused by a previous setup attempt."
            print_info "Automatically removing the broken stream configuration..."
            echo ""
            
            # Backup first
            cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup.$(date +%Y%m%d_%H%M%S)
            print_success "Backup created"
            
            # Use awk to remove the stream block (handles multi-line with nested braces)
            awk '
                /stream[[:space:]]*\{/ { in_stream=1; brace_count=1; next }
                in_stream && /\{/ { brace_count++ }
                in_stream && /\}/ { brace_count--; if(brace_count==0) { in_stream=0; next } }
                !in_stream { print }
            ' /etc/nginx/nginx.conf > /etc/nginx/nginx.conf.tmp
            mv /etc/nginx/nginx.conf.tmp /etc/nginx/nginx.conf
            
            # Also remove any leftover stream-related lines
            sed -i '/include.*stream/d' /etc/nginx/nginx.conf
            sed -i '/# Stream configuration/d' /etc/nginx/nginx.conf
            sed -i '/# Include stream configuration/d' /etc/nginx/nginx.conf
            sed -i '/include.*nginx-stream/d' /etc/nginx/nginx.conf
            
            # Clean up stream config files
            rm -f /etc/nginx/nginx-stream.conf
            rm -f /etc/nginx/stream.d/rotom-devices.conf 2>/dev/null
            
            # Test if fix worked
            if nginx -t 2>&1 | grep -q "test is successful"; then
                print_success "Nginx configuration fixed successfully!"
            else
                print_warning "Config may still have other issues, but stream error is resolved."
            fi
            echo ""
        fi
    fi
    
    # Step 3: Get configuration from user
    print_info "Step 3/11: Gathering configuration..."
    get_user_config
    
    # Step 4: Authelia setup (optional)
    print_info "Step 4/11: Authentication setup..."
    setup_authelia
    if [ "$AUTHELIA_ENABLED" != true ]; then
        setup_basic_auth
    fi
    
    # Step 5: Create nginx configs
    print_info "Step 5/11: Creating Nginx configurations..."
    create_nginx_configs
    create_symlinks
    
    # Step 6: Test and apply nginx config
    print_info "Step 6/11: Testing and applying Nginx configuration..."
    test_and_reload_nginx
    
    # Step 7: Rotom device port (optional)
    print_info "Step 7/11: Rotom device port configuration..."
    setup_rotom_device_port
    
    # Only test again if rotom setup made changes
    if [ "$SETUP_ROTOM_STREAM" = "y" ] || [ "$SETUP_ROTOM_STREAM" = "Y" ]; then
        print_info "Re-testing Nginx after stream configuration..."
        test_and_reload_nginx
    fi
    
    # Step 8: SSL setup (optional)
    print_info "Step 8/11: SSL certificate setup..."
    setup_ssl
    
    # Step 9: Fail2Ban setup (optional)
    print_info "Step 9/11: Fail2Ban security setup..."
    setup_fail2ban
    
    # Step 10: Firewall setup (UFW)
    print_info "Step 10/11: Firewall configuration..."
    setup_firewall
    
    # Step 11: Secure Docker ports
    print_info "Step 11/11: Docker port security..."
    secure_docker_ports
    
    # Done - print summary
    print_summary
    
    # Return to main menu or exit
    if [ "$AEGIS_LAUNCHER" = "1" ]; then
        echo ""
        read -p "Press Enter to return to main menu..."
        return_to_main
    fi
}

# Main execution
main() {
    # Check for command line arguments
    case "${1:-}" in
        --setup|-s)
            check_root
            run_setup_mode
            return
            ;;
        --maintenance|-m)
            check_root
            maintenance_mode
            return
            ;;
        --status)
            check_root
            show_status_dashboard
            press_enter
            return
            ;;
        --help|-h)
            echo ""
            echo "Aegis Nginx Security & Management Script"
            echo ""
            echo "Usage: $0 [option]"
            echo ""
            echo "Options:"
            echo "  (none)           Interactive mode selection"
            echo "  -s, --setup      Run setup mode directly"
            echo "  -m, --maintenance  Run maintenance mode directly"
            echo "  --status         Show status dashboard only"
            echo "  -h, --help       Show this help"
            echo ""
            exit 0
            ;;
    esac
    
    # Check root first
    check_root
    
    # Show mode selection
    show_mode_selection
    
    # Run selected mode
    case "$SCRIPT_MODE" in
        setup)
            run_setup_mode
            ;;
        maintenance)
            maintenance_mode
            ;;
    esac
}

# Run main function
main "$@"

