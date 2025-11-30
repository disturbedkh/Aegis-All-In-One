# Aegis AIO 2.0

> A complete, beginner-friendly Docker stack for Pokémon mapping using Aegis and the Unown# ecosystem.

---

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Services](#services)
- [Optional Features](#optional-features)
- [Security Setup](#security-setup)
- [Configuration](#configuration)
- [Device Setup](#device-setup)
- [Troubleshooting](#troubleshooting)
- [Screenshots](#screenshots)
- [Support](#support)

---

## Overview

This repository provides a complete, pre-configured Docker stack that brings together all the services needed for Pokémon mapping. It's designed as a **learning tool** to help newcomers understand how the different components interact.

### What's Included

| Component | Purpose |
|-----------|---------|
| **Aegis** | Mobile device client for scanning |
| **Dragonite** | Scanner backend & task distribution |
| **Golbat** | Data processor & Pokemon tracker |
| **Rotom** | Device manager & communication hub |
| **ReactMap** | Beautiful web-based map frontend |
| **Koji** | Geofence & area management |
| **Xilriws** | Pokemon GO API proxy & request handler |
| **Fletchling** | Pokemon nest detection & tracking |
| **Poracle** | Discord & Telegram alert notifications |
| **Grafana** | Performance monitoring & statistics |
| **MariaDB** | Database for all services |

### Alternative Stack

Looking for Atlas/RDM instead? Check out [Atlas-All-In-One](https://github.com/The-Pokemod-Group/Atlas-All-In-One).

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Your Server                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐  │
│  │  Aegis   │───▶│  Rotom   │───▶│ Dragonite│───▶│  Golbat  │  │
│  │ (Device) │    │ (Manager)│    │ (Scanner)│    │(Processor│  │
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘  │
│       │                │               │               │        │
│       │                │               │               │        │
│       │                ▼               ▼               ▼        │
│       │          ┌─────────────────────────────────────┐       │
│       │          │            MariaDB                   │       │
│       │          │  (golbat_db, dragonite_db, koji_db) │       │
│       │          └─────────────────────────────────────┘       │
│       │                              │                          │
│       │                              ▼                          │
│       │          ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│       └─────────▶│ ReactMap │  │   Koji   │  │ Grafana  │      │
│      Port 7070   │  (Map)   │  │ (Areas)  │  │ (Stats)  │      │
│                  └──────────┘  └──────────┘  └──────────┘      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

### System Requirements

- **Operating System**: Linux (Ubuntu 22.04+ or Debian 12+ recommended)
- **RAM**: 16GB or greater
- **Storage**: 50GB+ free space (SSD strongly recommended for database performance)
- **CPU**: 8+ cores recommended

> ⚠️ **Note**: While Docker runs on Windows/macOS, this AIO is designed and tested for Linux only.

### Required Software

1. **Docker Engine** (version 20.10+)
2. **Docker Compose Plugin** (v2)

> 💡 **Tip**: The setup script (`setup.sh`) can automatically install Docker and Docker Compose for you if they're not already installed.

### Install Docker Manually (Optional)

If you prefer to install Docker before running the setup script:

```bash
# Ubuntu/Debian
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Log out and back in for group changes to take effect
```

### Configure Docker Logging (Recommended)

Docker can generate massive log files. The setup script (`setup.sh`) will automatically prompt you to configure log rotation to prevent disk space issues.

**Default configuration** (applied by setup script):

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3",
    "compress": "true"
  }
}
```

This limits logs to 300MB total (3 files × 100MB each) with automatic rotation and compression.

> 💡 **Tip**: The setup script lets you customize these values and will automatically restart Docker to apply the changes.

---

## Quick Start

For experienced users, here's the fastest path to a running system:

```bash
# Clone and enter directory
git clone https://github.com/The-Pokemod-Group/Aegis-All-In-One.git
cd Aegis-All-In-One

# Run setup (creates configs, databases, passwords)
sudo bash ./setup.sh

# Start all services
docker compose up -d

# (Optional) Secure for external access
sudo bash ./nginx-setup.sh
```

Then visit http://localhost:6001 for ReactMap.

---

## Installation

### Step 1: Clone the Repository

```bash
git clone https://github.com/The-Pokemod-Group/Aegis-All-In-One.git
cd Aegis-All-In-One
```

### Step 2: Run the Setup Script

```bash
sudo bash ./setup.sh
```

The setup script will:

- ✅ Check and install Docker if needed
- ✅ Configure Docker log rotation to prevent disk space issues
- ✅ Generate secure random passwords for all services
- ✅ Create configuration files from templates
- ✅ Set up MariaDB with optimized settings for your hardware
- ✅ Create all required databases
- ✅ Configure inter-service communication

You'll be prompted to customize:
- Database usernames and passwords
- API secrets and bearer tokens
- Service-specific settings

### Step 3: Start the Stack

```bash
docker compose up -d --force-recreate --build
```

> 💡 **Tip**: Add `sudo` if your user isn't in the docker group.

First startup may take a few minutes as Docker downloads images and builds containers.

### Step 4: Verify Services

Check that all containers are running:

```bash
docker compose ps
```

All services should show `Up` status. Check individual logs if needed:

```bash
docker logs <container_name>
```

> 📝 **Note**: Some initial errors are normal (e.g., Koji needs projects before Dragonite can sync). These resolve once you complete the initial configuration.

### Step 5: Access the Web Interfaces

Open your browser and visit these URLs (replace `localhost` with your server IP if remote):

| Service | URL | Default Credentials |
|---------|-----|---------------------|
| ReactMap | http://localhost:6001 | None required |
| Dragonite Admin | http://localhost:6002 | Set in setup |
| Rotom | http://localhost:6003 | None required |
| Koji | http://localhost:6004 | None required |
| phpMyAdmin | http://localhost:6005 | DB credentials from setup |
| Grafana | http://localhost:6006 | admin / admin (change immediately!) |

---

## Services

### ReactMap (Port 6001)

The user-facing map interface that displays:
- Pokemon spawns and IVs
- Raids and gyms
- Pokestops and quests
- Nests (with Fletchling)

### Dragonite Admin (Port 6002)

Scanner management dashboard for:
- Adding and managing accounts
- Viewing worker status
- Configuring scan settings
- Monitoring scan progress

### Rotom (Port 6003 + 7070)

Device manager that:
- Receives connections from Aegis devices (port 7070)
- Assigns tasks to devices
- Monitors device health
- Manages device configurations

### Koji (Port 6004)

Geofence management tool for:
- Drawing scan areas on a map
- Creating projects (area groups)
- Exporting geofences to Dragonite/ReactMap
- Managing Pokemon spawn points

### phpMyAdmin (Port 6005)

Database management interface for:
- Viewing and editing database tables
- Running SQL queries
- Managing users and permissions
- Database maintenance

### Grafana (Port 6006)

Performance monitoring with:
- Real-time statistics dashboards
- Pokemon catch rates
- Device performance metrics
- Historical data analysis

---

## Optional Features

### Poracle - Discord/Telegram Alerts

Send Pokemon spawn, raid, and quest notifications to Discord or Telegram.

```bash
sudo bash ./poracle.sh
```

The script guides you through:
- Creating a Discord or Telegram bot
- Configuring notification filters
- Setting up webhooks from Golbat

📚 [Poracle Documentation](https://github.com/KartulUdus/PoracleJS)

### Fletchling - Pokemon Nests

Display Pokemon nests on ReactMap.

**Prerequisites**: Create a project with geofences in Koji first.

```bash
sudo bash ./fletchling.sh
```

The script will:
- Configure Fletchling with your Koji project
- Import park data from OpenStreetMap
- Enable automatic nest detection

📚 [Fletchling Documentation](https://github.com/UnownHash/Fletchling)

### Grafana Dashboards

Import the included dashboard for comprehensive monitoring:

1. Login to Grafana (http://localhost:6006) with admin/admin
2. **Change the default password immediately!**
3. Go to **Settings → Data Sources → Add data source**
4. Select **Prometheus** and set URL to `http://victoriametrics:8428`
5. Go to **Dashboards → Import**
6. Upload `grafana/Dragonite-Emi-v5.json`

---

## Security Setup

### Why Secure Your Setup?

If you plan to:
- Access your setup from outside your local network
- Expose services to the internet
- Allow others to view your map

**You MUST secure your setup!** Unsecured services can be exploited.

### Run the Security Script

```bash
sudo bash ./nginx-setup.sh
```

### Security Features

#### 🔒 Nginx Reverse Proxy
- **Subdomain routing**: `map.yourdomain.com`, `admin.yourdomain.com`
- **Path-based routing**: `yourdomain.com/map`, `yourdomain.com/admin`
- Proper proxy headers and WebSocket support
- Optimized timeouts for long-running connections

#### 🔐 SSL/TLS Encryption
- Free certificates from Let's Encrypt
- Automatic certificate renewal
- Forces HTTPS for all connections
- Modern TLS configuration

#### 🛡️ Authentication Options

**Basic Authentication**
- Simple username/password protection
- Configurable per-service
- Quick to set up

**Authelia SSO** (Advanced)
- Single Sign-On across all services
- Two-Factor Authentication (TOTP)
- Session management
- User access control

#### 🚫 Fail2Ban Protection
- Blocks brute-force attacks
- Bans malicious IPs automatically
- Protects SSH, Nginx, and services
- Configurable ban times and thresholds

#### 🔥 UFW Firewall
- Automatic firewall configuration
- SSH port hardening (prompts to change from default 22)
- VNC/RDP support for remote desktop users
- Opens only necessary ports

#### 🐳 Docker Port Security
- Binds service ports to localhost only
- Prevents Docker from bypassing firewall rules
- Forces all traffic through Nginx (with SSL + auth)
- Only port 7070 remains external for device connections

### Setup Steps

The security script guides you through 11 steps:

1. **Permission Check** - Ensures root access
2. **Web Server Detection** - Installs/configures Nginx
3. **Domain Configuration** - Set your domain/subdomains
4. **Authentication Setup** - Basic Auth or Authelia
5. **Nginx Configuration** - Creates site configs
6. **Configuration Testing** - Validates Nginx syntax
7. **Rotom Device Setup** - WebSocket proxy for devices
8. **SSL Certificates** - Let's Encrypt setup
9. **Fail2Ban** - Intrusion prevention
10. **UFW Firewall** - Port management
11. **Docker Security** - Localhost port binding

---

## Configuration

### Validate Your Setup

Run the configuration checker to ensure everything is properly configured:

```bash
sudo bash ./check.sh
```

This validates:
- ✅ Environment variables match across all configs
- ✅ Database passwords are consistent
- ✅ API secrets are properly configured
- ✅ Docker containers are running
- ✅ Required files exist

### Database Tuning

The setup script automatically tunes MariaDB based on your hardware:
- Detects available RAM and allocates buffer pool
- Configures I/O settings based on storage type (SSD/HDD)
- Sets appropriate connection limits

To re-run database tuning:

```bash
sudo bash ./dbsetup.sh
```

### Configuration Files

| File | Purpose |
|------|---------|
| `.env` | Main environment variables |
| `reactmap/local.json` | ReactMap configuration |
| `unown/dragonite_config.toml` | Dragonite settings |
| `unown/golbat_config.toml` | Golbat settings |
| `unown/rotom_config.json` | Rotom settings |
| `fletchling.toml` | Fletchling nest detection settings |
| `Poracle/config/local.json` | Poracle alert bot configuration |
| `Poracle/geofence/` | Poracle geofence definitions |
| `docker-compose.yaml` | Docker service definitions |

---

## Device Setup

### Aegis App Configuration

1. **Install Aegis** on your Android device
2. **Open the app** and enter connection details:
   - **Rotom URL**: `your-server-ip:7070`
   - **Auth Bearer**: The token from your setup
   - **Device Name**: A unique identifier

### Manual Configuration (Advanced)

Configuration file location on device:
```
/data/local/tmp/aegis_config.json
```

Example configuration:

```json
{
    "authBearer": "your_rotom_auth_bearer",
    "deviceAuthToken": "your_unique_device_token",
    "deviceName": "device-01",
    "email": "your_aegis_portal_email",
    "rotomUrl": "your-server-ip:7070",
    "runOnBoot": true
}
```

Log file location:
```
/data/local/tmp/aegis.log
```

### Device Connection Flow

1. Device connects to Rotom on port 7070
2. Rotom authenticates using the bearer token
3. Device appears in Rotom dashboard
4. Dragonite assigns scan tasks
5. Device executes tasks and reports data
6. Golbat processes and stores data
7. ReactMap displays results

---

## Troubleshooting

### Common Issues

#### Port Already in Use

```
Error: port is already allocated
```

**Solution**: Change the port in `docker-compose.yaml` or stop the conflicting service.

#### Container Won't Start

```bash
# Check logs for specific error
docker logs <container_name>

# Restart the container
docker compose restart <service_name>

# Rebuild if needed
docker compose up -d --force-recreate --build <service_name>
```

#### Database Connection Failed

1. Verify MariaDB is running: `docker compose ps mariadb`
2. Check credentials in `.env` match service configs
3. Ensure databases exist: `docker exec -it mariadb mysql -u root -p`

#### Device Not Connecting

1. Verify port 7070 is open: `sudo ufw status`
2. Check Rotom logs: `docker logs rotom`
3. Verify bearer token matches in device and `rotom_config.json`
4. Test connectivity: `telnet your-server-ip 7070`

#### Nginx 502 Bad Gateway

1. Check if backend service is running
2. Verify port numbers in Nginx config match docker-compose
3. Check Nginx error log: `sudo tail -f /var/log/nginx/error.log`

#### SSL Certificate Issues

```bash
# Test certificate renewal
sudo certbot renew --dry-run

# Force renewal
sudo certbot renew --force-renewal

# Check certificate status
sudo certbot certificates
```

### Useful Commands

```bash
# View all container status
docker compose ps

# Follow logs for all services
docker compose logs -f

# Restart everything
docker compose restart

# Full rebuild
docker compose down && docker compose up -d --force-recreate --build

# Check disk usage
docker system df

# Clean up unused resources
docker system prune -a
```

---

## Screenshots

### Koji - Area Management

Define your scan areas with the intuitive geofence editor:

![Koji Sample Projects](https://i.ibb.co/YhdSWCq/koji-projects.png)

### ReactMap - Pokemon Map

View Pokemon, raids, quests, and more on the beautiful map interface:

![Reactmap Sample Area](https://i.ibb.co/b7BS6Ww/reactmap.png)

### Dragonite - Scanner Control

Manage accounts, workers, and scan settings:

![Dragonite Sample](https://i.ibb.co/7SDmxrm/dragonite.png)

### Rotom - Device Manager

Monitor connected devices and their status:

![Rotom Sample](https://i.ibb.co/6FPB2ry/rotom.png)

### Grafana - Statistics

Track performance with detailed dashboards:

![Grafana Sample](https://i.ibb.co/qr1v3CP/grafana.png)

---

## Getting Started Checklist

After installation, complete these steps to start mapping:

- [ ] **Add accounts to Dragonite** 
  - Rule of thumb: 100 accounts per worker × (`minimum_account_reuse_hours` / 24)
  - Enable `recycle_on_jail=true` to maximize account usage

- [ ] **Create a project in Koji**
  - Draw geofences for your scan area
  - Name your project meaningfully

- [ ] **Sync Koji with Dragonite**
  - In Dragonite, import areas from Koji
  - Configure scan modes (Pokemon, Raids, Quests)

- [ ] **Sync Koji with ReactMap**
  - Import geofences for map display
  - Configure tile providers

- [ ] **Connect your first device**
  - Install Aegis on device
  - Configure Rotom URL and bearer token
  - Verify connection in Rotom dashboard

- [ ] **Start mapping!**
  - Assign device to area in Dragonite
  - Watch Pokemon appear on ReactMap

---

## Support

### Community Discord Servers

| Server | Focus |
|--------|-------|
| [Unown# Discord](https://discord.gg/Vjze47qchG) | Dragonite, Golbat, Rotom |
| [ReactMap/Koji Discord](https://discord.gg/EYYsKPVawn) | ReactMap, Koji |
| [Pokemod Discord](https://discord.gg/pokemod) | Aegis, General Questions |

### Before Asking for Help

1. Check container logs: `docker logs <container>`
2. Run the config checker: `sudo bash ./check.sh`
3. Search Discord for similar issues
4. Provide logs and error messages when asking

---

## License

This project is provided as-is for educational purposes.

---

<p align="center">
  <strong>Aegis All-in-One</strong><br>
  by <a href="https://pokemod.dev/">The Pokemod Group</a>
</p>
