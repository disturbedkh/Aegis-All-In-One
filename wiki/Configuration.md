# Configuration

Configuration files and settings reference.

---

## Configuration Files

| File | Purpose |
|------|---------|
| `.env` | Main environment variables |
| `reactmap/local.json` | ReactMap configuration |
| `unown/dragonite_config.toml` | Dragonite settings |
| `unown/golbat_config.toml` | Golbat settings |
| `unown/rotom_config.json` | Rotom settings |
| `fletchling.toml` | Fletchling settings |
| `Poracle/config/local.json` | Poracle alerts |
| `docker-compose.yaml` | Docker service definitions |

---

## Validating Configuration

Run the configuration checker:

```bash
sudo bash ./Shellder/check.sh
```

### Menu Options:
1. **Status Dashboard** - Quick health overview
2. **Full Configuration Check** - Detailed validation
3. **Docker & Container Status** - Container health
4. **Configuration Alignment** - Password/secret matching
5. **File & Endpoint Check** - Files and endpoints
6. **Port Status** - Port usage

### Command Line:
```bash
./Shellder/check.sh -d    # Dashboard only
./Shellder/check.sh -f    # Full check
./Shellder/check.sh -q    # Quick (non-interactive)
```

### What It Validates:
- ✅ Environment variables consistency
- ✅ Database password matching
- ✅ API secrets configuration
- ✅ Docker/Compose running
- ✅ Container health
- ✅ Required files exist
- ✅ Service endpoints
- ✅ User permissions
- ✅ Port availability

---

## Database Management

```bash
sudo bash ./Shellder/dbsetup.sh
```

### Setup Mode:
- Install MariaDB
- Detect resources and tune settings
- Create databases (dragonite, golbat, reactmap, koji, poracle)
- Create users with permissions

### Maintenance Mode:

| Category | Features |
|----------|----------|
| **Status** | Server status, DB sizes, accounts |
| **Account Cleanup** | Remove banned/invalid accounts |
| **Map Data Cleanup** | Remove stale data |
| **Nest Management** | Label/delete unknown nests |
| **Database/Users** | Create missing DBs, fix permissions |
| **Maintenance** | Optimize, analyze, repair tables |

---

## Environment Variables (.env)

Key variables set during setup:

```bash
# Database
MYSQL_ROOT_PASSWORD=
MYSQL_USER=
MYSQL_PASSWORD=
MYSQL_DATABASE=

# User IDs (for file permissions)
PUID=
PGID=

# API Keys
DRAGONITE_SECRET=
GOLBAT_API_SECRET=
ROTOM_AUTH_BEARER=
KOJI_SECRET=

# Shellder
SHELLDER_SECRET=
```

---

## Modifying Configurations

### Via Shellder
Most settings can be changed through Shellder scripts without editing files directly.

### Manual Editing
```bash
nano .env                              # Main environment
nano unown/dragonite_config.toml       # Dragonite
nano unown/golbat_config.toml          # Golbat
nano unown/rotom_config.json           # Rotom
```

After editing, restart affected services:
```bash
docker compose restart <service_name>
```

---

## File Permissions

The setup script automatically fixes ownership. If needed:

```bash
# Fix all Shellder files
sudo chown -R $USER:$USER .

# Make scripts executable
chmod +x shellder.sh shellderGUI.sh
chmod +x Shellder/*.sh
```

---

[[← Security|Security]] | [[Next: Device Setup →|Device-Setup]]

