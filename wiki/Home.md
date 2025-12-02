# Welcome to Aegis AIO 2.0

> A complete, beginner-friendly Docker stack for Pokémon mapping using Aegis and the Unown# ecosystem.

---

## 🎯 What is Aegis AIO?

Aegis All-in-One provides a **pre-configured Docker stack** that brings together all the services needed for Pokémon mapping. It's designed as a **learning tool** to help newcomers understand how the different components interact.

---

## 📦 Stack Components

| Component | Purpose | Port |
|-----------|---------|------|
| **Aegis** | Mobile device client for scanning | - |
| **Dragonite** | Scanner backend & task distribution | 6002 |
| **Golbat** | Data processor & Pokemon tracker | - |
| **Rotom** | Device manager & communication hub | 6003, 7070 |
| **ReactMap** | Beautiful web-based map frontend | 6001 |
| **Koji** | Geofence & area management | 6004 |
| **Xilriws** | Pokemon GO API proxy & request handler | 5090 |
| **Fletchling** | Pokemon nest detection & tracking | - |
| **Poracle** | Discord & Telegram alert notifications | 6007 |
| **Grafana** | Performance monitoring & statistics | 6006 |
| **MariaDB** | Database for all services | 3306 |
| **Shellder** | 🆕 Web dashboard, metrics, device monitor & management | 5000 |

---

## 🚀 Quick Links

### Getting Started
- [[Prerequisites]] - System requirements & preparation
- [[Quick-Start]] - Fast path for experienced users
- [[Installation]] - Detailed step-by-step guide

### Management
- [[Shellder]] - **Control panel & monitoring dashboard**
- [[Services]] - Individual service details
- [[Configuration]] - Config files reference

### Advanced
- [[Security]] - Nginx, SSL, firewall setup
- [[Xilriws]] - Proxy management & monitoring
- [[Device-Setup]] - Aegis app configuration

### Reference
- [[Architecture]] - System design & data flow
- [[Optional-Features]] - Poracle, Fletchling, Grafana
- [[Troubleshooting]] - Common issues & solutions

---

## 💡 First Time? Start Here!

```bash
# 1. Clone the repository
git clone https://github.com/The-Pokemod-Group/Aegis-All-In-One.git
cd Aegis-All-In-One

# 2. Launch Shellder control panel
sudo bash ./shellder.sh

# 3. Select option 1) Initial Setup
# 4. Follow the prompts
# 5. Start the stack with option s) Start Stack
```

Visit http://localhost:6001 for ReactMap when ready!

---

## 🔗 Alternative Stack

Looking for Atlas/RDM instead? Check out [Atlas-All-In-One](https://github.com/The-Pokemod-Group/Atlas-All-In-One).

---

## 📞 Support

| Server | Focus |
|--------|-------|
| [Unown# Discord](https://discord.gg/Vjze47qchG) | Dragonite, Golbat, Rotom |
| [ReactMap/Koji Discord](https://discord.gg/EYYsKPVawn) | ReactMap, Koji |
| [Pokemod Discord](https://discord.gg/pokemod) | Aegis, General Questions |

---

<p align="center">
  <strong>Aegis All-in-One</strong><br>
  by <a href="https://pokemod.dev/">The Pokemod Group</a>
</p>

