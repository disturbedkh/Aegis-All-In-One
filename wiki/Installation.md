# Installation

Detailed step-by-step installation guide.

---

## Step 1: Clone the Repository

```bash
git clone https://github.com/The-Pokemod-Group/Aegis-All-In-One.git
cd Aegis-All-In-One
```

---

## Step 2: Run the Setup Script

```bash
sudo bash ./Shellder/setup.sh
```

### What the Setup Script Does

- ✅ Checks and installs Docker if needed
- ✅ Adds your user to the docker group
- ✅ Configures Docker log rotation
- ✅ **Checks port availability** (6001-6006, 7070, 5090) with remediation
- ✅ Detects system resources (RAM, CPU, storage)
- ✅ Generates secure random passwords
- ✅ Creates configuration files from templates
- ✅ Tunes MariaDB for your hardware
- ✅ Creates required databases and users
- ✅ Sets up inter-service communication
- ✅ Restores file ownership to non-root user

### Setup Prompts

You'll be asked to customize:
- Database usernames and passwords
- API secrets and bearer tokens
- Service-specific settings

---

## Step 3: Start the Stack

```bash
docker compose up -d --force-recreate --build
```

> 💡 Add `sudo` if not in docker group yet. First startup may take several minutes.

---

## Step 4: Verify Services

```bash
docker compose ps
```

All services should show `Up` status. Check logs if needed:

```bash
docker logs <container_name>
```

> 📝 Some initial errors are normal (e.g., Koji needs projects before Dragonite syncs).

---

## Step 5: Access Web Interfaces

| Service | URL | Default Credentials |
|---------|-----|---------------------|
| ReactMap | http://localhost:6001 | None required |
| Dragonite Admin | http://localhost:6002 | Set in setup |
| Rotom | http://localhost:6003 | None required |
| Koji | http://localhost:6004 | None required |
| phpMyAdmin | http://localhost:6005 | DB credentials |
| Grafana | http://localhost:6006 | admin / admin |
| Shellder GUI | http://localhost:5000 | None required |

> ⚠️ **Change Grafana's default password immediately!**

---

## Step 6: (Optional) Security Setup

For external access:

```bash
sudo bash ./Shellder/nginx-setup.sh
```

See [[Security]] for details.

---

## Updating

### Via Shellder

```bash
sudo bash ./shellder.sh
# Select p) Pull Latest
```

### Via Git

```bash
git pull
docker compose up -d --force-recreate --build
```

Your configuration files are automatically preserved during updates.

---

[[← Quick Start|Quick-Start]] | [[Next: Services →|Services]]

