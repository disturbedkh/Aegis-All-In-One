# Prerequisites

System requirements and preparation for Aegis AIO.

---

## System Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| **OS** | Linux (Ubuntu 20.04+) | Ubuntu 22.04+ or Debian 12+ |
| **RAM** | 8GB | 16GB+ |
| **Storage** | 30GB | 50GB+ SSD |
| **CPU** | 4 cores | 8+ cores |

> ⚠️ **Note**: While Docker runs on Windows/macOS, this AIO is designed and tested for **Linux only**.

---

## Required Software

1. **Docker Engine** (version 20.10+)
2. **Docker Compose Plugin** (v2)

> 💡 **Tip**: The setup script (`setup.sh`) can automatically install Docker and add your user to the docker group!

---

## Install Docker Manually (Optional)

```bash
# Ubuntu/Debian
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Log out and back in for group changes
```

---

## Docker Logging Configuration

Docker can generate massive log files. The setup script automatically configures log rotation:

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3",
    "compress": "true"
  }
}
```

This limits logs to 300MB total (3 × 100MB) with automatic rotation and compression.

---

## Database Compatibility

This stack uses **MariaDB 12.x** (latest). Configuration has been optimized for MariaDB 12+ with deprecated options removed.

---

## Network Requirements

### Ports Used

| Port | Service | Access |
|------|---------|--------|
| 6001 | ReactMap | Web UI |
| 6002 | Dragonite Admin | Web UI |
| 6003 | Rotom | Web UI |
| 6004 | Koji | Web UI |
| 6005 | phpMyAdmin | Web UI |
| 6006 | Grafana | Web UI |
| 7070 | Rotom Devices | Device connections |
| 5090 | Xilriws | API proxy |
| 5000 | Shellder GUI | Dashboard |

### Firewall

If using UFW, the security script will configure it automatically. Manual setup:

```bash
sudo ufw allow 7070/tcp  # Device connections (required)
sudo ufw allow 80/tcp    # HTTP (for SSL setup)
sudo ufw allow 443/tcp   # HTTPS
```

---

[[← Back to Home|Home]] | [[Next: Quick Start →|Quick-Start]]

