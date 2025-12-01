# Architecture

System design and data flow.

---

## System Overview

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

## Data Flow

### Scanning Flow

```
1. Device (Aegis) connects to Rotom
           │
           ▼
2. Rotom assigns device to Dragonite
           │
           ▼
3. Dragonite sends scan tasks to device
           │
           ▼
4. Device scans Pokemon GO, reports data
           │
           ▼
5. Golbat processes and stores data
           │
           ▼
6. ReactMap displays on map
```

### Authentication Flow

```
1. Device needs to authenticate
           │
           ▼
2. Request sent to Xilriws
           │
           ▼
3. Xilriws uses proxy to get cookie
           │
           ▼
4. Cookie returned to device
           │
           ▼
5. Device uses cookie for API calls
```

---

## Component Responsibilities

| Component | Input | Output |
|-----------|-------|--------|
| **Aegis** | Scan tasks | Game data |
| **Rotom** | Device connections | Task routing |
| **Dragonite** | Areas, accounts | Scan assignments |
| **Golbat** | Raw game data | Processed data |
| **Xilriws** | Auth requests | Cookies |
| **ReactMap** | Database data | Visual map |
| **Koji** | User drawings | Geofences |
| **Shellder** | User commands | Management actions |

---

## Database Schema

### Main Databases

| Database | Purpose |
|----------|---------|
| `golbat` | Pokemon sightings, gyms, stops |
| `dragonite` | Accounts, workers, scan config |
| `reactmap` | Map settings, user preferences |
| `koji` | Geofences, projects |
| `poracle` | Alert configurations |

### Shellder's SQLite

Separate from MariaDB:
- Proxy statistics
- Error tracking
- Container health
- Config validation

---

## Port Mapping

| Port | Service | Purpose |
|------|---------|---------|
| 3306 | MariaDB | Database (internal) |
| 5000 | Shellder | Web dashboard |
| 5090 | Xilriws | Auth proxy |
| 6001 | ReactMap | Map frontend |
| 6002 | Dragonite | Admin panel |
| 6003 | Rotom | Device manager UI |
| 6004 | Koji | Geofence editor |
| 6005 | phpMyAdmin | DB management |
| 6006 | Grafana | Statistics |
| 7070 | Rotom | Device connections |

---

## Network Architecture

### Internal Network
All containers communicate via Docker network. External access only through exposed ports.

### With Nginx (Recommended)
```
Internet → Nginx (80/443) → Containers (localhost only)
                          ↓
         Devices → Port 7070 (direct, required)
```

---

## File System Layout

```
Aegis-All-In-One/
├── shellder.sh              # Main control panel
├── shellderGUI.sh           # Web dashboard launcher
├── docker-compose.yaml      # Service definitions
├── .env                     # Environment variables
├── Shellder/                # Management scripts
│   ├── *.sh                 # Shell scripts
│   ├── gui_server.py        # Web dashboard
│   ├── shellder.db          # SQLite database
│   └── shellder.log         # Operation log
├── unown/                   # Scanner configs
├── reactmap/                # ReactMap configs
├── mysql_data/              # Database storage
├── grafana/                 # Dashboards
└── Poracle/                 # Alert bot configs
```

---

[[Back to Home|Home]]

