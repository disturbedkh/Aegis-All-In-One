# Aegis AIO Stack Operation Simulation

This document provides a deep-dive simulation of how every component in the Aegis AIO stack operates, from startup to data flow.

---

## 🐳 Docker Images & Sources

| Service | Image | Source | Update Frequency |
|---------|-------|--------|------------------|
| **database** | `mariadb:latest` | Docker Hub | Stable |
| **dragonite** | `ghcr.io/unownhash/dragonite-public:latest` | GitHub Container Registry | Active development |
| **admin** | `ghcr.io/unownhash/dragonite-public-admin:latest` | GitHub Container Registry | Follows Dragonite |
| **golbat** | `ghcr.io/unownhash/golbat:main` | GitHub Container Registry | Active development |
| **rotom** | `ghcr.io/unownhash/rotom:main` | GitHub Container Registry | Active development |
| **xilriws** | `ghcr.io/unownhash/xilriws:main` | GitHub Container Registry | Active development |
| **reactmap** | `ghcr.io/watwowmap/reactmap:main` | GitHub Container Registry | Active development |
| **koji** | `ghcr.io/turtiesocks/koji:main` | GitHub Container Registry | Active development |
| **grafana** | `grafana/grafana:latest` | Docker Hub | Stable |
| **victoriametrics** | `victoriametrics/victoria-metrics` | Docker Hub | Stable |
| **vmagent** | `victoriametrics/vmagent` | Docker Hub | Stable |
| **pma** | `phpmyadmin:latest` | Docker Hub | Stable |
| **shellder** | `shellder:latest` (local build) | Local Dockerfile | This repo |

---

## 🚀 Startup Sequence Simulation

### Phase 1: Database Initialization

```
STEP 1: docker compose up -d
        │
        ▼
┌─────────────────────────────────────────────────────────────────┐
│ CONTAINER: database (mariadb:latest)                            │
├─────────────────────────────────────────────────────────────────┤
│ 1. Container starts                                             │
│ 2. MariaDB reads environment variables:                         │
│    - MYSQL_ROOT_PASSWORD from .env                              │
│    - MYSQL_USER from .env (default: dbuser)                     │
│    - MYSQL_PASSWORD from .env                                   │
│    - MYSQL_DATABASE = golbat (first DB created)                 │
│ 3. Mounts ./mysql_data/mariadb.cnf for tuning                   │
│ 4. FIRST RUN ONLY: Executes ./init/01.sql                       │
│    → Creates databases: golbat, dragonite, koji, reactmap,      │
│      poracle                                                    │
│    → Creates user with password from 01.sql                     │
│ 5. MariaDB ready on internal port 3306                          │
└─────────────────────────────────────────────────────────────────┘
```

### Phase 2: Core Services Start

```
STEP 2: Services wait for database, then start in parallel
        │
        ├─────────────────────────────┐
        │                             │
        ▼                             ▼
┌──────────────────────┐    ┌──────────────────────┐
│ CONTAINER: golbat    │    │ CONTAINER: koji      │
├──────────────────────┤    ├──────────────────────┤
│ depends_on: database │    │ depends_on: database │
│                      │    │                      │
│ 1. Reads config from │    │ 1. Reads env vars:   │
│    golbat_config.toml│    │    SCANNER_DB_URL    │
│ 2. Connects to DB:   │    │    KOJI_DB_URL       │
│    database:3306     │    │    CONTROLLER_DB_URL │
│ 3. Opens ports:      │    │ 2. Connects to DB    │
│    9001 (HTTP API)   │    │ 3. Serves web UI on  │
│    50001 (gRPC)      │    │    8080 → 6004       │
│ 4. Waits for data    │    └──────────────────────┘
└──────────────────────┘
```

### Phase 3: Scanner Brain & Device Manager

```
STEP 3: Dragonite and Rotom start
        │
        ├─────────────────────────────┐
        │                             │
        ▼                             ▼
┌──────────────────────┐    ┌──────────────────────┐
│ CONTAINER: dragonite │    │ CONTAINER: rotom     │
├──────────────────────┤    ├──────────────────────┤
│ depends_on: golbat   │    │ No depends_on        │
│                      │    │                      │
│ 1. Reads config from │    │ 1. Reads config from │
│    dragonite_config  │    │    rotom_config.json │
│    .toml             │    │ 2. Opens ports:      │
│ 2. Connects to:      │    │    7070 (devices)    │
│    - DB: database    │    │    7071 (controller) │
│      :3306/dragonite │    │    7072 (web UI)     │
│    - Golbat:         │    │       → 6003         │
│      http://golbat   │    │ 3. Waits for devices │
│      :9001           │    │    and Dragonite     │
│    - Golbat gRPC:    │    └──────────────────────┘
│      golbat:50001    │
│    - Koji:           │
│      http://koji:8080│
│    - Rotom:          │
│      ws://rotom:7071 │
│ 3. Opens API on 7272 │
│    (internal only)   │
│ 4. Fetches geofences │
│    from Koji         │
└──────────────────────┘
```

### Phase 4: Authentication & Frontend

```
STEP 4: Xilriws and ReactMap start
        │
        ├─────────────────────────────┐
        │                             │
        ▼                             ▼
┌──────────────────────┐    ┌──────────────────────┐
│ CONTAINER: xilriws   │    │ CONTAINER: reactmap  │
├──────────────────────┤    ├──────────────────────┤
│ No depends_on        │    │ depends_on: database │
│                      │    │                      │
│ 1. Reads proxies from│    │ 1. Reads config from │
│    ./unown/proxies   │    │    reactmap/local    │
│    .txt              │    │    .json             │
│ 2. Opens port 5090   │    │ 2. Runs: yarn start  │
│ 3. Waits for login   │    │ 3. Connects to       │
│    requests from     │    │    database:3306     │
│    Dragonite         │    │    /golbat           │
│ 4. Uses proxies for  │    │ 4. Serves web UI:    │
│    Pokemon GO auth   │    │    8080 → 6001       │
└──────────────────────┘    └──────────────────────┘
```

### Phase 5: Monitoring & Admin

```
STEP 5: Admin, Grafana, Shellder start
        │
        ├──────────────────┬──────────────────┐
        │                  │                  │
        ▼                  ▼                  ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ admin        │  │ grafana      │  │ shellder     │
├──────────────┤  ├──────────────┤  ├──────────────┤
│ depends_on:  │  │ depends_on:  │  │ Builds from  │
│   dragonite  │  │ victoria-    │  │ ./Shellder/  │
│              │  │   metrics    │  │ Dockerfile   │
│ Connects to: │  │              │  │              │
│ - Dragonite  │  │ Serves:      │  │ Mounts:      │
│   :7272      │  │ 3000 → 6006  │  │ - Docker sock│
│ - Golbat     │  │              │  │ - ./:/aegis  │
│   :9001      │  │ Data from:   │  │              │
│              │  │ victoria-    │  │ Serves:      │
│ Serves:      │  │   metrics    │  │ 5000         │
│ 7273 → 6002  │  │   :8428      │  └──────────────┘
└──────────────┘  └──────────────┘
```

---

## 📡 Data Flow Simulation: Scanning Operation

### Step 1: Device Connects

```
┌─────────────┐                    ┌─────────────┐
│   AEGIS     │   WebSocket        │   ROTOM     │
│   PHONE     │ ──────────────────▶│   :7070     │
│             │   Auth Bearer:     │             │
│             │   "SuperSecret..." │             │
└─────────────┘                    └─────────────┘
                                         │
                        Device registered │
                        in Rotom's memory │
                                         ▼
                                   ┌─────────────┐
                                   │ Rotom Web   │
                                   │ UI :6003    │
                                   │ shows device│
                                   └─────────────┘
```

### Step 2: Dragonite Gets Device

```
┌─────────────┐                    ┌─────────────┐
│  DRAGONITE  │   WebSocket        │   ROTOM     │
│             │ ◀─────────────────▶│   :7071     │
│             │   Controller conn  │             │
└─────────────┘                    └─────────────┘
       │
       │ "Device aegis-001 available"
       ▼
┌─────────────────────────────────────────────────┐
│ Dragonite checks:                               │
│ 1. Is device assigned to an area?               │
│ 2. What task type? (Pokemon/Raid/Quest)         │
│ 3. Any accounts available for this worker?      │
└─────────────────────────────────────────────────┘
```

### Step 3: Account Authentication

```
┌─────────────┐                    ┌─────────────┐
│  DRAGONITE  │   HTTP POST        │  XILRIWS    │
│             │ ──────────────────▶│   :5090     │
│             │   /api/v1/login    │             │
│             │   {account, proxy} │             │
└─────────────┘                    └─────────────┘
                                         │
                          Uses proxy to  │
                          contact Niantic│
                                         ▼
                                   ┌─────────────┐
                                   │ Niantic API │
                                   │ Servers     │
                                   └─────────────┘
                                         │
                          Returns cookie │
                          or error       │
                                         ▼
┌─────────────┐                    ┌─────────────┐
│  DRAGONITE  │ ◀──────────────────│  XILRIWS    │
│             │   Auth token/cookie│             │
│             │   or error code    │             │
└─────────────┘                    └─────────────┘
```

### Step 4: Task Assignment

```
┌─────────────┐                    ┌─────────────┐
│  DRAGONITE  │   WebSocket        │   ROTOM     │
│             │ ──────────────────▶│   :7071     │
│             │   Task: {          │             │
│             │     location,      │             │
│             │     action,        │             │
│             │     account_token  │             │
│             │   }                │             │
└─────────────┘                    └─────────────┘
                                         │
                          Forwards to    │
                          device         │
                                         ▼
                                   ┌─────────────┐
                                   │   AEGIS     │
                                   │   PHONE     │
                                   └─────────────┘
```

### Step 5: Scanning Execution

```
┌─────────────┐                    ┌─────────────┐
│   AEGIS     │   Pokemon GO       │   Niantic   │
│   PHONE     │ ──────────────────▶│   Servers   │
│             │   GMO Request      │             │
│             │   (map objects)    │             │
└─────────────┘                    └─────────────┘
                                         │
                          Pokemon, Gyms, │
                          Stops, etc.    │
                                         ▼
┌─────────────┐                    ┌─────────────┐
│   AEGIS     │ ◀──────────────────│   Niantic   │
│   PHONE     │   Raw proto data   │   Servers   │
└─────────────┘                    └─────────────┘
       │
       │ Proto data
       ▼
┌─────────────┐                    ┌─────────────┐
│   ROTOM     │ ◀──────────────────│   AEGIS     │
│   :7070     │   Scan results     │   PHONE     │
└─────────────┘                    └─────────────┘
       │
       │ Forwards via
       │ Dragonite
       ▼
┌─────────────┐                    ┌─────────────┐
│  DRAGONITE  │   HTTP POST        │   GOLBAT    │
│             │ ──────────────────▶│   :9001     │
│             │   /api/pokemon     │   (or gRPC  │
│             │   raw_bearer auth  │    :50001)  │
└─────────────┘                    └─────────────┘
```

### Step 6: Data Processing (Golbat)

```
┌─────────────────────────────────────────────────────────────────┐
│ GOLBAT DATA PROCESSING                                          │
├─────────────────────────────────────────────────────────────────┤
│ 1. Receive raw proto data from Dragonite                        │
│ 2. Decode Pokemon GO protobuf messages                          │
│ 3. For each Pokemon:                                            │
│    a. Calculate Individual Values (IVs)                         │
│    b. Calculate CP                                              │
│    c. Calculate despawn time                                    │
│    d. Calculate PVP rankings (Great/Ultra/Master League)        │
│    e. Determine area/geofence from Koji                         │
│ 4. Store in database (golbat):                                  │
│    - pokemon table                                              │
│    - pokemon_stats table                                        │
│    - gym table                                                  │
│    - pokestop table                                             │
│    - raid table                                                 │
│ 5. Send webhook notifications (if configured):                  │
│    - Poracle for Discord/Telegram alerts                        │
└─────────────────────────────────────────────────────────────────┘
         │
         │ Data stored in MariaDB
         ▼
┌─────────────────────────────────────────────────────────────────┐
│ DATABASE: golbat                                                 │
├─────────────────────────────────────────────────────────────────┤
│ Tables:                                                          │
│   pokemon - Active Pokemon spawns with IVs                       │
│   pokemon_stats - Historical catch statistics                    │
│   gym - Gym locations and team control                           │
│   gym_defender - Pokemon defending gyms                          │
│   pokestop - Pokestop locations and lures                        │
│   raid - Active raids on gyms                                    │
│   quest - Daily research tasks                                   │
│   incident - Team Rocket invasions                               │
│   spawnpoint - Known spawn locations and timers                  │
│   weather - Weather conditions per cell                          │
│   s2cell - S2 geometry cells                                     │
└─────────────────────────────────────────────────────────────────┘
```

### Step 7: Display on Map (ReactMap)

```
┌─────────────┐                    ┌─────────────┐
│  BROWSER    │   HTTP GET         │  REACTMAP   │
│  (User)     │ ──────────────────▶│   :6001     │
│             │   /api/pokemon     │             │
│             │   {bounds, filters}│             │
└─────────────┘                    └─────────────┘
                                         │
                          Query Golbat   │
                          API            │
                                         ▼
                                   ┌─────────────┐
                                   │   GOLBAT    │
                                   │   :9001     │
                                   │   /pokemon  │
                                   └─────────────┘
                                         │
                          SQL Query to   │
                          database       │
                                         ▼
                                   ┌─────────────┐
                                   │  DATABASE   │
                                   │  :3306      │
                                   │  golbat DB  │
                                   └─────────────┘
                                         │
                          Pokemon data   │
                          with IVs       │
                                         ▼
┌─────────────┐                    ┌─────────────┐
│  BROWSER    │ ◀──────────────────│  REACTMAP   │
│  (User)     │   JSON: Pokemon    │             │
│             │   with coords,     │             │
│             │   IVs, despawn     │             │
└─────────────┘                    └─────────────┘
       │
       │ Rendered on
       │ interactive map
       ▼
┌─────────────────────────────────────────────────┐
│ 🗺️ MAP DISPLAY                                   │
│   📍 Pokemon icons at spawn locations           │
│   💪 IV stats on hover/click                    │
│   ⏱️ Despawn timers                              │
│   🏟️ Gyms with raid info                        │
│   🛑 Pokestops with quests                      │
└─────────────────────────────────────────────────┘
```

---

## 📊 Metrics Flow (Grafana)

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  Dragonite  │  │   Golbat    │  │   Rotom     │
│  /metrics   │  │  /metrics   │  │  /metrics   │
└──────┬──────┘  └──────┬──────┘  └──────┬──────┘
       │                │                │
       └────────┬───────┴────────────────┘
                │
                ▼ Prometheus scrape
┌─────────────────────────────────────────────────┐
│ VMAGENT (VictoriaMetrics Agent)                  │
│ Reads prometheus.yml config                      │
│ Scrapes /metrics endpoints every 15s            │
└─────────────────────────────────────────────────┘
                │
                │ Remote write
                ▼
┌─────────────────────────────────────────────────┐
│ VICTORIAMETRICS                                  │
│ Time-series database                             │
│ Stores all metrics history                       │
│ Port 8428 (internal)                             │
└─────────────────────────────────────────────────┘
                │
                │ PromQL queries
                ▼
┌─────────────────────────────────────────────────┐
│ GRAFANA                                          │
│ Dashboards: Dragonite-Emi-v5.json               │
│   - Pokemon caught per hour                      │
│   - Account health status                        │
│   - Device performance                           │
│   - Scanner coverage                             │
│ Port 6006                                        │
└─────────────────────────────────────────────────┘
```

---

## 🔄 Shellder's Role in the Stack

```
┌─────────────────────────────────────────────────────────────────┐
│                           SHELLDER                               │
│                    Shell + Web Dashboard                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ SHELL SCRIPTS (Terminal)                                 │    │
│  │                                                          │    │
│  │  shellder.sh ─────▶ Main control panel                  │    │
│  │       │                                                  │    │
│  │       ├─▶ setup.sh ──────▶ Initial configuration        │    │
│  │       ├─▶ check.sh ──────▶ Validate configs             │    │
│  │       ├─▶ dbsetup.sh ────▶ MariaDB management           │    │
│  │       ├─▶ logs.sh ───────▶ Docker log viewer            │    │
│  │       ├─▶ nginx-setup.sh ▶ Security setup               │    │
│  │       └─▶ files.sh ──────▶ Git/file management          │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ WEB DASHBOARD (Browser - port 5000)                      │    │
│  │                                                          │    │
│  │  shellder_service.py                                     │    │
│  │       │                                                  │    │
│  │       ├─▶ Container Stats (via Docker socket)           │    │
│  │       │     └─ CPU, Memory, Status per container        │    │
│  │       │                                                  │    │
│  │       ├─▶ Xilriws Monitoring                            │    │
│  │       │     ├─ Parse xilriws container logs             │    │
│  │       │     ├─ Track success/failure rates              │    │
│  │       │     └─ Monitor proxy health                     │    │
│  │       │                                                  │    │
│  │       ├─▶ System Resources                              │    │
│  │       │     └─ Memory, Disk, CPU (via psutil)           │    │
│  │       │                                                  │    │
│  │       ├─▶ Port Scanner                                  │    │
│  │       │     └─ Check 5000, 5090, 6001-6006, 7070        │    │
│  │       │                                                  │    │
│  │       ├─▶ System Services                               │    │
│  │       │     └─ nginx, fail2ban, ufw status              │    │
│  │       │                                                  │    │
│  │       ├─▶ SQLite Database (shellder.db)                 │    │
│  │       │     ├─ proxy_stats                              │    │
│  │       │     ├─ error_stats                              │    │
│  │       │     ├─ container_stats                          │    │
│  │       │     ├─ config_values                            │    │
│  │       │     └─ system_events                            │    │
│  │       │                                                  │    │
│  │       └─▶ WebSocket (real-time updates)                 │    │
│  │             └─ Push stats to browser every 5s           │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ INTERNAL HELPERS                                         │    │
│  │                                                          │    │
│  │  db_helper.sh ────▶ SQLite operations                   │    │
│  │       └─ Persist stats across log clears                │    │
│  │                                                          │    │
│  │  log_helper.sh ───▶ Operation logging                   │    │
│  │       └─ Debug Shellder scripts themselves              │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🔐 Secret/Token Flow

```
.env file (source of truth)
    │
    ├── MYSQL_ROOT_PASSWORD ──────▶ database container ENV
    ├── MYSQL_USER ───────────────▶ database, dragonite, golbat, koji
    ├── MYSQL_PASSWORD ───────────▶ database, dragonite, golbat, koji
    ├── DRAGONITE_PASSWORD ───────▶ admin container ENV
    ├── DRAGONITE_API_SECRET ─────▶ admin, dragonite_config.toml
    ├── GOLBAT_API_SECRET ────────▶ admin, golbat_config.toml
    ├── KOJI_SECRET ──────────────▶ koji ENV, dragonite_config.toml, golbat_config.toml
    └── SHELLDER_SECRET ──────────▶ shellder container ENV

Config files derived from .env:
    init/01.sql ──────────────────▶ Creates DB user with MYSQL_PASSWORD
    dragonite_config.toml ────────▶ DB creds, API secrets
    golbat_config.toml ───────────▶ DB creds, API secrets
    rotom_config.json ────────────▶ Device auth bearer
    reactmap/local.json ──────────▶ DB creds, Golbat API secret
```

---

## ⚠️ Error Scenarios & Recovery

### Scenario 1: Xilriws Proxy Failures

```
Problem: All proxies returning errors
Detection: logs.sh Xilriws monitor shows 0% success rate
         │
         ▼
Shellder Actions:
  1. Parse xilriws logs for error patterns
  2. Identify failing proxies
  3. Offer to remove from proxies.txt
  4. Randomize remaining proxies
  5. Restart xilriws container
```

### Scenario 2: Database Connection Lost

```
Problem: Golbat/Dragonite can't connect to MariaDB
Detection: Container logs show "Connection refused"
         │
         ▼
Shellder Actions:
  1. check.sh validates DB connection
  2. dbsetup.sh checks MariaDB status
  3. Verify credentials in .env vs configs
  4. Restart database container if needed
```

### Scenario 3: Device Disconnection

```
Problem: Aegis device loses connection
Detection: Rotom shows device offline
         │
         ▼
Data Flow:
  Rotom ──▶ Dragonite: "Device aegis-001 offline"
  Dragonite: Reassign tasks to other devices
  When device reconnects:
    Rotom ──▶ Dragonite: "Device aegis-001 online"
    Dragonite: Assign new account and tasks
```

---

## 📈 Performance Considerations

| Component | Memory | CPU | Disk I/O | Network |
|-----------|--------|-----|----------|---------|
| MariaDB | High | Medium | Very High | Low |
| Golbat | High (cache) | High (IV calc) | Medium | High |
| Dragonite | Medium | Medium | Low | High |
| Rotom | Low | Low | Low | Medium |
| ReactMap | Medium | Low | Low | Medium |
| Xilriws | Low | Medium | Low | High |
| Shellder | Low | Low | Low | Low |

---

## 🎯 Key Integration Points for Shellder

1. **Docker Socket** (`/var/run/docker.sock`)
   - Container list, stats, logs
   - Start/stop/restart operations

2. **Database** (`database:3306`)
   - Account counts from dragonite DB
   - Pokemon/scan stats from golbat DB

3. **Config Files** (`./:/aegis:ro`)
   - Read .env for credentials
   - Read *.toml, *.json for validation

4. **Log Files**
   - Parse container logs for errors
   - Xilriws logs for proxy stats

5. **SQLite** (`shellder.db`)
   - Persist stats across restarts
   - Track historical data

---

*This simulation document reflects the complete operational flow of Aegis AIO 2.0 with Shellder as the management layer.*

