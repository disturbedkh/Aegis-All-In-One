# Security Setup

Configure external access with Nginx, SSL, and authentication.

---

## Why Secure Your Setup?

If you plan to:
- Access from outside your local network
- Expose services to the internet
- Allow others to view your map

**You MUST secure your setup!** Unsecured services can be exploited.

---

## Running the Security Script

```bash
sudo bash ./Shellder/nginx-setup.sh
```

The script has two modes:
- **Setup Mode** - First-time configuration
- **Maintenance Mode** - Ongoing management

---

## Setup Mode (11 Steps)

1. **Permission Check** - Ensures root access
2. **Web Server Detection** - Installs/configures Nginx
3. **Domain Configuration** - Set your domain/subdomains
4. **Authentication Setup** - Basic Auth or Authelia
5. **Nginx Configuration** - Creates site configs
6. **Configuration Testing** - Validates syntax
7. **Rotom Device Setup** - WebSocket proxy
8. **SSL Certificates** - Let's Encrypt
9. **Fail2Ban** - Intrusion prevention
10. **UFW Firewall** - Port management
11. **Docker Security** - Localhost binding

---

## Security Features

### 🔒 Nginx Reverse Proxy

| Mode | Example |
|------|---------|
| Subdomain | `map.yourdomain.com`, `admin.yourdomain.com` |
| Path-based | `yourdomain.com/map`, `yourdomain.com/admin` |

### 🔐 SSL/TLS Encryption

- Free certificates from Let's Encrypt
- Automatic renewal
- Forces HTTPS
- Modern TLS configuration

### 🛡️ Authentication Options

**Basic Authentication**
- Simple username/password
- Per-service configuration
- Quick setup

**Authelia SSO** (Advanced)
- Single Sign-On
- Two-Factor Authentication
- Session management
- User access control

### 🚫 Fail2Ban Protection

- Blocks brute-force attacks
- Auto-bans malicious IPs
- Protects SSH, Nginx, services
- Configurable thresholds

### 🔥 UFW Firewall

- Automatic configuration
- SSH port hardening
- Opens only necessary ports

### 🐳 Docker Port Security

- Binds services to localhost
- Forces traffic through Nginx
- Only port 7070 external (devices)

---

## Maintenance Mode

Access with:
```bash
sudo bash ./Shellder/nginx-setup.sh -m
```

### Status Dashboard Shows:
- Service status (Nginx, Fail2Ban, UFW)
- Enabled/available sites
- SSL certificate status
- Active Fail2Ban jails
- Port listening status

### Management Options:

| Category | Options |
|----------|---------|
| **Services** | Start, stop, restart, reload |
| **Sites** | Enable/disable, view/edit configs |
| **SSL** | Request, renew, revoke certificates |
| **Fail2Ban** | View jails, ban/unban IPs |
| **UFW** | Allow/deny ports, manage rules |

---

## Command Line Options

```bash
./Shellder/nginx-setup.sh              # Interactive mode
./Shellder/nginx-setup.sh -s           # Setup mode
./Shellder/nginx-setup.sh -m           # Maintenance mode
./Shellder/nginx-setup.sh --status     # Status dashboard only
```

---

## Shellder GUI External Access

To expose the Shellder web dashboard:

```bash
sudo bash ./Shellder/nginx-setup.sh -m
# Navigate to: Site Management → Setup Shellder GUI
```

Configure:
- Subdomain (e.g., `shellder.yourdomain.com`)
- Password protection
- SSL certificate

---

[[← Services|Services]] | [[Next: Configuration →|Configuration]]

