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
| **Web Dashboard** | Modern UI at `http://localhost:5000` |
| **Live Container Stats** | Real-time CPU, memory, status for all containers |
| **Xilriws Monitoring** | Live proxy statistics and error tracking |
| **Log Streaming** | Real-time log aggregation from all services |
| **WebSocket Updates** | Instant updates without page refresh |
| **Remote Management** | Start/stop/restart containers from browser |

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

