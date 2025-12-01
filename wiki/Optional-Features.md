# Optional Features

Additional services you can enable for enhanced functionality.

---

## Poracle - Discord/Telegram Alerts

Send Pokemon spawn, raid, and quest notifications.

### Setup

```bash
sudo bash ./Shellder/poracle.sh
```

### What It Does
- Guides through Discord/Telegram bot creation
- Configures webhook from Golbat
- Sets up notification filters and geofences

### Prerequisites
- Running Golbat with webhook support

### Documentation
📚 [Poracle GitHub](https://github.com/KartulUdus/PoracleJS)

---

## Fletchling - Pokemon Nests

Display Pokemon nests on ReactMap.

### Prerequisites
Create a project with geofences in Koji first!

### Setup

```bash
sudo bash ./Shellder/fletchling.sh
```

### What It Does
- Configures Fletchling with your Koji project
- Imports park data from OpenStreetMap
- Enables automatic nest detection
- Integrates with ReactMap

### Documentation
📚 [Fletchling GitHub](https://github.com/UnownHash/Fletchling)

---

## OpenStreetMap Import

Import park boundaries for nest detection.

```bash
sudo bash ./Shellder/docker-osm-importer.sh
```

Downloads and imports:
- Park boundaries
- Natural area boundaries
- Data for Fletchling

---

## Grafana Dashboards

Comprehensive performance monitoring.

### Initial Setup

1. Login to Grafana: http://localhost:6006
   - Default: `admin` / `admin`
   - **Change password immediately!**

2. Add data source:
   - Settings → Data Sources → Add
   - Select **Prometheus**
   - URL: `http://victoriametrics:8428`

3. Import dashboard:
   - Dashboards → Import
   - Upload `grafana/Dragonite-Emi-v5.json`

### What You Get
- Real-time statistics dashboards
- Pokemon catch rates
- Device performance metrics
- Historical data analysis

---

## Enabling Optional Services

Services are defined in `docker-compose.yaml` but commented out.

### Poracle
Uncomment the `poracle` section in docker-compose.yaml after running the setup script.

### Fletchling
Uncomment the `fletchling` and optionally `fletchling-tools` sections.

### Example
```yaml
# Before (commented)
# poracle:
#   image: ghcr.io/kartuludus/poraclejs:develop

# After (enabled)
poracle:
  image: ghcr.io/kartuludus/poraclejs:develop
```

Then restart:
```bash
docker compose up -d
```

---

[[← Xilriws|Xilriws]] | [[Next: Troubleshooting →|Troubleshooting]]

