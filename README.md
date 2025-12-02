# Aegis AIO 2.0

> A complete, beginner-friendly Docker stack for Pokémon mapping using Aegis and the Unown# ecosystem.

📚 **[Full Documentation on Wiki](../../wiki)** | 🎮 [Pokemod Discord](https://discord.gg/pokemod) | 🔧 [Unown# Discord](https://discord.gg/Vjze47qchG)

---

## Overview

This repository provides a **pre-configured Docker stack** that brings together all the services needed for Pokémon mapping. It's designed as a learning tool to help newcomers understand how the different components interact.

### Stack Components

| Component | Purpose | Port |
|-----------|---------|------|
| **Aegis** | Mobile device client for scanning | - |
| **Dragonite** | Scanner backend & task distribution | 6002 |
| **Golbat** | Data processor & Pokemon tracker | - |
| **Rotom** | Device manager & communication hub | 6003, 7070 |
| **ReactMap** | Beautiful web-based map frontend | 6001 |
| **Koji** | Geofence & area management | 6004 |
| **Xilriws** | Pokemon GO API proxy | 5090 |
| **Fletchling** | Pokemon nest detection | - |
| **Poracle** | Discord & Telegram alerts | 6007 |
| **Grafana** | Performance monitoring | 6006 |
| **MariaDB** | Database for all services | - |
| **Shellder** | 🆕 Web dashboard & management | 5000 |

### Alternative Stack

Looking for Atlas/RDM instead? Check out [Atlas-All-In-One](https://github.com/The-Pokemod-Group/Atlas-All-In-One).

---

## Quick Start

```bash
# Clone repository
git clone https://github.com/The-Pokemod-Group/Aegis-All-In-One.git
cd Aegis-All-In-One

# Launch Shellder control panel
sudo bash ./shellder.sh

# Select 1) Initial Setup and follow prompts
# Then select s) Start Stack
```

Visit **http://localhost:6001** for ReactMap when ready!

📚 **[Detailed Installation Guide →](../../wiki/Installation)**

---

## Shellder - Control Panel & Monitoring

**Shellder** is the unified command center for your Aegis AIO — named after the Pokémon! 🐚

### Three Ways to Manage

| Method | Description | Access |
|--------|-------------|--------|
| **Shell Scripts** | Interactive terminal menus | `sudo bash shellder.sh` |
| **Web Dashboard** | Browser-based control panel | http://localhost:5000 |
| **Docker Service** | Containerized monitoring | `docker compose up -d shellder` |

### Web Dashboard Features

| Feature | Description |
|---------|-------------|
| 📊 **Live Dashboard** | Real-time system stats with sparkline graphs |
| 🐳 **Container Control** | Start/stop/restart with CPU/MEM usage per container |
| 📈 **Metric History** | Click CPU/RAM/Disk for 10m/1h/6h/24h/7d charts |
| 🔧 **System Services** | Docker, MariaDB, Nginx, Python status monitoring |
| 🌐 **Site Availability** | HTTP health checks for all configured sites |
| 📡 **Xilriws Dashboard** | Live proxy stats, success rates, error tracking |
| 📱 **Device Monitor** | Real-time device activity with crash tracking |
| 📁 **File Browser** | View and edit configuration files |
| 📋 **Log Viewer** | Aggregated logs with search capability |
| 🔌 **WebSocket** | Instant updates without page refresh |
| 🤖 **AI Debug Panel** | Live logs, Pull & Restart, version tracking |

### Starting the Dashboard

```bash
# Option 1: With Docker (recommended)
docker compose up -d shellder

# Option 2: Launcher script
./shellderGUI.sh

# Option 3: Via main menu
sudo bash shellder.sh → Select 9) Shellder GUI
```

**Access at:** http://localhost:5000

### Shell Scripts Reference

| Script | Purpose |
|--------|---------|
| `shellder.sh` | Main control panel |
| `Shellder/setup.sh` | Initial setup wizard |
| `Shellder/dbsetup.sh` | Database management |
| `Shellder/check.sh` | Status & validation |
| `Shellder/logs.sh` | Log viewer & analysis |
| `Shellder/nginx-setup.sh` | Security setup |
| `Shellder/files.sh` | File management |

📚 **[Full Shellder Documentation →](../../wiki/Shellder)**

---

## Documentation

All detailed documentation is available on the **[Wiki](../../wiki)**:

| Topic | Description |
|-------|-------------|
| [Prerequisites](../../wiki/Prerequisites) | System requirements |
| [Installation](../../wiki/Installation) | Step-by-step setup |
| [Services](../../wiki/Services) | Service details |
| [Security](../../wiki/Security) | Nginx, SSL, firewall |
| [Configuration](../../wiki/Configuration) | Config files reference |
| [Device Setup](../../wiki/Device-Setup) | Aegis app configuration |
| [Xilriws](../../wiki/Xilriws) | Proxy management |
| [Troubleshooting](../../wiki/Troubleshooting) | Common issues |

---

## Support

| Community | Focus |
|-----------|-------|
| [Unown# Discord](https://discord.gg/Vjze47qchG) | Dragonite, Golbat, Rotom |
| [ReactMap/Koji Discord](https://discord.gg/EYYsKPVawn) | ReactMap, Koji |
| [Pokemod Discord](https://discord.gg/pokemod) | Aegis, General Questions |

---

<p align="center">
  <strong>Aegis All-in-One</strong><br>
  by <a href="https://pokemod.dev/">The Pokemod Group</a>
</p>
