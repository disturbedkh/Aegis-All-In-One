# Aegis AIO - AI Context File

> **For AI Assistants:** Read this file first to understand the project completely.

---

## What is Aegis AIO?

**Aegis AIO** (All-In-One) is a Pokemon GO mapping infrastructure stack that orchestrates multiple containerized services for real-time Pokemon data collection, processing, and visualization.

**Purpose:** Provide a complete, pre-configured Docker stack for Pokemon mapping using Aegis devices and the Unown# ecosystem.

**Target Users:** Community map operators, Pokemon GO data enthusiasts, developers learning mapping infrastructure.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AEGIS AIO STACK                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                    SHELLDER (Control Panel)                          │    │
│  │  • shellder.sh - Main CLI interface                                  │    │
│  │  • shellderGUI.sh - Web dashboard launcher                          │    │
│  │  • Shellder/ - Scripts, service, MCP server                         │    │
│  │  • Port 5000 (Web UI) | Port 5050 (AI Debug API)                    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                      SCANNING LAYER                                  │    │
│  │                                                                      │    │
│  │  Aegis Phone ──WebSocket──▶ Rotom ──▶ Dragonite ──▶ Golbat         │    │
│  │     (7070)              (Device Mgr)  (Scanner)   (Processor)       │    │
│  │                              │            │            │             │    │
│  │                              │            │            ▼             │    │
│  │                              │            │      ┌──────────┐        │    │
│  │                              │            └─────▶│ Xilriws  │        │    │
│  │                              │           Auth    │  (5090)  │        │    │
│  │                              │                   └──────────┘        │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                      DATA LAYER                                      │    │
│  │                                                                      │    │
│  │  ┌──────────────────────────────────────────────────────────────┐   │    │
│  │  │                    MariaDB (3306 internal)                    │   │    │
│  │  │  golbat - Pokemon, gyms, stops, raids                        │   │    │
│  │  │  dragonite - Accounts, workers, scan config                  │   │    │
│  │  │  reactmap - Map settings, user preferences                   │   │    │
│  │  │  koji - Geofences, projects                                  │   │    │
│  │  │  poracle - Alert configurations                              │   │    │
│  │  └──────────────────────────────────────────────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                      FRONTEND LAYER                                  │    │
│  │                                                                      │    │
│  │  ReactMap (6001) │ Koji (6004) │ Grafana (6006) │ phpMyAdmin (6005) │    │
│  │      Map UI         Geofence      Statistics        DB Admin         │    │
│  │                     Editor        Dashboards                         │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Core Components

### Scanning Pipeline

| Component | Purpose | Ports | Has UI? |
|-----------|---------|-------|---------|
| **Aegis** | Mobile device app that scans Pokemon GO | Connects to 7070 | Phone app |
| **Rotom** | Device manager & communication hub | 7070 (devices), 6003 (Web UI) | ✅ Yes |
| **Dragonite** | Scanner backend & task distribution | 7272 (API only) | ❌ No UI |
| **Admin** | Web UI frontend for Dragonite | 6002 | ✅ Yes (Dragonite's UI) |
| **Golbat** | Data processor & Pokemon tracker | 9001 (API), 50001 (gRPC) | ❌ No UI |
| **Xilriws** | Pokemon GO authentication proxy | 5090 (API only) | ❌ No UI |

**Important:** Dragonite and Golbat are backend services with NO web interface. The "Admin" container IS the web UI for managing Dragonite.

### Data Flow

```
Aegis Phone → Rotom → Dragonite → Golbat → MariaDB → ReactMap
                         ↓
                      Xilriws (for auth)
```

### Management & Monitoring

| Component | Purpose | Port |
|-----------|---------|------|
| **Shellder** | Web dashboard & CLI management | 5000 |
| **Koji** | Geofence/area management | 6004 |
| **Grafana** | Performance monitoring (embedded in Shellder Metrics page) | 6006 |
| **VictoriaMetrics** | Time-series metrics database | 8428 (internal) |
| **VMAgent** | Metrics scraper | 8429 (internal) |
| **phpMyAdmin** | Database administration | 6005 |

### Optional Features (Commented in docker-compose.yaml)

| Component | Purpose | Port |
|-----------|---------|------|
| **Fletchling** | Nest detection (correlates spawns with OSM park data) | 9042 |
| **Poracle** | Discord/Telegram alert notifications | 3030 (webhook) |

#### Fletchling - Nest Tracking

Detects which Pokemon species are "nesting" in parks/nature areas by:
1. Importing park boundaries from OpenStreetMap (OSM)
2. Correlating Pokemon spawns with park locations
3. Identifying species that spawn disproportionately in specific parks

**Critical Step:** Must run OSM importer after enabling:
```bash
docker compose exec fletchling-tools ./fletchling-osm-importer "AreaName"
```
Area name must match a Koji geofence exactly.

**Data Flow:** `Golbat → webhook (9042) → Fletchling → golbat.nests table → ReactMap`

#### Poracle - Alert Bot

Sends Discord/Telegram notifications when Pokemon spawn, raids start, etc.

**Data Flow:** `Golbat → webhook (3030) → Poracle → Discord/Telegram`

---

## Key Directories

| Directory | Purpose |
|-----------|---------|
| `AI/` | AI assistant documentation (this folder) |
| `Shellder/` | Management scripts & web service |
| `unown/` | Scanner configuration (dragonite, golbat, rotom) |
| `reactmap/` | ReactMap configuration |
| `Poracle/` | Alert bot configuration |
| `wiki/` | GitHub wiki documentation |
| `init/` | Database initialization SQL |
| `mysql_data/` | MariaDB data storage |

---

## Configuration Files

### Primary Configuration

| File | Purpose |
|------|---------|
| `.env` | Environment variables (NEVER commit - contains secrets) |
| `docker-compose.yaml` | Container definitions and networking |

### Service Configs

| File | Service | Format |
|------|---------|--------|
| `unown/dragonite_config.toml` | Dragonite | TOML |
| `unown/golbat_config.toml` | Golbat | TOML |
| `unown/rotom_config.json` | Rotom | JSON |
| `unown/proxies.txt` | Xilriws | Text (one per line) |
| `reactmap/local.json` | ReactMap | JSON |
| `fletchling.toml` | Fletchling | TOML |
| `Poracle/config/local.json` | Poracle | JSON |

---

## Databases

| Database | Contents |
|----------|----------|
| `golbat` | Pokemon sightings, gyms, pokestops, raids, quests |
| `dragonite` | PTC/Google accounts, workers, scan configuration |
| `reactmap` | Map user settings, saved locations |
| `koji` | Geofences, projects, spawn points |
| `poracle` | Alert subscriptions, user preferences |

**Shellder SQLite** (`Shellder/shellder.db`) stores:
- Proxy statistics
- Error tracking
- Container health
- Config validation history

---

## Common Operations

### Starting the Stack
```bash
# Via Shellder (recommended)
sudo bash ./shellder.sh
# Select: s) Start Stack

# Direct Docker
docker compose up -d
```

### Viewing Logs
```bash
# Specific container
docker compose logs -f dragonite

# Via Shellder
bash Shellder/logs.sh
```

### Checking Status
```bash
./shellder.sh --status
# or
bash Shellder/check.sh
```

### Web Access
- **ReactMap:** http://localhost:6001
- **Shellder Dashboard:** http://localhost:5000
- **Dragonite Admin:** http://localhost:6002
- **Rotom UI:** http://localhost:6003
- **Koji:** http://localhost:6004

---

## AI Integration

### MCP Server
Located at `Shellder/mcp-server/`, provides tools for AI assistants:
- `shellder_diagnose` - System diagnostics
- `shellder_docker` - Container operations
- `shellder_sql` - Database queries
- `shellder_logs` - Log retrieval
- `shellder_exec` - Command execution

**See:** [MCP_SERVER.md](MCP_SERVER.md)

### AI Debug API
REST API at `http://localhost:5000/api/ai-debug/*`

**Note:** The AI Debug API runs on the same port as the web dashboard (5000), not 5050.

**See:** [AI_DEBUG_API.md](AI_DEBUG_API.md)

### Remote Access
When connecting from a different machine (e.g., Cursor on Windows to a Linux server):
- Use the server's IP instead of `localhost`
- Example: `http://<your-server-ip>:5000/api/ai-debug/diagnose`
- Ensure port 5000 is open in firewall (`sudo ufw allow 5000`)
- Forward port through router if behind NAT

---

## Related Documentation

| File | Purpose |
|------|---------|
| [RULES.md](RULES.md) | Guidelines for AI assistants |
| [STRUCTURE.md](STRUCTURE.md) | Complete directory structure |
| [CHANGELOG.md](CHANGELOG.md) | Project change history |
| [MCP_SERVER.md](MCP_SERVER.md) | MCP server documentation |
| [AI_DEBUG_API.md](AI_DEBUG_API.md) | REST API reference |
| [DEEP_ANALYSIS.md](DEEP_ANALYSIS.md) | System deep-dive |
| [STACK_SIMULATION.md](STACK_SIMULATION.md) | Data flow simulation |
| [COLLABORATORS.md](COLLABORATORS.md) | Team coordination |

---

## File Permissions & Ownership

### Auto-Detection System

Shellder automatically detects the correct user for file permissions on startup:

```
Checking PUID/PGID configuration...
[Shellder] Auto-detected PUID:PGID = 1001:1001 (was 1000:1000)
[Shellder] Updated .env with correct PUID=1001 PGID=1001
Aegis owner: pokemap (uid=1001, gid=1001)
```

**Detection Priority:**
1. Owner of AEGIS_ROOT directory (whoever owns the project)
2. SUDO_USER environment variable (if running with sudo)
3. PUID/PGID from .env file
4. User lookup by name
5. Fallback to uid 1000, then 1001

**No Hardcoded Values:** Works for any username and any UID.

### Docker Volume Permissions

If Docker containers can't write to their data directories:

```bash
# Via API
POST /api/files/fix-docker-permissions

# Via Shellder
sudo bash ./shellder.sh
# Select file operations
```

Fixes these directories:
- `grafana/` - Grafana dashboards and data
- `victoriametrics/` - Metrics database
- `vmagent/` - Metrics agent data
- `mysql_data/` - MariaDB database files
- `Shellder/data/`, `Shellder/logs/` - Shellder data
- `unown/logs/`, `unown/golbat_cache/` - Scanner caches

### Common Permission Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Grafana won't start | Wrong PUID/PGID in .env | Restart Shellder (auto-fixes) |
| Files owned by root | GUI operations with sudo | Use "Fix All Ownership" button |
| Can't edit configs | Wrong file permissions | `sudo chown -R $USER:$USER .` |

---

## Sites & Security

### Setup Wizard (in Dashboard)

Located in Overview → Sites & Security. Guided 6-step setup:

1. **Nginx** - Web server/reverse proxy
2. **Sites** - Configure reverse proxy for services  
3. **Certbot** - SSL certificates (Let's Encrypt)
4. **Fail2Ban** - Brute-force protection
5. **Authentication** - Basic Auth (htpasswd) or Authelia (SSO)
6. **UFW** - Firewall rules

### Security Status Dashboard

Shows real-time status of all security services:
- UFW Firewall (active/inactive, rules count)
- Fail2Ban (active/inactive, banned IP count)
- Authelia SSO (installed/running)
- Basic Auth (user count from htpasswd)
- SSL Certificates (expiry dates)

### Authentication Options

| Option | Description | Use Case |
|--------|-------------|----------|
| **Basic Auth** | htpasswd-based | Simple password protection |
| **Authelia** | Full SSO container | 2FA, multiple users, access control |

### Python Compatibility (Ubuntu 23.10+)

**asynchat Module Missing (Python 3.12)**
- Fail2Ban requires `asynchat` which was removed from Python 3.12
- Shellder auto-installs `pyasynchat` package on install/start
- Applied to both installation and control panel actions

**Regex Flags (Python 3.11+)**
- Global flags like `(?i)` must be at start of expression
- nginx-badbots filter auto-fixed during Fail2Ban installation

---

## Quick Reference

### Essential Commands
```bash
docker compose up -d          # Start all containers
docker compose down           # Stop all containers
docker compose ps             # List container status
docker compose logs -f <svc>  # Follow service logs
docker compose restart <svc>  # Restart a service
```

### Shellder Commands
```bash
./shellder.sh --start         # Start stack
./shellder.sh --stop          # Stop stack
./shellder.sh --status        # View status
./shellder.sh --help          # Show help
```

### Troubleshooting Entry Points
1. `docker compose ps` - Check container status
2. `docker logs <container>` - Check container logs
3. `bash Shellder/check.sh` - Run validation
4. `http://localhost:5000` - Shellder dashboard
