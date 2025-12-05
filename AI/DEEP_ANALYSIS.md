# Shellder Deep Analysis Report
**Date:** December 2024  
**Version:** Post-Debug Analysis v2

---

## 🔍 Executive Summary

This analysis simulates the entire Aegis AIO stack operation at the deepest level, tracing every data flow, identifying issues, and proposing solutions for perfect interoperability.

---

## ✅ Issues Fixed In This Session

| # | Issue | Fix Applied |
|---|-------|-------------|
| 1 | **Duplicate Flask Servers** - `gui_server.py` and `shellder_service.py` both implemented Flask | Deleted `gui_server.py`, consolidated into `shellder_service.py` |
| 2 | **Inconsistent Server Launch** - `shellderGUI.sh` was launching wrong server | Updated to use `shellder_service.py` for both modes |
| 3 | **Operator Precedence Bug** - Line 598: `'tunnel' or 'connect' and 'error'` | Added parentheses: `('tunnel' or 'connect') and 'error'` |
| 4 | **Deprecated File in Dockerfile** - Was copying `gui_server.py` | Updated to copy only `shellder_service.py` |
| 5 | **Missing Xilriws UI** - API existed but no dashboard display | Added Xilriws panel to HTML + JS + CSS |

---

## 🔄 Startup Sequence Simulation

### Docker Compose Startup Trace

```
USER: docker compose up -d
      │
      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ STEP 1: Network Creation                                                     │
│ Docker creates aegis-all-in-one_default network                             │
└─────────────────────────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ STEP 2: Volume Mounting                                                      │
│ All bind mounts verified:                                                    │
│   ./mysql_data → container:/var/lib/mysql                                    │
│   ./init → container:/docker-entrypoint-initdb.d (database only)            │
│   ./unown/* → various configs                                                │
│   ./ → /aegis (shellder only, read-only)                                    │
│   /var/run/docker.sock → container (shellder only)                          │
└─────────────────────────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ STEP 3: Container Start Order (depends_on resolution)                        │
│                                                                              │
│ Phase 1 (No dependencies):                                                   │
│   ├─ database    (MariaDB) ─────────────────────────────────────────────┐   │
│   ├─ rotom       (Device Manager)                                       │   │
│   └─ xilriws     (Auth Bypass)                                          │   │
│                                                                          │   │
│ Phase 2 (depends_on: database):                                   waits ▼   │
│   ├─ golbat      (Data Processor)                                       │   │
│   ├─ koji        (Geofence Manager)                                     │   │
│   ├─ reactmap    (Map Frontend)                                         │   │
│   └─ pma         (phpMyAdmin)                                           │   │
│                                                                              │
│ Phase 3 (depends_on: golbat):                                                │
│   └─ dragonite   (Scanner Brain)                                            │
│                                                                              │
│ Phase 4 (depends_on: dragonite):                                             │
│   ├─ admin       (Dragonite Admin UI)                                       │
│   └─ victoriametrics (Metrics Storage)                                      │
│                                                                              │
│ Phase 5 (depends_on: victoriametrics):                                       │
│   ├─ vmagent     (Metrics Collector)                                        │
│   └─ grafana     (Dashboards)                                               │
│                                                                              │
│ Phase 6 (Independent - builds locally):                                      │
│   └─ shellder    (Control Panel)                                            │
└─────────────────────────────────────────────────────────────────────────────┘
```

### First-Run Database Initialization

```
DATABASE CONTAINER FIRST START:
      │
      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ MariaDB reads environment variables from .env:                               │
│   MYSQL_ROOT_PASSWORD=****                                                   │
│   MYSQL_USER=dbuser                                                          │
│   MYSQL_PASSWORD=****                                                        │
│   MYSQL_DATABASE=golbat (first DB created automatically)                    │
└─────────────────────────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ Entrypoint script detects empty /var/lib/mysql:                              │
│   → Initializes MariaDB data directory                                       │
│   → Creates root user with MYSQL_ROOT_PASSWORD                              │
│   → Executes ./init/01.sql:                                                  │
│       CREATE USER 'dbuser'@'%' IDENTIFIED BY '***';                          │
│       CREATE DATABASE golbat, dragonite, koji, reactmap, poracle;           │
│       GRANT ALL PRIVILEGES...                                                │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 📡 Data Flow: Complete Scan Cycle

### Phase 1: Device Connection

```
PHONE (Aegis App)                          ROTOM Container
       │                                          │
       │ WebSocket Connection                     │
       │ ──────────────────────────────────────▶  │
       │ Headers:                                 │
       │   Authorization: Bearer <secret>         │
       │   Device-ID: aegis-device-001            │
       │                                          │
       │                                          │
       │ ◀──────────────────────────────────────  │
       │ Connection Acknowledged                  │
       │ Worker assigned: aegis-device-001        │
       │                                          │
```

### Phase 2: Task Assignment Chain

```
DRAGONITE                    ROTOM                    KOJI
    │                          │                        │
    │ WebSocket: ws://rotom:7071                        │
    │ ─────────────────────▶   │                        │
    │ "Connect as controller"  │                        │
    │                          │                        │
    │ HTTP: GET /api/v1/geofence/feature-collection/Mapping
    │ ────────────────────────────────────────────────▶ │
    │                                                   │
    │ ◀──────────────────────────────────────────────── │
    │ GeoJSON: {features: [polygons...]}                │
    │                          │                        │
    │ ◀─────────────────────   │                        │
    │ "Device aegis-001 ready" │                        │
    │                          │                        │
    │                          │                        │
    ▼                          ▼                        │
┌─────────────────────────────────────────────────────┐
│ DRAGONITE TASK SCHEDULER                             │
│                                                      │
│ 1. Check available workers (from Rotom)              │
│ 2. Check available accounts (from dragonite DB)     │
│ 3. Calculate next scan location (from Koji areas)    │
│ 4. Assign task to device via Rotom                   │
└─────────────────────────────────────────────────────┘
```

### Phase 3: Authentication via Xilriws

```
DRAGONITE                         XILRIWS                    NIANTIC
    │                                │                           │
    │ HTTP POST /api/v1/login-code   │                           │
    │ ───────────────────────────▶   │                           │
    │ {                              │                           │
    │   "username": "ptc_account",   │                           │
    │   "password": "***",           │ Proxy: socks5://...       │
    │   "proxy": "..."               │ ───────────────────────▶  │
    │ }                              │                           │
    │                                │                           │
    │                                │ ◀───────────────────────  │
    │                                │ Cookie/Token              │
    │ ◀───────────────────────────   │                           │
    │ {                              │                           │
    │   "success": true,             │                           │
    │   "token": "..."               │                           │
    │ }                              │                           │
```

### Phase 4: Scan Execution

```
ROTOM → PHONE (via WebSocket):
{
  "action": "scan",
  "location": {"lat": 40.7128, "lng": -74.0060},
  "account_token": "...",
  "scan_type": "pokemon"
}

PHONE → NIANTIC (via modified client):
  GMO Request (GetMapObjects)
  
NIANTIC → PHONE:
  Protobuf response with Pokemon, Gyms, Stops, Weather, etc.

PHONE → ROTOM → DRAGONITE:
  Raw proto data forwarded

DRAGONITE → GOLBAT:
  HTTP POST /api/pokemon (or gRPC :50001)
  Authorization: Bearer <raw_bearer>
  Body: {pokemon data...}
```

### Phase 5: Data Processing (Golbat)

```
INCOMING DATA                              GOLBAT PROCESSING
       │                                          │
       ▼                                          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ For each Pokemon encounter:                                                  │
│                                                                              │
│ 1. DECODE PROTO                                                              │
│    └─ Extract: encounter_id, pokemon_id, lat, lng, cp, ivs, moves           │
│                                                                              │
│ 2. CALCULATE IVs                                                             │
│    └─ Attack: 0-15, Defense: 0-15, Stamina: 0-15                            │
│    └─ IV%: ((atk + def + sta) / 45) * 100                                   │
│                                                                              │
│ 3. CALCULATE PVP                                                             │
│    └─ Great League rank (CP ≤ 1500)                                         │
│    └─ Ultra League rank (CP ≤ 2500)                                         │
│    └─ Master League rank (no limit)                                         │
│                                                                              │
│ 4. DETERMINE DESPAWN                                                         │
│    └─ Use spawnpoint data to calculate exact despawn time                   │
│                                                                              │
│ 5. STORE IN DATABASE                                                         │
│    └─ INSERT INTO pokemon (id, lat, lon, pokemon_id, cp, iv, ...)          │
│                                                                              │
│ 6. SEND WEBHOOKS (if configured)                                             │
│    └─ POST to Poracle: pokemon, raid, quest, gym data                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Phase 6: Map Display

```
USER BROWSER                    REACTMAP                    GOLBAT
       │                           │                           │
       │ HTTP GET /api/pokemon     │                           │
       │ ───────────────────────▶  │                           │
       │ {bounds: {...}}           │                           │
       │                           │                           │
       │                           │ HTTP GET /api/pokemon     │
       │                           │ ───────────────────────▶  │
       │                           │ {lat, lon, radius}        │
       │                           │                           │
       │                           │ ◀───────────────────────  │
       │                           │ [pokemon array...]        │
       │                           │                           │
       │ ◀───────────────────────  │                           │
       │ {pokemon: [...]}          │                           │
       │                           │                           │
       ▼                           │                           │
  ┌─────────────────────┐          │                           │
  │ LEAFLET MAP RENDER  │          │                           │
  │ Pokemon markers     │          │                           │
  │ Click → IV details  │          │                           │
  │ Timer → despawn     │          │                           │
  └─────────────────────┘          │                           │
```

---

## 🔌 Port & Connectivity Map

```
                          EXTERNAL ACCESS
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        EXPOSED PORTS (Host)                                  │
│                                                                              │
│  5000  → Shellder GUI (Web Dashboard)                                       │
│  5090  → Xilriws (Auth bypass - used by phones)                            │
│  6001  → ReactMap (Map frontend)                                            │
│  6002  → Dragonite Admin (Scanner control)                                  │
│  6003  → Rotom (Device manager web UI)                                      │
│  6004  → Koji (Geofence manager)                                            │
│  6005  → phpMyAdmin (Database admin)                                        │
│  6006  → Grafana (Statistics dashboard)                                     │
│  7070  → Rotom Device Port (Aegis phones connect here)                      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      INTERNAL PORTS (Docker Network Only)                    │
│                                                                              │
│  3306  → MariaDB (database)                                                 │
│  7071  → Rotom Controller (Dragonite → Rotom)                              │
│  7072  → Rotom Web Internal                                                 │
│  7272  → Dragonite API                                                      │
│  8080  → ReactMap/Koji internal                                             │
│  8428  → VictoriaMetrics                                                    │
│  8429  → VMAgent                                                            │
│  9001  → Golbat HTTP API                                                    │
│ 50001  → Golbat gRPC                                                        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 🧠 Shellder Integration Points

### Current Capabilities

| Feature | Implementation | Status |
|---------|---------------|--------|
| Container Stats | Docker socket + `docker-py` | ✅ Working |
| System Resources | `psutil` library | ✅ Working |
| Xilriws Log Parsing | Regex on container logs | ✅ Working |
| Port Scanning | Socket connections | ✅ Working |
| Service Status | `systemctl is-active` | ✅ Working |
| SQLite Database | `sqlite3` module | ✅ Working |
| WebSocket Updates | Flask-SocketIO | ✅ Working |
| File Browser | Path traversal API | ✅ Working |
| Git Operations | subprocess + git CLI | ✅ Working |

### Data Persistence Flow

```
SHELL SCRIPTS (db_helper.sh)          PYTHON SERVICE (shellder_service.py)
           │                                     │
           ▼                                     ▼
      ┌─────────────────────────────────────────────────┐
      │             shellder.db (SQLite)                │
      │                                                 │
      │  proxy_stats      - Xilriws proxy performance  │
      │  error_stats      - Error occurrences          │
      │  container_stats  - Container lifecycle        │
      │  log_summaries    - Daily log metrics          │
      │  system_events    - Audit log                  │
      │  config_values    - Validated configurations   │
      │  config_discrepancies - Config mismatches      │
      └─────────────────────────────────────────────────┘
                          │
                          ▼
               ┌─────────────────────┐
               │   WEB GUI + API     │
               │                     │
               │  /api/db/proxy-stats│
               │  /api/db/error-stats│
               │  /api/db/events     │
               └─────────────────────┘
```

---

## 🎯 Remaining Opportunities & Recommendations

### High Priority

| ID | Opportunity | Benefit |
|----|-------------|---------|
| P1 | **Add Account Stats from Dragonite DB** | Show account health, usage, cooldowns |
| P2 | **Add Scan Coverage Stats from Golbat** | Show Pokemon seen, spawn points, coverage % |
| P3 | **Real-time Alert System** | Push notifications for critical errors |
| P4 | **Proxy Health Monitor** | Auto-disable failing proxies, health scoring |

### Medium Priority

| ID | Opportunity | Benefit |
|----|-------------|---------|
| M1 | **Historical Charts** | Line graphs for success rate over time |
| M2 | **Webhook Test Button** | Test Poracle/other webhook connections |
| M3 | **Config Editor in GUI** | Edit .toml/.json files with validation |
| M4 | **Device Status Page** | Show connected Aegis devices, their status |

### Low Priority / Future

| ID | Opportunity | Benefit |
|----|-------------|---------|
| L1 | **Multi-server Support** | Manage multiple Aegis instances |
| L2 | **Mobile App** | React Native companion app |
| L3 | **AI Error Diagnosis** | Feed errors to AI for troubleshooting |
| L4 | **Automated Recovery** | Auto-restart failed containers |

---

## 🔧 Simulated Error Scenarios

### Scenario 1: Database Connection Failure

```
SYMPTOM: Golbat/Dragonite logs show "Connection refused to database:3306"

SHELLDER DETECTION:
  1. check.sh → Database health check fails
  2. shellder_service.py → Container stats show database "unhealthy"
  3. SQLite logs error event

RECOVERY STEPS:
  1. Verify database container is running
  2. Check MYSQL_PASSWORD in .env matches 01.sql
  3. Check if mysql_data is corrupted
  4. Use dbsetup.sh maintenance mode to repair

SHELLDER ACTIONS:
  ├─ Display alert in GUI dashboard
  ├─ Log to shellder.log with full context
  └─ Offer "Restart Database" button
```

### Scenario 2: Xilriws Proxy Exhaustion

```
SYMPTOM: All logins failing, "auth-banned" errors increasing

SHELLDER DETECTION:
  1. Xilriws log parser sees success rate < 10%
  2. Error stats show auth_banned spike
  3. No successful logins in last hour

RECOVERY STEPS:
  1. Check proxies.txt for valid proxies
  2. Rotate proxy list
  3. Wait 30+ minutes for rate limit reset
  4. Add new proxies

SHELLDER ACTIONS:
  ├─ Show critical warning in Xilriws panel
  ├─ Display proxy health breakdown
  ├─ Offer to view/edit proxies.txt
  └─ Show command to restart xilriws
```

### Scenario 3: Rotom Device Disconnect Storm

```
SYMPTOM: Multiple devices disconnecting/reconnecting rapidly

SHELLDER DETECTION:
  1. Rotom container logs show connect/disconnect spam
  2. Container memory usage spiking
  3. Dragonite unable to assign tasks

POSSIBLE CAUSES:
  ├─ Network instability
  ├─ Rotom out of memory
  └─ Device config issues

SHELLDER ACTIONS:
  ├─ Alert: "Rotom device instability detected"
  ├─ Show device connection count graph
  └─ Offer to restart Rotom with increased memory
```

---

## 📊 Performance Baseline Expectations

| Metric | Normal Range | Warning | Critical |
|--------|--------------|---------|----------|
| Xilriws Success Rate | > 80% | 50-80% | < 50% |
| Database Query Time | < 100ms | 100-500ms | > 500ms |
| Container Memory (Golbat) | < 2GB | 2-4GB | > 4GB |
| Container Memory (Dragonite) | < 1GB | 1-2GB | > 2GB |
| Device Connection Time | < 5s | 5-15s | > 15s |
| Scan Cycle Time | < 30s | 30-60s | > 60s |

---

## 🔒 Security Considerations

### Current State

| Item | Status | Notes |
|------|--------|-------|
| .env Password Storage | ⚠️ Plaintext | Industry standard for Docker, use file permissions |
| API Authentication | ❌ None | GUI is local-only by default |
| Docker Socket Access | ⚠️ Read-only | Shellder has RO access |
| Database Exposure | ✅ Internal | Port 3306 not exposed |
| Nginx SSL | Optional | Configured via nginx-setup.sh |

### Recommendations

1. **Add API Key for Shellder GUI** when exposed externally
2. **Use Docker secrets** for production deployments
3. **Enable fail2ban** for SSH and exposed ports
4. **Regular proxy rotation** to avoid IP bans

---

## 📝 Final Notes

This analysis covers the complete operational flow of Aegis AIO 2.0 with Shellder as the management layer. The system is designed to be:

1. **Self-contained** - All services run in Docker
2. **Observable** - Metrics, logs, and stats are collected
3. **Recoverable** - Config validation and error tracking
4. **User-friendly** - Both terminal (Shellder) and GUI (Web Dashboard)

The integration between shell scripts (`db_helper.sh`, `log_helper.sh`) and the Python service (`shellder_service.py`) provides a unified data layer while allowing flexibility in access methods.

---

## 🔧 Quick Debugging Reference

> Practical solutions from real debugging sessions

### Xilriws Shows 0 for All Stats

**Symptom:** Dashboard/Xilriws tab shows `Code 15: 0`, `Failed: 0` despite logs showing errors.

**Causes & Fixes:**
1. **ANSI color codes in logs** - Docker logs contain escape sequences like `[36m`
   ```python
   # Fix: Strip ANSI before parsing
   ansi_pattern = re.compile(r'\x1b\[[0-9;]*m|\[(?:\d+;)*\d*m')
   clean_line = ansi_pattern.sub('', line)
   ```

2. **Duplicate JavaScript function** - Later function overwrites correct one
   ```javascript
   // Search for function name across ENTIRE file
   // If two `updateXilriwsPage` exist, the LAST one wins
   ```

3. **Wrong field names** - API returns `browser_bot_protection`, code expects `code_15`
   ```javascript
   // Check actual API response in DevTools Network tab
   // Use: data.browser_bot_protection (not data.code_15)
   ```

### Metrics Charts Not Showing Full History

**Symptom:** 24h/7d charts only show recent hours, not full period.

**Fixes:**
1. **Remove LIMIT from SQL** - Fixed query was limiting to 500 rows regardless of time range
2. **Use downsampling with ROW_NUMBER()** - Evenly distribute points across entire range
3. **Set SQLite busy_timeout** - Prevents lock failures during concurrent read/write

### Config Editor Shows Default Values

**Symptom:** Editor shows "dbuser" instead of actual "pokemap" from config file.

**Fixes:**
1. **TOML parsing fallback** - Ensure `parse_simple_toml()` is called when `tomli` unavailable
2. **Nested section navigation** - Access `values.db.dragonite.user`, not `values['db.dragonite'].user`
3. **collectFormValues()** - Must create nested objects, not flat keys

### Docker Start Button Fails

**Symptom:** "Start all containers" fails with port conflict errors.

**Fix:** Check if host Shellder is running on port 5000, exclude `shellder` container from `docker compose up` command. Use `--no-recreate` flag.

### File Edit/Rename Buttons Don't Work

**Symptom:** Clicking Edit or Rename does nothing.

**Cause:** Special characters in file paths break inline `onclick` handlers.

**Fix:** Base64 encode paths in onclick attributes:
```javascript
// Encode
const encoded = btoa(unescape(encodeURIComponent(path)));
// Decode
const decoded = decodeURIComponent(escape(atob(encoded)));
```

### Database Locking Errors

**Symptom:** "database is locked" errors when viewing metrics.

**Fix:** Configure SQLite properly:
```python
conn = sqlite3.connect(db_path, timeout=5.0)  # 5 second timeout
conn.execute("PRAGMA busy_timeout = 5000")
conn.execute("PRAGMA journal_mode = WAL")
```

### Using AI Debug API from Remote Machine

```bash
# From Windows Cursor to Linux server at 77.237.241.111
curl http://77.237.241.111:5000/api/ai-debug/diagnose

# PowerShell example
$response = Invoke-WebRequest -Uri "http://77.237.241.111:5000/api/ai-debug/diagnose"
$response.Content | ConvertFrom-Json
```

---

*Analysis generated by simulating complete stack operation and tracing all data flows.*

