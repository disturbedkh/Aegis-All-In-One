# Aegis AIO 2.0

> A complete, beginner-friendly Docker stack for Pokémon mapping using Aegis and the Unown# ecosystem.

---

## 📋 Table of Contents

- [Overview](#overview)
- [Shellder](#shellder)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Services](#services)
- [Optional Features](#optional-features)
- [Xilriws Operation](#xilriws-operation)
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

## Shellder

**Shellder** is the shell management system for Aegis AIO — named after the Pokémon! 🐚

### What is Shellder?

Shellder serves as the **unified command center** for your entire Pokémon mapping infrastructure. It's a collection of interactive shell scripts that provide a friendly, menu-driven interface to manage the Aegis AIO ecosystem and its Unown# stack without needing to memorize Docker commands or edit configuration files manually.

### Shellder's Role

```
┌─────────────────────────────────────────────────────────────────────┐
│                           SHELLDER                                   │
│                    Shell Management System                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐             │
│   │  shellder.sh │  │   setup.sh   │  │   check.sh   │             │
│   │  Main Panel  │  │ First Setup  │  │ Health Check │             │
│   └──────────────┘  └──────────────┘  └──────────────┘             │
│                                                                      │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐             │
│   │  dbsetup.sh  │  │nginx-setup.sh│  │   logs.sh    │             │
│   │  Database    │  │  Security    │  │ Log Manager  │             │
│   └──────────────┘  └──────────────┘  └──────────────┘             │
│                                                                      │
│   ┌──────────────┐  ┌──────────────┐                                │
│   │  poracle.sh  │  │fletchling.sh │  + More...                     │
│   │   Alerts     │  │    Nests     │                                │
│   └──────────────┘  └──────────────┘                                │
│                                                                      │
├─────────────────────────────────────────────────────────────────────┤
│                         MANAGES ▼                                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│                      AEGIS AIO ECOSYSTEM                             │
│                                                                      │
│                        ┌─────────────────────────────────┐          │
│                        │         UNOWN# STACK            │          │
│                        │  Dragonite, Golbat, Rotom,      │          │
│                        │  ReactMap, Koji, Xilriws, etc.  │          │
│                        └─────────────────────────────────┘          │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Functions

| Function | Description |
|----------|-------------|
| **Stack Control** | Start, stop, restart, and rebuild all Docker containers with single commands |
| **Initial Setup** | Guided wizard for first-time configuration, password generation, and database creation |
| **Security Management** | Nginx reverse proxy, SSL certificates, firewall rules, and authentication setup |
| **Database Administration** | MariaDB tuning, user management, cleanup, and maintenance operations |
| **Health Monitoring** | Real-time status dashboard, configuration validation, and troubleshooting tools |
| **Log Analysis** | View, search, and manage Docker logs across all services |
| **Statistics Database** | Persistent SQLite database for all-time stats (survives log clearing) |
| **Update Management** | Git pulls, Docker image updates, and stack rebuilds with config preservation |
| **Optional Features** | Easy setup for Poracle (alerts) and Fletchling (nest detection) |

### Shellder Statistics Database

Shellder includes a built-in SQLite database (`Shellder/shellder.db`) that stores persistent statistics across all scripts. This means you can:

- **View all-time proxy statistics** even after Xilriws logs are cleared
- **Track historical error counts** by service and error type
- **Monitor container health trends** over time
- **See log summaries** for the past 30 days

**Access via:**
- `logs.sh` → "All-Time Statistics" menu option
- `dbsetup.sh` → "Shellder Statistics Database" in maintenance mode

**Recorded Statistics:**
| Category | Data Tracked |
|----------|--------------|
| **Proxy Stats** | Total requests, success/fail counts, response times, per-proxy performance |
| **Error Stats** | Error type, occurrence count, first/last seen, by service |
| **Container Stats** | Start/restart/crash counts, total uptime, status history |
| **Log Summaries** | Daily line counts, error/warning counts per service |
| **System Events** | Important events logged with timestamps |

### Shellder Scripts

| Script | Purpose | When to Run |
|--------|---------|-------------|
| `shellder.sh` | **Main control panel** - unified interface to everything | Anytime |
| `Shellder/setup.sh` | Initial setup wizard - Docker, configs, passwords, databases | First time setup |
| `Shellder/dbsetup.sh` | Database setup and maintenance | Initial setup or maintenance |
| `Shellder/check.sh` | Status dashboard & configuration validation | Troubleshooting, health checks |
| `Shellder/logs.sh` | Docker log viewer, analyzer, and maintenance | Monitoring, debugging |
| `Shellder/nginx-setup.sh` | Nginx, SSL, firewall, and authentication | External access setup |
| `Shellder/poracle.sh` | Discord/Telegram notification bot setup | When you want alerts |
| `Shellder/fletchling.sh` | Pokémon nest detection setup | After creating Koji project |

### Quick Start with Shellder

```bash
# Launch the Shellder control panel
sudo bash ./shellder.sh

# Or use command-line shortcuts
./shellder.sh --start      # Start all containers
./shellder.sh --stop       # Stop all containers
./shellder.sh --status     # View status dashboard
./shellder.sh --help       # See all options
```

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

> 💡 **Tip**: The setup script (`setup.sh`) can automatically install Docker, Docker Compose, and add your user to the docker group - no manual steps required!

### Database Compatibility

This stack uses **MariaDB 12.x** (latest). The configuration has been optimized for MariaDB 12+ with deprecated options removed to ensure clean startup without warnings.

### Install Docker Manually (Optional)

If you prefer to install Docker before running the setup script:

```bash
# Ubuntu/Debian
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Log out and back in for group changes to take effect
```

> 💡 **Note**: The setup script automatically adds your user to the docker group if not already a member, and reminds you to log out/in to activate it.

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

### `Shellder/setup.sh` - Initial Setup

The main setup script that prepares your entire environment.

```bash
sudo bash ./Shellder/setup.sh
```

**What it does:**
- ✅ Installs Docker and Docker Compose if missing
- ✅ **Automatically adds user to docker group** (no more sudo for docker commands)
- ✅ Configures Docker log rotation (prevents disk space issues)
- ✅ **Checks port availability** for all stack services with remediation options
- ✅ Detects system resources (RAM, CPU, storage type)
- ✅ Generates secure random passwords for all services
- ✅ Creates configuration files from templates
- ✅ Tunes MariaDB settings for your hardware
- ✅ Creates required databases and users
- ✅ Sets up inter-service communication
- ✅ **Restores file ownership** (prevents root-locked files)

---

### `Shellder/nginx-setup.sh` - Security Setup & Management

**Dual-mode script** for initial security setup AND ongoing maintenance.

```bash
sudo bash ./Shellder/nginx-setup.sh
```

**Two Modes:**

#### Setup Mode
First-time configuration of Nginx reverse proxy, SSL, and security:

- 🔒 Configures Nginx reverse proxy (subdomain or path-based routing)
- 🔐 Sets up SSL/TLS with Let's Encrypt (free certificates)
- 🛡️ Configures authentication (Basic Auth or Authelia SSO)
- 🚫 Installs Fail2Ban (blocks brute-force attacks)
- 🔥 Configures UFW firewall (only opens necessary ports)
- 🐳 Secures Docker ports (binds to localhost, forces traffic through Nginx)
- 📱 Sets up Rotom device WebSocket proxy

**11-Step Setup Process:**
1. Permission verification
2. Web server detection/installation
3. Domain configuration
4. Authentication setup
5. Nginx site configuration
6. Configuration testing
7. Rotom device port setup
8. SSL certificate generation
9. Fail2Ban installation
10. UFW firewall configuration
11. Docker port security

#### Maintenance Mode
Manage existing security configuration with colorful status dashboard:

**Status Dashboard Shows:**
- Nginx, Fail2Ban, UFW service status
- Enabled/available sites count
- SSL certificate status and expiry
- Active Fail2Ban jails and banned IPs
- Port listening status (80/443)
- Configuration health check

**Maintenance Menu Options:**

| Category | Options |
|----------|---------|
| **Service Management** | Start, stop, restart, reload Nginx and Fail2Ban |
| **Site Management** | Enable/disable sites, view/edit configs, add new sites |
| **SSL Certificates** | Request, renew, revoke, delete certificates |
| **Fail2Ban** | View jails, ban/unban IPs, view logs |
| **UFW Firewall** | Enable/disable, allow/deny ports, manage rules, **log management** |

**Add New Sites:**
- Aegis service proxy template (ReactMap, Dragonite, etc.)
- Custom reverse proxy
- Static file site
- Auto-enable and optional SSL setup

**Firewall Log Management (Press 'l' in UFW menu):**
- Log dashboard with statistics (blocked/allowed counts)
- View blocked connections with color highlighting
- View allowed connections
- Filter by port or IP address
- Real-time log monitoring (live tail)
- Search logs by keyword
- **Top blocked IPs analysis** with ban option
- **Top targeted ports analysis**
- Log rotation and cleanup
- Export log entries

**Command Line Options:**
```bash
./Shellder/nginx-setup.sh              # Interactive mode selection
./Shellder/nginx-setup.sh -s           # Setup mode directly
./Shellder/nginx-setup.sh -m           # Maintenance mode directly
./Shellder/nginx-setup.sh --status     # Show status dashboard only
./Shellder/nginx-setup.sh --help       # Help
```

---

### `Shellder/dbsetup.sh` - Database Setup & Maintenance

Dual-mode script for initial database setup and ongoing maintenance.

```bash
sudo bash ./Shellder/dbsetup.sh
```

**Two Modes:**

#### Setup Mode
- Installs MariaDB if not present
- Detects system resources and calculates optimal settings
- Tunes MariaDB for your hardware (buffer pool, I/O, connections)
- Creates all required databases (dragonite, golbat, reactmap, koji, poracle)
- Creates database users with proper permissions

#### Maintenance Mode
Interactive dashboard with:

**Status Dashboard:**
- MariaDB server status and version
- Database sizes and connection status
- Account statistics (total, banned, invalid, warned)
- Map data counts (pokestops, gyms, spawnpoints)
- User permissions verification

**Account Cleanup:**
- Remove banned accounts
- Remove invalid accounts
- Remove auth-banned accounts
- Remove warned/suspended accounts
- Reset account flags (unban, clear warnings)

**Map Data Cleanup:**
- Remove stale pokestops (not seen in 24h)
- Remove stale gyms (not seen in 24h)
- Remove stale spawnpoints (not seen in 24h)
- Custom staleness threshold
- Truncate spawnpoint table (complete reset)
- Purge expired Pokemon

**Nest Management:**
- List unknown/unnamed nests
- Label unknown nests with area name or coordinates
- Delete unknown nests

**Database & User Management:**
- View required vs existing databases
- View config users vs database users
- Create missing databases automatically
- Create missing users from config files
- Grant full privileges to users
- Fix ALL issues with one click
- Manually create/delete users
- View user grants and permissions
- Reset all nests

**General Maintenance:**
- Optimize tables (reclaim disk space)
- Analyze tables (update query statistics)
- Check tables for errors
- Repair corrupted tables
- View table sizes
- Purge old statistics data
- Purge old quest/incident data
- Flush query cache

---

### `Shellder/check.sh` - Configuration & Status Checker

Interactive status dashboard and configuration validator.

```bash
sudo bash ./Shellder/check.sh
```

**Interactive Menu Options:**
1. **Status Dashboard** - Quick system health overview
2. **Full Configuration Check** - Detailed validation of all settings
3. **Docker & Container Status** - Check Docker and container health
4. **Configuration Alignment** - Verify passwords/secrets match
5. **File & Endpoint Check** - Verify files and service endpoints
6. **Port Status** - Check which ports are in use

**Command Line Options:**
```bash
./Shellder/check.sh -d    # Status dashboard only
./Shellder/check.sh -f    # Full configuration check
./Shellder/check.sh -q    # Quick check (non-interactive, for scripts)
./Shellder/check.sh -h    # Help
```

**Status Dashboard Shows:**
- Docker installation and daemon status
- Docker Compose availability
- User permissions and docker group membership
- MariaDB connection and version
- Container status (running/stopped/missing)
- Configuration alignment (passwords, secrets, tokens)

**What it validates:**
- ✅ Environment variables match across all configs
- ✅ Database passwords are consistent
- ✅ API secrets are properly configured
- ✅ Docker and Docker Compose running
- ✅ Container health status
- ✅ Required files exist
- ✅ Service endpoints configured correctly
- ✅ User/group permissions
- ✅ Port availability

---

### `Shellder/poracle.sh` - Alert Bot Setup

Sets up Poracle for Discord/Telegram notifications.

```bash
sudo bash ./Shellder/poracle.sh
```

**What it does:**
- Guides you through Discord/Telegram bot creation
- Configures webhook connection from Golbat
- Sets up notification filters and geofences

**Prerequisites:** Running Golbat with webhook support enabled.

---

### `Shellder/fletchling.sh` - Nest Detection Setup

Configures Fletchling for Pokemon nest detection and display.

```bash
sudo bash ./Shellder/fletchling.sh
```

**What it does:**
- Configures Fletchling with your Koji project
- Imports park data from OpenStreetMap
- Enables automatic nest detection
- Integrates with ReactMap for display

**Prerequisites:** Create a project with geofences in Koji first.

---

### `Shellder/docker-osm-importer.sh` - OpenStreetMap Import

Imports OpenStreetMap data for park boundaries and features.

```bash
sudo bash ./Shellder/docker-osm-importer.sh
```

**What it does:**
- Downloads OSM data for your region
- Imports park and natural area boundaries
- Provides data for Fletchling nest detection

---

### `Shellder/logs.sh` - Docker Log Manager & Analyzer

Comprehensive log analysis, monitoring, and maintenance tool with special Xilriws management.

```bash
sudo bash ./Shellder/logs.sh
```

**Main Dashboard Shows:**
- All services with running/stopped status
- Log size for each container
- Error counts (total, warnings, critical) with **smart filtering** (excludes info messages)
- Color-coded health indicators

**Log Search Feature (Press 's'):**
- Search all containers or specific container by keyword
- Configurable context lines (default 3)
- Results summary showing matches per container
- User-friendly navigation with clear quit instructions

**Service Detail View:**
- Container uptime and status
- Log size and file path
- Error breakdown by category:
  - Account errors (login, auth, banned)
  - Database errors (MySQL, connection, deadlock)
  - Connection errors (timeout, refused, socket)
  - Memory errors (OOM, allocation)
  - API errors (HTTP 4xx/5xx, endpoint failures)
  - Device errors (worker, disconnect)
  - Critical errors (fatal, panic)
- Recent log activity preview
- **Numbered Error View** with context jump (press `e`)

**Xilriws Status & Proxy Management (Press 'x'):**
- Login Statistics:
  - Successful logins count
  - Auth-banned account count
  - Invalid credential count
- Error Breakdown:
  - Tunneling errors
  - Code 15 errors
  - Rate limiting incidents
  - Timeouts and connection refused
  - Proxy errors
  - Permanently banned IPs
- Live Monitoring Mode:
  - Real-time statistics display
  - Consecutive failure tracking
  - **Auto-restart container after 30 consecutive failures**
  - Visual alerts for critical states

**Proxy Manager (Press 'p' from Xilriws menu):**
- Proxy Statistics:
  - Total proxy count and file size
  - Unique IPs/domains analysis
  - Group/subnet distribution
  - Consecutive same-group detection
- Proxy Randomization:
  - **Smart shuffle avoiding consecutive same-IP/domain entries**
  - Groups proxies by IP subnet (first 3 octets) or domain
  - Minimizes detection patterns
  - Auto-backup before changes
- Proxy Cleanup:
  - View banned IP addresses from logs
  - Find failing proxies (configurable threshold, default 25+)
  - Remove banned IPs from proxy.txt
  - Remove failing proxies (no successful logins)
  - Remove duplicate proxies
  - View first/last proxy samples

**Error Analysis Features:**
- View errors by category with context
- Color-coded log output (errors=red, warnings=yellow)
- **Smart error filtering** - excludes info messages like:
  - `ℹ` prefixed lines, `level=info` Grafana logs
  - Database bound/migration messages
  - "Successfully" and "completed" messages
  - ReactMap `[CONFIG]`, `[API]`, `[STATS]` etc.
- **Startup error annotation** - marks errors that occurred during container startup
- **Numbered Error List** (press `e` in service detail):
  - Paginated view of all errors (20 per page)
  - Shows error number, log line number, and message
  - Select any error number to view with **50 lines of context** before/after
  - Filter errors by keyword
  - Extended context view (100 or 200 lines)
  - Copy error to clipboard
- Search functionality with preset patterns:
  - Device disconnects
  - Account errors
  - Database errors
  - Connection issues
  - Custom regex search

**User-Friendly Navigation:**
All log viewers display clear instructions:
```
╔══════════════════════════════════════════════════════════════════════════╗
║  Navigation: Press Enter to scroll, q to quit, / to search              ║
║  Arrows: ↑/↓ scroll line, PgUp/PgDn scroll page                         ║
╚══════════════════════════════════════════════════════════════════════════╝
```

**Device Disconnect Monitor:**
- Scans Rotom and Dragonite logs
- Shows disconnect event counts
- Displays recent disconnect entries

**Log Maintenance:**
- View all log sizes at a glance
- Clear individual service logs
- Clear ALL logs at once
- View log file paths

**Docker Configuration:**
- View current daemon.json settings
- Apply recommended log rotation settings
- Edit config manually
- Restart Docker to apply changes

**Command Line Options:**
```bash
./Shellder/logs.sh              # Interactive menu
./Shellder/logs.sh -h           # Quick health check
./Shellder/logs.sh -x           # Xilriws status & proxy management
./Shellder/logs.sh --xilriws-monitor  # Xilriws live monitor mode
./Shellder/logs.sh --clear-all  # Clear all logs
./Shellder/logs.sh --help       # Help
```

---

## Quick Start

For experienced users, here's the fastest path to a running system:

```bash
# Clone and enter directory
git clone https://github.com/The-Pokemod-Group/Aegis-All-In-One.git
cd Aegis-All-In-One

# Launch the main control panel
sudo bash ./shellder.sh
```

The control panel provides a unified interface to:
- Run initial setup (option 1)
- Start all containers (option 8)
- Set up security (option 3)
- Monitor and troubleshoot (options 4-5)

**Or run individual commands:**

```bash
# Run setup (creates configs, databases, passwords)
sudo bash ./Shellder/setup.sh

# Start all services
docker compose up -d

# (Optional) Secure for external access
sudo bash ./Shellder/nginx-setup.sh
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
sudo bash ./Shellder/setup.sh
```

The setup script will:

- ✅ Check and install Docker if needed
- ✅ Configure Docker log rotation to prevent disk space issues
- ✅ **Check port availability** (6001-6006, 7070, 5090) with advanced remediation:
  - Investigate containers bound to ports
  - Remove/purge old containers
  - Clean Docker networks
  - Full Docker cleanup option
- ✅ Generate secure random passwords for all services
- ✅ Create configuration files from templates
- ✅ Set up MariaDB with optimized settings for your hardware
- ✅ Create all required databases
- ✅ Configure inter-service communication
- ✅ **Properly restore file ownership** to non-root user

You'll be prompted to customize:
- Database usernames and passwords (properly configured across all services including Koji and init scripts)
- API secrets and bearer tokens
- Service-specific settings

> 💡 **Note**: Custom database usernames are now properly applied to all configuration files, including Koji environment URLs and the database initialization script.

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

> 💡 **Note**: Grafana runs with proper user permissions (PUID/PGID from `.env`) to avoid permission denied errors on startup.

### Xilriws (Port 6008)

Pokemon GO API proxy service that:
- Handles authentication requests from devices
- Obtains login cookies for accounts
- Manages proxy rotation for requests
- Provides account status monitoring

---

## Optional Features

### Poracle - Discord/Telegram Alerts

Send Pokemon spawn, raid, and quest notifications to Discord or Telegram.

```bash
sudo bash ./Shellder/poracle.sh
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
sudo bash ./Shellder/fletchling.sh
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

## Xilriws Operation

Xilriws is a critical component that handles Pokemon GO authentication requests. Proper management of proxies and monitoring of login success rates is essential for smooth operation.

### Accessing Xilriws Management

Access Xilriws tools via the Log Manager:

```bash
# Via main control panel
sudo bash ./shellder.sh
# Select option 5) Log Manager, then press 'x'

# Or directly
sudo bash ./Shellder/logs.sh -x
```

### Xilriws Status Dashboard

The status dashboard provides real-time visibility into Xilriws performance:

| Metric | Description |
|--------|-------------|
| **Successful Logins** | Number of accounts that obtained cookies successfully |
| **Auth-Banned** | Accounts flagged as authentication banned |
| **Invalid Credentials** | Failed logins due to wrong password/username |
| **Tunneling Errors** | Proxy tunnel/CONNECT failures |
| **Code 15 Errors** | Specific API error responses |
| **Rate Limited** | Requests blocked due to rate limiting |
| **Timeouts** | Connection timeouts to proxy or API |
| **Connection Refused** | Failed connections to proxies |
| **Proxy Errors** | General proxy-related failures |
| **Permanently Banned** | IPs flagged as permanently banned |
| **Success Rate** | Percentage of successful logins |

### Xilriws Menu Options

| Option | Key | Description |
|--------|-----|-------------|
| View Recent Errors | `1` | Display last 50 error entries from logs |
| Live Monitoring Mode | `2` | Real-time stats with auto-restart on 30 consecutive failures |
| Clear Logs | `3` | Truncate Xilriws container logs |
| Restart Container | `4` | Restart Xilriws container |
| Proxy Manager | `p` | Access proxy management submenu |

### Proxy Manager

The Proxy Manager provides comprehensive tools for maintaining your proxy list:

| Option | Key | Description |
|--------|-----|-------------|
| View Proxy Statistics | `1` | Total count, unique IPs, group distribution |
| Randomize Proxy List | `2` | Smart shuffle avoiding consecutive same-subnet entries |
| View Banned IPs | `3` | IPs associated with ban messages in logs |
| Find Failing Proxies | `4` | Proxies with 25+ failures and no success |
| Remove Banned IPs | `5` | Remove banned IPs from proxy.txt |
| Remove Failing Proxies | `6` | Remove consistently failing proxies |
| Remove Duplicates | `7` | Remove duplicate entries |
| View Sample | `8` | Display first/last 10 proxies |

### Proxy Randomization

The randomization feature intelligently shuffles your proxy list:

**How it works:**
1. Groups proxies by IP subnet (first 3 octets) or domain
2. Shuffles the list while avoiding consecutive same-group entries
3. Creates automatic backup before modification
4. Reports unavoidable consecutive duplicates (when too many proxies share a subnet)

**Benefits:**
- Distributes load across different proxy providers
- Reduces detection patterns
- Minimizes consecutive failures from same source

**Example:**
```
Before: 192.168.1.10, 192.168.1.20, 192.168.1.30, 10.0.0.5, 10.0.0.6
After:  192.168.1.10, 10.0.0.5, 192.168.1.20, 10.0.0.6, 192.168.1.30
```

### Live Monitoring Mode

The live monitoring mode provides continuous oversight:

```bash
# Start directly from command line
sudo bash ./Shellder/logs.sh --xilriws-monitor
```

**Features:**
- Real-time statistics refresh (every 3 seconds)
- **Watches for Xilriws "30 consecutive failures" log message**
- Auto-restart container when Xilriws stops trying proxies
- Highlights critical messages in red
- Last 5 log entries displayed
- Restart counter tracking
- Press Ctrl+C to exit

**Auto-restart trigger:**
The monitor specifically watches for the critical error message from Xilriws:

```
30 consecutive failures in the browser! this is really bad
```

This message indicates Xilriws has stopped attempting to use proxies entirely and needs a restart to recover.

When this message is detected in the logs:
1. Displays a critical warning banner
2. Automatically restarts the Xilriws container
3. Resets the baseline failure count
4. Increments the restart counter
5. Continues monitoring

### Proxy File Requirements

Xilriws expects a `proxy.txt` file in the project root with the following formats supported:

```
# IP:Port
192.168.1.1:8080

# User:Pass@IP:Port
username:password@192.168.1.1:8080

# Protocol://IP:Port
http://192.168.1.1:8080
socks5://192.168.1.1:1080

# Full format
http://username:password@192.168.1.1:8080
```

### Proxy Maintenance Best Practices

1. **Regular Monitoring**: Check the status dashboard daily for degradation
2. **Remove Bad Proxies**: Use the failing proxy removal tool weekly
3. **Randomize Periodically**: Shuffle the list after removing proxies
4. **Keep Backups**: All modifications create timestamped backups
5. **Monitor Success Rate**: Aim for >50% success rate; investigate drops
6. **Check Banned IPs**: Remove permanently banned IPs promptly

### Command Line Quick Access

```bash
# Xilriws status menu
sudo bash ./Shellder/logs.sh -x

# Start live monitoring
sudo bash ./Shellder/logs.sh --xilriws-monitor

# Quick health check (all services)
sudo bash ./Shellder/logs.sh -h
```

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
sudo bash ./Shellder/nginx-setup.sh
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

### Ongoing Security Management

After initial setup, use **Maintenance Mode** to manage your security configuration:

```bash
sudo bash ./Shellder/nginx-setup.sh -m
```

This provides a colorful dashboard showing:
- All service statuses at a glance
- Quick health checks
- Easy access to common tasks (restart services, add sites, manage certificates)

---

## Configuration

### Validate Your Setup

Run the configuration checker to ensure everything is properly configured:

```bash
sudo bash ./Shellder/check.sh
```

This provides an interactive menu with:
- **Status Dashboard** - Quick health overview of Docker, MariaDB, containers
- **Full Configuration Check** - Detailed validation with pass/warn/fail counts
- **Quick Check** - Use `./Shellder/check.sh -q` for non-interactive validation

### Database Management

The setup script automatically tunes MariaDB based on your hardware during initial setup. For ongoing database maintenance:

```bash
sudo bash ./Shellder/dbsetup.sh
```

**Choose Maintenance Mode to:**
- View status dashboard (accounts, data counts, database sizes)
- Clean up banned/invalid accounts
- Remove stale map data (pokestops, gyms, spawnpoints)
- Manage unknown nests
- Optimize and repair tables
- Purge old statistics and expired data
- **Create missing databases and users**
- **Fix user permissions automatically**

**Choose Setup Mode to:**
- Re-tune MariaDB for your hardware
- Create new databases or users
- Reinstall MariaDB if needed

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

### Pulling Updates

The scripts automatically preserve your configuration when pulling updates:

```bash
# Via shellder.sh (recommended)
sudo bash ./shellder.sh
# Select p) Pull Latest

# Or directly via git
git pull  # May prompt about local changes
```

**What happens automatically:**
1. Your local config changes (`.env`, `*.toml`, etc.) are saved
2. Updates are pulled from GitHub
3. Your configs are restored
4. No manual stashing required!

> 💡 **Tip**: If you see merge conflicts after pulling, run `setup.sh` again to regenerate configs, or manually edit the conflicting files.

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
2. Run the config checker: `sudo bash ./Shellder/check.sh`
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
