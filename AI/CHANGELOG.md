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
- AI/ folder for cross-tool AI collaboration
- MCP server documentation (AI/MCP_SERVER.md)
- AI Debug API reference (AI/AI_DEBUG_API.md)
- Project structure guide (AI/STRUCTURE.md)
- This changelog file

### Changed
- Moved DEEP_ANALYSIS.md to AI/ folder
- Moved STACK_SIMULATION.md to AI/ folder
- Updated .gitignore to exclude node_modules in mcp-server

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

