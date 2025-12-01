# Quick Start

For experienced users, here's the fastest path to a running system.

---

## One-Liner Start

```bash
git clone https://github.com/The-Pokemod-Group/Aegis-All-In-One.git && \
cd Aegis-All-In-One && \
sudo bash ./shellder.sh
```

---

## Step-by-Step

### 1. Clone Repository

```bash
git clone https://github.com/The-Pokemod-Group/Aegis-All-In-One.git
cd Aegis-All-In-One
```

### 2. Run Setup

```bash
sudo bash ./Shellder/setup.sh
```

This will:
- ✅ Install Docker if needed
- ✅ Configure Docker log rotation
- ✅ Check port availability
- ✅ Generate secure passwords
- ✅ Create configuration files
- ✅ Set up MariaDB
- ✅ Create databases

### 3. Start Stack

```bash
docker compose up -d
```

### 4. Access Services

| Service | URL |
|---------|-----|
| ReactMap | http://localhost:6001 |
| Dragonite Admin | http://localhost:6002 |
| Rotom | http://localhost:6003 |
| Koji | http://localhost:6004 |
| phpMyAdmin | http://localhost:6005 |
| Grafana | http://localhost:6006 |
| Shellder GUI | http://localhost:5000 |

### 5. (Optional) Security Setup

```bash
sudo bash ./Shellder/nginx-setup.sh
```

---

## Using Shellder Control Panel

Instead of running individual commands, use the unified control panel:

```bash
sudo bash ./shellder.sh
```

**Main Menu Options:**
- `1` Initial Setup
- `2` Database Management
- `3` Security Setup
- `4` System Check
- `5` Log Manager
- `9` Web Dashboard (Shellder GUI)
- `s` Start Stack
- `x` Stop Stack
- `t` Restart Stack

---

## Command-Line Shortcuts

```bash
./shellder.sh --start      # Start all containers
./shellder.sh --stop       # Stop all containers
./shellder.sh --restart    # Restart all containers
./shellder.sh --status     # View status dashboard
./shellder.sh --pull       # Pull latest images
./shellder.sh --help       # See all options
```

---

## Getting Started Checklist

After installation:

- [ ] Add accounts to Dragonite
- [ ] Create a project in Koji (draw geofences)
- [ ] Sync Koji with Dragonite
- [ ] Sync Koji with ReactMap
- [ ] Connect your first device
- [ ] Start mapping!

---

[[← Prerequisites|Prerequisites]] | [[Detailed Installation →|Installation]]

