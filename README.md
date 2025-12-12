# Aegis AIO 2.0

> A complete, beginner-friendly Docker stack for Pokémon mapping using Aegis and the Unown# ecosystem.

📚 **[Full Documentation on Wiki](../../wiki)** | 🎮 [Pokemod Discord](https://discord.gg/pokemod) | 🔧 [Unown# Discord](https://discord.gg/Vjze47qchG)

---

## What's New in AIO 2.0?

Aegis AIO 2.0 is a complete reimagining of the original stack, centered around **Shellder** — the new unified control panel.

| Feature | AIO 1.x | AIO 2.0 (Shellder) |
|---------|---------|-------------------|
| **Setup** | Manual config editing | Guided setup wizard in browser |
| **Management** | SSH + command line | Web dashboard at port 5000 |
| **Monitoring** | Check individual containers | Real-time dashboard with metrics |
| **Grafana** | Separate manual setup | Integrated with auto-provisioning |
| **Logs** | `docker logs` commands | Multi-container viewer with search |
| **Updates** | Manual `git pull` | One-click in Setup & Config |
| **Config Editing** | SSH + text editor | Browser-based editor with validation |
| **Security Setup** | Manual nginx/certbot | Guided 6-step wizard |
| **Database Setup** | Manual SQL commands | Auto-setup with optimization |
| **File Permissions** | Manual chown commands | Auto-detected and fixed |

**Bottom line:** If you used AIO 1.x, you'll find AIO 2.0 does everything through a friendly web interface instead of SSH commands.

---

## Stack Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     SHELLDER (Port 5000)                        │
│         Web Dashboard • Setup Wizard • Monitoring               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  SCANNING          DATA              FRONTEND                   │
│  ─────────         ────              ────────                   │
│  Rotom (6003)  →   Golbat      →     ReactMap (6001)           │
│  Dragonite    →   MariaDB     →     Koji (6004)                │
│  Xilriws (5090)                      Grafana (6006)             │
│                                                                 │
│  OPTIONAL                                                       │
│  ────────                                                       │
│  Fletchling (nests) • Poracle (alerts)                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

| Component | Purpose | Web UI |
|-----------|---------|--------|
| **Shellder** | Control panel & monitoring | ✅ Port 5000 |
| **ReactMap** | Map frontend | ✅ Port 6001 |
| **Admin** | Dragonite management UI | ✅ Port 6002 |
| **Rotom** | Device manager | ✅ Port 6003 |
| **Koji** | Geofence editor | ✅ Port 6004 |
| **phpMyAdmin** | Database admin | ✅ Port 6005 |
| **Grafana** | Metrics dashboards | ✅ Port 6006 |
| **Dragonite** | Scanner backend | ❌ API only |
| **Golbat** | Data processor | ❌ API only |
| **Xilriws** | Auth proxy | ❌ API only |

---

## Quick Start

```bash
# Clone repository
git clone https://github.com/The-Pokemod-Group/Aegis-All-In-One.git
cd Aegis-All-In-One

# Launch Shellder GUI
./shellderGUI.sh

# Or use terminal menu
sudo bash ./shellder.sh
```

Then open **http://localhost:5000** and follow the Setup Wizard:

1. ✅ Check Docker & Compose
2. ✅ Verify ports are free
3. ✅ Detect system resources
4. ✅ Copy config templates
5. ✅ Generate secure passwords
6. ✅ Setup MariaDB
7. 🚀 Start Stack

> 💡 **Zero Config Required:** Shellder auto-detects your user ID, fixes Docker permissions, and generates secure passwords. Just click through the wizard!

📚 **[Detailed Installation Guide →](../../wiki/Installation)**

---

## Shellder Features

### Setup & Config
- **Step-by-step wizard** - No command line needed
- **Auto-resource detection** - CPU, RAM, storage
- **Password generator** - Secure random credentials
- **Config file editor** - Edit TOML/JSON in browser
- **GitHub manager** - Pull updates with one click

### Monitoring
- **Live dashboard** - CPU, RAM, disk with sparklines
- **Container status** - Start/stop/restart any container
- **Grafana integration** - Full-page metrics dashboard
- **Log viewer** - Multi-container with filters

### Management
- **File browser** - Upload, edit, manage permissions
- **Database setup** - Auto-create and optimize MariaDB
- **Security wizard** - Nginx, SSL, firewall, auth
- **Fletchling setup** - Nest detection configuration
- **Poracle setup** - Discord/Telegram alerts

---

## Documentation

All detailed documentation is on the **[Wiki](../../wiki)**:

| Topic | Description |
|-------|-------------|
| [Quick Start](../../wiki/Quick-Start) | Fast setup guide |
| [Installation](../../wiki/Installation) | Detailed walkthrough |
| [Shellder](../../wiki/Shellder) | Control panel guide |
| [Security](../../wiki/Security) | Nginx, SSL, firewall |
| [Troubleshooting](../../wiki/Troubleshooting) | Common issues |

---

## Alternative Stack

Looking for Atlas/RDM instead? Check out [Atlas-All-In-One](https://github.com/The-Pokemod-Group/Atlas-All-In-One).

---

## Support

| Community | Focus |
|-----------|-------|
| [Unown# Discord](https://discord.gg/Vjze47qchG) | Dragonite, Golbat, Rotom |
| [ReactMap/Koji Discord](https://discord.gg/EYYsKPVawn) | ReactMap, Koji |
| [Pokemod Discord](https://discord.gg/pokemod) | Aegis, General Questions |

---

<p align="center">
  <strong>Aegis All-in-One 2.0</strong><br>
  Powered by <strong>Shellder</strong> 🐚<br>
  by <a href="https://pokemod.dev/">The Pokemod Group</a>
</p>
