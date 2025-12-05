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

| Component | Purpose | Ports |
|-----------|---------|-------|
| **Aegis** | Mobile device app that scans Pokemon GO | Connects to 7070 |
| **Rotom** | Device manager & communication hub | 7070 (devices), 6003 (UI) |
| **Dragonite** | Scanner backend & task distribution | 7272 (API), 6002 (Admin) |
| **Golbat** | Data processor & Pokemon tracker | 9001 (HTTP), 50001 (gRPC) |
| **Xilriws** | Pokemon GO authentication proxy | 5090 |

### Data Flow

```
Aegis Phone → Rotom → Dragonite → Golbat → MariaDB → ReactMap
                         ↓
                      Xilriws (for auth)
```

### Management

| Component | Purpose | Port |
|-----------|---------|------|
| **Shellder** | Web dashboard & CLI management | 5000 |
| **Koji** | Geofence/area management | 6004 |
| **Poracle** | Discord/Telegram alert bot | 3030 (webhook) |
| **Grafana** | Performance monitoring | 6006 |
| **phpMyAdmin** | Database administration | 6005 |

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
- Example: `http://77.237.241.111:5000/api/ai-debug/diagnose`
- Ensure port 5000 is accessible through firewall

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
