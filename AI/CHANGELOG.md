# Aegis AIO Changelog

> Project change history for AI assistants and collaborators.

---

## Format

```
## [Version] - YYYY-MM-DD
### Added / Changed / Fixed / Removed
- Description of change
```

---

## [Unreleased]

### Added
- **Metrics Page Redesign** - Full-page Grafana dashboard
  - Removed "Historical Shellder Stats" and "All-Time Proxy Stats" sections
  - Grafana iframe now fills viewport (`calc(100vh - 200px)`)
  - Fullscreen toggle button for even larger view
  - Compact status bar with VictoriaMetrics/Grafana status indicators
  - Inline setup wizard with step-by-step progress
  - Credential form for Grafana login during dashboard import
  - Live setup log showing import progress
- **Grafana Provisioning System**
  - `grafana/provisioning/datasources/victoriametrics.yml` - Auto-configure datasource
  - `grafana/provisioning/dashboards/aegis.yml` - Auto-load dashboards
  - `grafana/dashboards/Dragonite-Emi-v5.json` - Pre-configured dashboard
  - Docker Compose mounts for provisioning directories
- **GRAFANA_ADMIN_PASSWORD** - Added to password generation in Setup Wizard
- **Setup Wizard Enhancements**
  - Live stack logging during `docker compose up -d`
  - Auto-apply MariaDB optimization when resources detected
  - Progress bar updates after each step completion
  - Partial stack state detection ("partially started" status)

### Changed
- **Removed Updates Page** - Functionality moved to Setup & Config → GitHub Manager
- **MariaDB Setup** - Now exclusively uses `docker exec database mariadb` (not localhost)
- **MariaDB Client** - Changed from `mysql` to `mariadb` command for newer containers
- **Metrics queries** - Use `docker exec victoriametrics` for PromQL queries

### Fixed
- **Grafana 401 errors** - Now tries multiple passwords (provided, .env, default)
- **Grafana "starting up" loop** - Fixed health check to use GET /api/health
- **requests import missing** - Added `import requests` for Grafana status checks
- **Dashboard not found** - Improved dashboard UID detection and import
- **Config variables check** - Now updates after password and config copy steps

---

## [Previous Unreleased]

### Added
- AI/ folder for cross-tool AI collaboration
- MCP server documentation (AI/MCP_SERVER.md)
- AI Debug API reference (AI/AI_DEBUG_API.md)
- Project structure guide (AI/STRUCTURE.md)
- This changelog file
- **Stack Configuration System** - Configurable component paths and remote support
  - `Shellder/shellder_config.toml` - Master configuration file
  - `Shellder/config_loader.py` - Python configuration loader
  - `Shellder/config_loader.sh` - Shell script configuration loader
  - Web UI "Shellder" page under Overview for configuration management
  - API endpoints: `/api/stack-config`, `/api/stack-config/components`, etc.
  - Support for local Docker containers OR remote services per component
- Sidebar menu scrollbar for small screens
- **Golbat Webhook Manager** - CRUD UI for webhooks in config editor
- **Fletchling Tab** - Under Management with status, setup wizard, and nest management
  - OSM park data import step (critical for nest detection)
  - Nest list with filtering by area, unknown names, active status
  - Edit/delete nests, bulk operations by area
  - Statistics dashboard (total nests, active, unknown names)
- **Poracle Tab** - Discord/Telegram alert bot management
  - Status grid: Docker, Config, Container, Database, Discord, Telegram, Webhook
  - 7-step setup wizard with Discord/Telegram bot configuration
  - Geofence import from Koji
  - Container controls and log preview
  - API endpoints: `/api/poracle/status`, `/api/poracle/configure-discord`, etc.
- **File Manager Enhancements** - Upload, ownership, permissions, sudo support
- **Config Editor** - Shows commented-out optional fields with badges
- **Sites & Security Setup Wizard** - Under Overview section
  - 5-step wizard: Nginx → Sites → Certbot → Fail2Ban → UFW
  - Sites must be configured BEFORE SSL certificates
  - Individual install buttons with status indicators
- **Enhanced Logs Page** - Moved to Monitoring section
  - Tab-based container selection (All, Dragonite, Golbat, Rotom, etc.)
  - Custom search tab with advanced filtering:
    - Multi-container selection for combined logs
    - Time range filtering with timezone conversion (UTC → local)
    - Text search and regex patterns
    - Exclude filters (DEBUG, INFO, heartbeat, health checks)
    - Log level filtering (ERROR, WARN, INFO, DEBUG)
    - Saved presets
  - Live clock showing user's local timezone
  - Download logs to file
  - Auto-refresh toggle

### Changed
- Moved DEEP_ANALYSIS.md to AI/ folder
- Moved STACK_SIMULATION.md to AI/ folder
- Updated .gitignore to exclude node_modules in mcp-server
- Updated shellder_service.py to use configurable component paths
- AI Debug API port corrected: 5000 (not 5050) - same as web dashboard
- **Navigation Reorganization:**
  - Sites & Security moved from Management to Overview
  - Logs moved from Management to Monitoring
  - Xilriws moved from Monitoring to Management
- **Service dropdown corrected** - Fixed incorrect port assignments:
  - Removed Dragonite (has no UI) - Admin IS the Dragonite UI
  - Removed Golbat (has no UI)
  - Fixed Koji port: 6004 (was incorrectly 6002)
  - Fixed Rotom port: 6003 (was incorrectly 6004)
  - Added phpMyAdmin: 6005
  - Fixed Grafana port: 6006 (was incorrectly 3000)

### Fixed
- **Xilriws Log Parsing** - ANSI color codes now stripped before regex matching
- **Xilriws Stats Display** - Removed duplicate `updateXilriwsPage` function that was overwriting correct one
- **Xilriws Proxy Stats** - Added 'local' tracking when no external proxy configured
- **Metrics Charts** - SQLite busy_timeout and WAL mode prevent database locking
- **Metrics Charts** - AbortController cancels in-flight requests when switching periods
- **Metrics Charts** - Bar width CSS fixed to fill container proportionally
- **Config Editor** - Fixed nested TOML section navigation (db.dragonite.user)
- **Config Status** - Fixed detection of configured vs default values
- **File Manager** - Base64 encoding for paths with special characters
- **Docker Start** - Handles already-running containers and port conflicts gracefully
- **CRITICAL: GUI Broken After Config Loader Update** - Function wrapper at end of script.js was reassigning `window.navigateTo`, breaking all onclick handlers. Removed wrapper and added page handling directly in navigateTo().
- **File Ownership** - All file write operations now call `fix_file_ownership()` to prevent root-owned files
- **Grafana Permissions** - Fixed container startup failure due to wrong PUID/PGID in .env
- **PUID/PGID Auto-Detection** - Now auto-detects from AEGIS_ROOT owner, works for any user/uid
- **Docker Volume Permissions** - New API endpoint `/api/files/fix-docker-permissions` fixes all volume dirs

### Auto-Detection System (NEW)
- `auto_detect_and_fix_puid_pgid()` - Runs on Shellder startup
  - Detects correct owner from AEGIS_ROOT directory
  - Auto-updates .env if PUID/PGID don't match
  - No hardcoded usernames or UIDs
  - Works for any Linux user (pokemap, ubuntu, etc.)
- `get_aegis_owner()` - Priority-based owner detection
  1. SUDO_USER environment variable
  2. Owner of AEGIS_ROOT directory  
  3. PUID/PGID from environment
  4. User lookup by common names
  5. Fallback to uid 1000, then 1001
- All Docker volume directories fixed on demand:
  - grafana/, victoriametrics/, vmagent/, mysql_data/
  - Shellder/data/, Shellder/logs/, unown/logs/

### Fail2Ban Python 3.11+ Compatibility (NEW)
- **asynchat Fix** - Python 3.12 removed `asynchat` from stdlib
  - `ensure_asynchat_available()` - Auto-installs pyasynchat package
  - Applied in both installation and start/restart actions
  - Works on Ubuntu 24.04 (Python 3.12) and newer
- **nginx-badbots Filter Fix** - Stock filter has bad regex for Python 3.11+
  - Original: `(?i)` in middle of regex (invalid in Python 3.11+)
  - Fixed: Moves `(?i)` to start of expression
  - Auto-detects and fixes during Fail2Ban installation
  - Removes duplicate jail files (nginx.local → aegis.local only)

### Graceful Docker Shutdown (NEW)
- Prevents database restart loops when stopping via GUI
- Stop order: Apps → Infrastructure → Database
- Wait periods between service groups
- Handles container dependencies properly
- Fixes issue where clicking Stop would corrupt MariaDB state

---

## [2.0.0] - 2024-12 (Shellder Release)

### Added
- **Shellder Control Panel** - Complete management system
  - Web dashboard on port 5000
  - Real-time container stats via WebSocket
  - System resource monitoring (CPU, RAM, Disk)
  - Xilriws proxy monitoring
  - SQLite database for persistent stats
  - AI Debug API endpoints

- **Shell Scripts** (moved to Shellder/)
  - `setup.sh` - Initial setup wizard
  - `check.sh` - Status validation
  - `dbsetup.sh` - Database management
  - `logs.sh` - Log viewer & analysis
  - `nginx-setup.sh` - Security setup
  - `files.sh` - File management
  - `db_helper.sh` - SQLite operations
  - `log_helper.sh` - Logging helper

- **MCP Server** (`Shellder/mcp-server/`)
  - Model Context Protocol integration
  - Tools for Cursor/Claude AI assistants
  - Direct access to diagnostics, files, Docker, SQL

- **Web Dashboard Features**
  - Live container stats with sparklines
  - Metric history charts (10m/1h/6h/24h/7d)
  - System services monitoring
  - Site availability checks
  - Device monitor with crash tracking
  - AI Debug panel with Pull & Restart
  - File browser and editor

- **Documentation**
  - Complete wiki documentation
  - Deep analysis document
  - Stack simulation document

### Changed
- Renamed `aegis.sh` → `shellder.sh`
- Restructured scripts into Shellder/ directory
- Updated docker-compose.yaml for Shellder service
- Enhanced MariaDB configuration

### Fixed
- Duplicate Flask server issue (consolidated to shellder_service.py)
- Operator precedence bug in log parsing
- Dockerfile copying deprecated files

---

## [1.x] - Previous Versions

### Features
- Basic Docker Compose stack
- Dragonite, Golbat, Rotom, ReactMap integration
- Xilriws proxy support
- Koji geofence management
- Grafana dashboards
- phpMyAdmin database access

---

## Upstream Projects

This stack integrates the following projects:

| Project | Repository | Notes |
|---------|------------|-------|
| Dragonite | [unownhash/dragonite-public](https://github.com/UnownHash/Dragonite-Public) | Scanner backend |
| Golbat | [unownhash/golbat](https://github.com/UnownHash/Golbat) | Data processor |
| Rotom | [unownhash/rotom](https://github.com/UnownHash/Rotom) | Device manager |
| Xilriws | [unownhash/xilriws](https://github.com/UnownHash/Xilriws) | Auth proxy |
| ReactMap | [watwowmap/reactmap](https://github.com/WatWowMap/ReactMap) | Map frontend |
| Koji | [turtiesocks/koji](https://github.com/TurtIeSocks/Koji) | Geofence manager |

---

## Shellder Version History

| Version | Date | Key Changes |
|---------|------|-------------|
| 1.0.36 | 2024-12-03 | Setup & Config page, GitHub manager |
| 1.0.24 | 2024-12 | Chart bar distribution fixes |
| 1.0.17-23 | 2024-12 | Metric history, timezone handling |
| 1.0.13-16 | 2024-12 | System services, site availability |
| 1.0.0 | 2024-12 | Initial release |

---

## How to Update This File

When making significant changes:

1. Add entry under `## [Unreleased]`
2. Use appropriate category (Added/Changed/Fixed/Removed)
3. Be specific but concise
4. Include relevant file paths or feature names

When releasing:
1. Move [Unreleased] items to new version section
2. Add date to version header
3. Create new empty [Unreleased] section

