# Aegis AIO Project Structure

> Complete directory structure with descriptions for AI assistants.

---

## Root Directory

```
Aegis-All-In-One/
├── 📁 AI/                      # AI assistant documentation (this folder)
├── 📁 Shellder/                # Management scripts & web service
├── 📁 wiki/                    # GitHub wiki documentation
├── 📁 unown/                   # Scanner configuration files
├── 📁 reactmap/                # ReactMap configuration
├── 📁 Poracle/                 # Alert bot configuration
├── 📁 init/                    # Database initialization
├── 📁 mysql_data/              # MariaDB data & config
├── 📁 grafana/                 # Grafana dashboards
├── 📁 victoriametrics/         # Metrics storage
├── 📁 vmagent/                 # Metrics agent config
├── 📁 fletchling/              # Nest detection (if enabled)
│
├── 📄 shellder.sh              # Main control panel entry point
├── 📄 shellderGUI.sh           # Web dashboard launcher
├── 📄 docker-compose.yaml      # Container definitions
├── 📄 .env                     # Environment variables (secrets)
├── 📄 .cursorrules             # Cursor AI rules
├── 📄 .gitignore               # Git ignore patterns
└── 📄 README.md                # Project readme
```

---

## AI/ Directory (This Folder)

```
AI/
├── 📄 README.md                # How to use this folder
├── 📄 CONTEXT.md               # Project overview for AI
├── 📄 RULES.md                 # Guidelines for AI assistants
├── 📄 STRUCTURE.md             # This file - directory structure
├── 📄 CHANGELOG.md             # Project change history
├── 📄 COLLABORATORS.md         # Team coordination notes
├── 📄 MCP_SERVER.md            # MCP server documentation
├── 📄 AI_DEBUG_API.md          # REST API reference
├── 📄 DEEP_ANALYSIS.md         # System deep-dive analysis
└── 📄 STACK_SIMULATION.md      # Data flow simulation
```

---

## Shellder/ Directory

```
Shellder/
├── 📁 gui_static/              # Web dashboard assets
│   ├── script.js               # Frontend JavaScript (~11k lines)
│   └── style.css               # CSS styles (~8.5k lines)
├── 📁 gui_templates/           # HTML templates
│   └── index.html              # Main dashboard template (~3.2k lines)
├── 📁 mcp-server/              # MCP server for AI
│   ├── index.js                # MCP server entry point
│   ├── package.json            # Node.js dependencies
│   └── node_modules/           # Installed packages (gitignored)
├── 📁 data/                    # Persistent data storage
│   └── shellder.db             # SQLite database (metrics, stats)
├── 📁 logs/                    # Shellder logs
│   └── debuglog.txt            # Debug log file
│
├── 📄 shellder_service.py      # Main Python web service (~17k lines)
├── 📄 shellder_config.toml     # Stack configuration (NEW)
├── 📄 config_loader.py         # Python config loader (NEW)
├── 📄 config_loader.sh         # Shell config loader (NEW)
├── 📄 debug_logger.py          # Debug logging module
├── 📄 requirements.txt         # Python dependencies
├── 📄 Dockerfile               # Docker build file
├── 📄 run_local.sh             # Local development launcher
│
├── 📄 setup.sh                 # Initial setup wizard
├── 📄 check.sh                 # Status & validation
├── 📄 dbsetup.sh               # Database management
├── 📄 logs.sh                  # Log viewer & analysis
├── 📄 nginx-setup.sh           # Security setup
├── 📄 files.sh                 # File management
├── 📄 poracle.sh               # Poracle setup
├── 📄 fletchling.sh            # Fletchling setup
├── 📄 docker-osm-importer.sh   # OSM data import
│
├── 📄 db_helper.sh             # SQLite operations helper
└── 📄 log_helper.sh            # Logging operations helper
```

### Key File Sizes (for context)
| File | Lines | Notes |
|------|-------|-------|
| shellder_service.py | ~17,000 | Main backend - too large to read fully |
| script.js | ~11,000 | Search for functions before adding |
| style.css | ~8,500 | Uses CSS variables |
| index.html | ~3,200 | Single-page app with tabs |

---

## unown/ Directory (Scanner Configs)

```
unown/
├── 📄 dragonite_config.toml          # Dragonite configuration
├── 📄 dragonite_config-default.toml  # Default template
├── 📄 golbat_config.toml             # Golbat configuration
├── 📄 golbat_config-default.toml     # Default template
├── 📄 rotom_config.json              # Rotom configuration
├── 📄 rotom_config-default.json      # Default template
├── 📄 proxies.txt                    # Proxy list for Xilriws
├── 📁 golbat_cache/                  # Golbat cache data
├── 📁 logs/                          # Container logs
└── 📁 rotom_jobs/                    # Rotom job definitions
    └── main.json                     # Main job config
```

---

## reactmap/ Directory

```
reactmap/
├── 📄 local.json                     # ReactMap configuration
├── 📄 local-default.json             # Default template
└── 📄 env                            # Environment overrides
```

---

## Fletchling Setup (Nest Detection)

Fletchling handles Pokemon nest detection by:
1. Receiving Pokemon spawn data from Golbat via webhook
2. Correlating spawns with park/nature areas from OpenStreetMap
3. Identifying which Pokemon species are "nesting" in each area
4. Providing nest data to ReactMap for display

**Complete Setup Process:**
1. Create geofences in Koji Admin (scanning areas)
2. Enable Fletchling service in docker-compose.yaml
3. Configure `fletchling.toml` with Koji project name
4. **Start containers** (fletchling + fletchling-tools)
5. **Run OSM importer** - This is CRITICAL:
   ```bash
   ./docker-osm-importer.sh "AreaName"
   # OR
   docker compose exec fletchling-tools ./fletchling-osm-importer "AreaName"
   ```
   - Downloads park boundaries from OpenStreetMap
   - Area name MUST match a Koji geofence name exactly
   - Can take several minutes for large areas
6. Add webhook to Golbat config:
   ```toml
   [[webhooks]]
   url = "http://fletchling:9042/webhook"
   types = ["pokemon_iv"]
   ```
7. Restart Golbat to apply webhook

**Data Flow:** `Golbat → webhook → Fletchling → golbat.nests table → ReactMap`

**Key Files:**
- `fletchling.toml` - Main config with Koji URL
- `docker-osm-importer.sh` - Wrapper script for OSM import
- `unown/golbat_config.toml` - Add webhook here

## Poracle/ Directory (Discord/Telegram Alert Bot)

```
Poracle/
├── 📁 config/
│   └── 📄 local.json                 # Main Poracle configuration
│       ├── database.conn             # DB connection (from .env)
│       ├── server.port (3030)        # Webhook receiver port
│       ├── discord                   # Discord bot settings
│       │   ├── enabled               # true/false
│       │   ├── token                 # Bot token (from Developer Portal)
│       │   └── admins                # Admin user IDs
│       └── telegram                  # Telegram bot settings
│           ├── enabled               # true/false
│           ├── token                 # Bot token (from @BotFather)
│           └── admins                # Admin user IDs
└── 📁 geofence/
    ├── 📄 default.json               # Default geofence template
    └── 📄 koji_import.json           # Imported from Koji (auto-generated)
```

**Data Flow:** `Golbat → webhook (port 3030) → Poracle → Discord/Telegram`

**References:**
- [Poracle Wiki](https://muckelba.github.io/poracleWiki/)
- [PoracleJS GitHub](https://github.com/KartulUdus/PoracleJS)

---

## wiki/ Directory

```
wiki/
├── 📄 Home.md                        # Wiki home page
├── 📄 _Sidebar.md                    # Wiki navigation
├── 📄 Architecture.md                # System architecture
├── 📄 Configuration.md               # Config file reference
├── 📄 Device-Setup.md                # Aegis device setup
├── 📄 Installation.md                # Installation guide
├── 📄 Optional-Features.md           # Poracle, Fletchling
├── 📄 Prerequisites.md               # Requirements
├── 📄 Quick-Start.md                 # Quick start guide
├── 📄 Security.md                    # Security setup
├── 📄 Services.md                    # Service descriptions
├── 📄 Shellder.md                    # Shellder documentation
├── 📄 Troubleshooting.md             # Common issues
├── 📄 Xilriws.md                     # Proxy management
└── 📁 images/                        # Wiki images
    └── shellder-dashboard.png
```

---

## Key Configuration Files

| File | Purpose | Format |
|------|---------|--------|
| `.env` | Environment variables (secrets, ports) | Shell env |
| `docker-compose.yaml` | Container definitions | YAML |
| `unown/dragonite_config.toml` | Scanner configuration | TOML |
| `unown/golbat_config.toml` | Data processor config | TOML |
| `unown/rotom_config.json` | Device manager config | JSON |
| `unown/proxies.txt` | Proxy list (one per line) | Text |
| `reactmap/local.json` | Map frontend config | JSON |
| `mysql_data/mariadb.cnf` | MariaDB tuning | INI |
| `init/01.sql` | Database initialization | SQL |

---

## Docker Volumes & Mounts

| Host Path | Container Path | Service | Purpose |
|-----------|----------------|---------|---------|
| `./mysql_data` | `/var/lib/mysql` | database | DB storage |
| `./init` | `/docker-entrypoint-initdb.d` | database | Init scripts |
| `./unown/*_config.*` | `/config/*` | golbat, dragonite | Configs |
| `./unown/proxies.txt` | `/config/proxies.txt` | xilriws | Proxy list |
| `./reactmap/local.json` | `/home/node/server/src/configs/local.json` | reactmap | Config |
| `./` | `/aegis:ro` | shellder | Project root (read-only) |
| `/var/run/docker.sock` | `/var/run/docker.sock:ro` | shellder | Docker API |

---

## Ports Reference

| Port | Service | Purpose | Access |
|------|---------|---------|--------|
| 3306 | MariaDB | Database | Internal only |
| 5000 | Shellder | Web dashboard | Host |
| 5050 | Shellder | AI Debug API | Internal |
| 5090 | Xilriws | Auth proxy | Host |
| 6001 | ReactMap | Map frontend | Host |
| 6002 | Dragonite Admin | Scanner control | Host |
| 6003 | Rotom | Device manager UI | Host |
| 6004 | Koji | Geofence editor | Host |
| 6005 | phpMyAdmin | DB admin | Host |
| 6006 | Grafana | Statistics | Host |
| 7070 | Rotom | Device connections | Host (required) |
| 7071 | Rotom | Controller API | Internal |
| 7272 | Dragonite | Scanner API | Internal |
| 8428 | VictoriaMetrics | Metrics storage | Internal |
| 9001 | Golbat | HTTP API | Internal |
| 50001 | Golbat | gRPC API | Internal |

---

## Files to Never Modify Directly

| File/Directory | Reason |
|----------------|--------|
| `mysql_data/*` | Live database files |
| `*.db` | SQLite databases |
| `node_modules/` | Auto-generated |
| `.venv/` | Python virtual env |
| `*-default.*` | Template files |

---

## Files Safe to Modify

| File | When to Modify |
|------|----------------|
| `.env` | Changing credentials, ports |
| `docker-compose.yaml` | Adding services, changing mounts |
| `unown/*_config.toml` | Scanner settings |
| `reactmap/local.json` | Map settings |
| `Poracle/config/local.json` | Alert settings |
| `unown/proxies.txt` | Adding/removing proxies |

