# Shellder - Control Panel & Monitoring

**Shellder** is the shell management system and web dashboard for Aegis AIO — named after the Pokémon! 🐚

---

## What is Shellder?

Shellder serves as the **unified command center** for your entire Pokémon mapping infrastructure. It includes:

1. **Shell Scripts** - Interactive terminal-based management tools
2. **Web Dashboard** - Browser-based control panel with live monitoring
3. **Docker Service** - Containerized service for real-time stats and WebSocket updates

---

## Shellder Service (Docker Container)

The Shellder service runs as a Docker container providing live monitoring:

| Feature | Description |
|---------|-------------|
| **Web Dashboard** | Modern dark-themed UI at `http://localhost:5000` |
| **Live Container Stats** | Real-time CPU, memory, status for all containers |
| **System Metrics** | CPU, RAM, Disk usage with historical sparkline graphs |
| **Metric History Charts** | Click any metric for detailed 10m/1h/6h/24h/7d history |
| **Xilriws Monitoring** | Live proxy statistics and error tracking |
| **System Services** | Docker, MariaDB, Nginx, Python status monitoring |
| **Site Availability** | HTTP health checks for all configured sites |
| **Log Streaming** | Real-time log aggregation from all services |
| **WebSocket Updates** | Instant updates without page refresh |
| **Remote Management** | Start/stop/restart containers from browser |
| **AI Debug Panel** | Live debug logs, version info, Pull & Restart controls |

### Starting the Dashboard

```bash
# Option 1: With Docker Compose (recommended)
docker compose up -d shellder

# Option 2: Via launcher script
./shellderGUI.sh              # Auto-detect: Docker or local
./shellderGUI.sh --docker     # Force Docker mode
./shellderGUI.sh --local      # Force local Python/venv mode
./shellderGUI.sh --status     # Check status
./shellderGUI.sh --stop       # Stop service

# Option 3: Via Shellder menu
sudo bash shellder.sh
# Select 9) Shellder GUI
```

**Access at:** `http://localhost:5000` or `http://<your-ip>:5000`

### Web Dashboard Sections

| Section | Features |
|---------|----------|
| **Overview** | |
| └─ Dashboard | Live stats, container status, system services, quick actions |
| └─ Setup & Config | Setup wizard, GitHub manager, config editor |
| └─ Sites & Security | Nginx, SSL, firewall, authentication setup |
| **Monitoring** | |
| └─ Metrics | **Full-page Grafana dashboard** with VictoriaMetrics |
| └─ Logs | Multi-container viewer with search, filters, presets |
| **Management** | |
| └─ Containers | Start/stop/restart, CPU/RAM per container |
| └─ Devices | Connected device monitoring |
| └─ Xilriws | Proxy statistics, success rates, error tracking |
| └─ Fletchling | Nest detection setup and management |
| └─ Poracle | Discord/Telegram alert bot configuration |
| **Tools** | |
| └─ Files | File browser, editor, upload, permissions |
| └─ Scripts | Quick access to shell scripts |
| └─ Debug | AI debug panel, live logs, version info |

### Metric History Charts

Click on CPU, RAM, or Disk Usage cards to view detailed history:

- **10m** - Last 10 minutes (20 data points at 30s intervals)
- **1h** - Last hour
- **6h** - Last 6 hours
- **24h** - Last 24 hours
- **7d** - Last 7 days

Charts show:
- Current, Average, Min, Max values
- Interactive bar graph with time axis
- Local timezone-adjusted timestamps

### AI Debug Panel

The bottom-right panel provides developer tools:

- **Version & Git Commit** - Current Shellder version (e.g., v1.0.24)
- **Pull & Restart** - One-click update from GitHub and service restart
- **Git Pull** - Pull latest changes without restart
- **Restart** - Restart service only
- **Live Debug Log** - Real-time server logs with auto-refresh toggle
- **Uptime & PID** - Service health indicators

---

## Device Monitor

Real-time monitoring of connected scanning devices:

| Feature | Description |
|---------|-------------|
| **Live Activity** | Stream device events from Rotom/Dragonite logs |
| **Crash Tracking** | Automatic detection and logging of device crashes |
| **Cross-Reference** | Correlate crashes with database and log entries |
| **Memory Tracking** | Monitor device memory usage from Rotom reports |

The Device Monitor parses logs from:
- **Rotom** - Device connections, disconnections, memory reports
- **Dragonite** - Scan tasks, completions, errors
- **Database** - Device registration and status

---

## Recent Updates (v1.0.x)

### Version 1.0.50+ (December 2024)
- **Metrics Page Redesign** - Full-page Grafana dashboard replaces Statistics
  - Removed historical stats and all-time proxy stats sections
  - Grafana iframe fills viewport with fullscreen toggle
  - Inline setup wizard for first-time Grafana configuration
  - Credential form for dashboard import
- **Removed Updates Page** - Moved to Setup & Config → GitHub Manager
- **Grafana Auto-Provisioning** - Datasource and dashboard auto-configured on container start
- **Setup Wizard Improvements**
  - Live logging during stack startup
  - Auto-apply MariaDB optimization
  - Progress bar updates correctly
  - Partial stack state detection
- **MariaDB Setup Fixes** - Uses `docker exec` exclusively for container operations
- **GRAFANA_ADMIN_PASSWORD** - Added to password generation

### Version 1.0.40+ (December 2024)
- **Auto PUID/PGID Detection** - Automatically detects correct user from directory ownership
- **File Ownership Fixes** - All file writes now preserve correct ownership (no more root-owned files)
- **Docker Permissions API** - New `/api/files/fix-docker-permissions` endpoint
- **Grafana Fix** - Resolved container startup failures due to wrong PUID/PGID
- **Service Clarifications** - UI now shows which services have web interfaces
- **Sites Available** - Shows service descriptions and warnings for backend-only services

### Version 1.0.36+
- **Fletchling Management** - Nest detection setup wizard, OSM import, nest list
- **Poracle Setup** - Discord/Telegram alert bot configuration wizard
- **Enhanced Logs** - Multi-container filtering, timezone conversion, saved presets
- **Sites & Security Wizard** - Guided Nginx, Certbot, Fail2Ban, UFW setup
- **Golbat Webhook Manager** - Create/edit/delete webhooks in config editor

### Version 1.0.24-1.0.35
- Fixed chart bar distribution for all time ranges
- Improved metric history visualization
- Fixed nested TOML config editing
- Added config status detection for shared variables

### Version 1.0.17-1.0.23
- Added 10-minute quick view for metrics
- Fixed chart axes (Y=percentage, X=time)
- Added proper UTC timezone handling
- Fixed sparkline scaling (100% max for percentages)

### Version 1.0.13-1.0.16
- Added System Services monitoring (Docker, MariaDB, Nginx, Python)
- Added Site Availability HTTP health checks
- Improved error handling and null checks
- Added parallel service checks with shorter timeouts

### Earlier Versions
- Added AI Debug Panel with Pull & Restart
- Added CPU monitoring with sparklines
- Added Xilriws dashboard with live stats
- Added File browser and editor
- Added Device Monitor with crash tracking
- Comprehensive debug logging system

---

## Shell Scripts

### Architecture

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
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐             │
│   │  poracle.sh  │  │fletchling.sh │  │   files.sh   │             │
│   │   Alerts     │  │    Nests     │  │ File Manager │             │
│   └──────────────┘  └──────────────┘  └──────────────┘             │
│                                                                      │
├─────────────────────────────────────────────────────────────────────┤
│                         MANAGES ▼                                    │
├─────────────────────────────────────────────────────────────────────┤
│                      AEGIS AIO ECOSYSTEM                             │
│                        ┌─────────────────────────────────┐          │
│                        │         UNOWN# STACK            │          │
│                        │  Dragonite, Golbat, Rotom,      │          │
│                        │  ReactMap, Koji, Xilriws, etc.  │          │
│                        └─────────────────────────────────┘          │
└─────────────────────────────────────────────────────────────────────┘
```

### Script Reference

| Script | Purpose | When to Run |
|--------|---------|-------------|
| `shellder.sh` | **Main control panel** - unified interface | Anytime |
| `Shellder/setup.sh` | Initial setup wizard | First time setup |
| `Shellder/dbsetup.sh` | MariaDB management | Database tasks |
| `Shellder/check.sh` | Status & validation | Troubleshooting |
| `Shellder/logs.sh` | Docker log viewer | Monitoring |
| `Shellder/nginx-setup.sh` | Security setup | External access |
| `Shellder/poracle.sh` | Alert bot setup | Notifications |
| `Shellder/fletchling.sh` | Nest detection | After Koji setup |
| `Shellder/files.sh` | File management | Git/restore files |

### Internal Helper Scripts

| Script | Purpose |
|--------|---------|
| `Shellder/db_helper.sh` | SQLite database for stats/config |
| `Shellder/log_helper.sh` | Shellder operation logging |

---

## Key Functions

| Function | Description |
|----------|-------------|
| **Stack Control** | Start, stop, restart, rebuild Docker containers |
| **Initial Setup** | Guided wizard for first-time configuration |
| **Security Management** | Nginx, SSL, firewall, authentication |
| **Database Administration** | MariaDB tuning, maintenance |
| **Health Monitoring** | Status dashboard, validation |
| **Log Analysis** | View, search Docker logs |
| **Statistics Database** | Persistent SQLite stats |
| **Update Management** | Git pulls, image updates |

---

## Shellder Internal Database (SQLite)

> **⚠️ Different from MariaDB!**
>
> | Tool | Database | What It Stores |
> |------|----------|----------------|
> | `dbsetup.sh` | **MariaDB** | Game data (Pokemon, gyms, accounts) |
> | `db_helper.sh` | **SQLite** | Shellder's internal stats & config |

Shellder's SQLite database (`Shellder/shellder.db`) stores:

- **Proxy Statistics** - Request counts, success/fail rates
- **Error Stats** - Error types, occurrence counts
- **Container Stats** - Start/restart counts, uptime
- **Log Summaries** - Daily error/warning counts
- **System Events** - Important events with timestamps
- **Config Values** - Validated credentials

**Access via:**
- `logs.sh` → "All-Time Statistics"
- `dbsetup.sh` → "Shellder Statistics Database"

---

## Shellder Operation Log

> **⚠️ Different from Docker logs!**
>
> | Tool | Purpose | Shows |
> |------|---------|-------|
> | `logs.sh` | **Docker Logs** | Dragonite, Golbat output |
> | `log_helper.sh` | **Shellder Log** | Shellder script errors |

The operation log (`Shellder/shellder.log`) captures:

- Session starts/ends with timestamps
- User actions (menu selections, Docker ops)
- Errors with context (line numbers, suggestions)
- System snapshots on crashes
- Signal handling (Ctrl+C, kills)

```bash
# View recent logs
bash Shellder/log_helper.sh --view 50

# View errors only
bash Shellder/log_helper.sh --errors

# Export for AI debugging
bash Shellder/log_helper.sh --export-error

# Clear logs
bash Shellder/log_helper.sh --clear
```

---

## Configuration Validation

Shellder maintains configuration integrity:

- **Database credentials** verified before storing
- **API secrets** validated (8+ characters)
- **PUID/PGID** checked as numeric
- **Default values** automatically rejected
- **Discrepancy alerts** on config changes

On launch, Shellder compares `.env` against stored values and alerts on mismatches.

---

## External Access (Nginx)

Make the dashboard accessible externally:

```bash
sudo bash Shellder/nginx-setup.sh

# Navigate to:
#   2) Maintenance Mode
#   2) Site Management
#   s) Setup Shellder GUI

# Configure:
#   - Subdomain (e.g., shellder.yourdomain.com)
#   - Password protection (recommended)
#   - SSL certificate
```

### Managing Dashboard Users

```bash
# Change password
sudo htpasswd /etc/nginx/.htpasswd-shellder admin

# Add user
sudo htpasswd /etc/nginx/.htpasswd-shellder newuser

# Remove user
sudo htpasswd -D /etc/nginx/.htpasswd-shellder username
```

---

## Quick Start

```bash
# Launch the control panel
sudo bash ./shellder.sh

# Or use command-line shortcuts
./shellder.sh --start      # Start all containers
./shellder.sh --stop       # Stop all containers
./shellder.sh --status     # View status dashboard
./shellder.sh --help       # See all options
```

---

[[← Back to Home|Home]]

