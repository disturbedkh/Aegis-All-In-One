# Shellder AI Debug API Reference

> Complete REST API documentation for AI assistants to interact with Aegis AIO.

**Base URL:** `http://localhost:5000` (same as web dashboard)  
**Content-Type:** `application/json`

**Remote Access:** Replace `localhost` with server IP (e.g., `http://77.237.241.111:5000`)

---

## Quick Reference

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/ai-debug/help` | GET | API documentation |
| `/api/ai-debug/diagnose` | GET | System diagnostics |
| `/api/ai-debug/system` | GET | System information |
| `/api/ai-debug/config` | GET/POST | API configuration |
| `/api/ai-debug/file` | GET/POST | File read/write |
| `/api/ai-debug/exec` | POST | Execute commands |
| `/api/ai-debug/docker` | GET | Docker operations |
| `/api/ai-debug/sql` | POST | Database queries |
| `/api/ai-debug/logs` | GET | Log retrieval |

---

## Endpoints

### GET /api/ai-debug/help

Get complete API documentation.

**Response:**
```json
{
  "message": "Shellder AI Debug API",
  "version": "1.0",
  "endpoints": [...],
  "tips": [...]
}
```

---

### GET /api/ai-debug/diagnose

Run comprehensive system diagnostics.

**Response:**
```json
{
  "timestamp": "2024-12-05T12:00:00Z",
  "system": {
    "cpu_percent": 25.5,
    "memory_percent": 60.2,
    "disk_percent": 45.0
  },
  "containers": [
    {
      "name": "dragonite",
      "status": "running",
      "cpu": "2.5%",
      "memory": "256MB"
    }
  ],
  "ports": {
    "5000": "open",
    "5090": "open",
    "6001": "open"
  },
  "services": {
    "docker": "active",
    "mariadb": "active"
  }
}
```

---

### GET /api/ai-debug/system

Get detailed system information.

**Response:**
```json
{
  "hostname": "aegis-server",
  "platform": "Linux-5.15.0",
  "cpu_count": 4,
  "memory_total_gb": 16.0,
  "memory_available_gb": 8.5,
  "disk_total_gb": 500.0,
  "disk_free_gb": 300.0,
  "git_branch": "main",
  "git_commit": "abc1234",
  "shellder_version": "1.0.36"
}
```

---

### GET /api/ai-debug/file

Read a file from the Aegis directory.

**Query Parameters:**
| Param | Required | Description |
|-------|----------|-------------|
| `path` | Yes | Relative path from Aegis root |
| `lines` | No | Limit to last N lines |

**Example:**
```
GET /api/ai-debug/file?path=.env
GET /api/ai-debug/file?path=unown/dragonite_config.toml&lines=50
```

**Response:**
```json
{
  "path": ".env",
  "content": "MYSQL_ROOT_PASSWORD=...\n...",
  "lines": 25,
  "size": 1024
}
```

---

### POST /api/ai-debug/file

Write to a file in the Aegis directory.

**Request Body:**
```json
{
  "path": "test.txt",
  "content": "Hello World",
  "append": false
}
```

**Response:**
```json
{
  "success": true,
  "path": "test.txt",
  "bytes_written": 11
}
```

---

### POST /api/ai-debug/exec

Execute a shell command.

**Request Body:**
```json
{
  "cmd": "docker ps",
  "timeout": 30,
  "cwd": "/aegis"
}
```

**Response:**
```json
{
  "stdout": "CONTAINER ID   IMAGE...",
  "stderr": "",
  "returncode": 0,
  "duration": 0.25
}
```

---

### GET /api/ai-debug/docker

Docker operations.

**Query Parameters:**
| Param | Required | Description |
|-------|----------|-------------|
| `cmd` | Yes | ps, logs, inspect, stats, images |
| `container` | Conditional | Required for logs/inspect |
| `lines` | No | Number of log lines |

**Examples:**
```
GET /api/ai-debug/docker?cmd=ps
GET /api/ai-debug/docker?cmd=logs&container=dragonite&lines=100
GET /api/ai-debug/docker?cmd=stats
```

**Response (cmd=ps):**
```json
{
  "containers": [
    {
      "id": "abc123",
      "name": "dragonite",
      "image": "ghcr.io/unownhash/dragonite-public:latest",
      "status": "Up 2 hours",
      "ports": "7272/tcp"
    }
  ]
}
```

---

### POST /api/ai-debug/sql

Execute SQL query on databases.

**Request Body:**
```json
{
  "database": "golbat",
  "query": "SELECT COUNT(*) as count FROM pokemon"
}
```

**Available Databases:**
- `golbat` - Pokemon data, gyms, stops
- `dragonite` - Accounts, workers, scan config
- `reactmap` - Map settings, users
- `koji` - Geofences, projects

**Response:**
```json
{
  "database": "golbat",
  "query": "SELECT COUNT(*) as count FROM pokemon",
  "results": [{"count": 15234}],
  "row_count": 1
}
```

---

### GET /api/ai-debug/logs

Get system logs.

**Query Parameters:**
| Param | Required | Description |
|-------|----------|-------------|
| `type` | Yes | shellder, docker, nginx, system, container |
| `lines` | No | Number of lines (default: 100) |
| `container` | Conditional | Required for type=container |

**Examples:**
```
GET /api/ai-debug/logs?type=shellder&lines=50
GET /api/ai-debug/logs?type=container&container=dragonite&lines=100
```

**Response:**
```json
{
  "type": "shellder",
  "lines": 50,
  "content": "2024-12-05 12:00:00 INFO: Service started...\n..."
}
```

---

### GET /api/ai-debug/config

Get AI debug configuration.

**Response:**
```json
{
  "config": {
    "file_access": true,
    "exec_access": true,
    "docker_access": true,
    "sql_access": true,
    "system_info": true
  },
  "endpoints": {...},
  "port": 5050,
  "aegis_root": "/aegis"
}
```

---

### POST /api/ai-debug/config

Update AI debug configuration.

**Request Body:**
```json
{
  "file_access": true,
  "exec_access": false
}
```

---

## Error Responses

All endpoints return errors in this format:

```json
{
  "error": "Description of error"
}
```

**HTTP Status Codes:**
- `200` - Success
- `400` - Bad request (missing parameters)
- `403` - Access disabled in config
- `404` - Resource not found
- `500` - Server error

---

## Usage Tips

1. **Start with `/api/ai-debug/diagnose`** to understand system state
2. **Check `/api/ai-debug/logs?type=shellder`** for recent errors
3. **Use SQL queries with LIMIT** to prevent large result sets
4. **File paths are relative** to Aegis root directory

---

## cURL Examples

```bash
# Get system diagnostics
curl http://localhost:5050/api/ai-debug/diagnose

# Read a config file
curl "http://localhost:5050/api/ai-debug/file?path=docker-compose.yaml"

# Get container logs
curl "http://localhost:5050/api/ai-debug/docker?cmd=logs&container=dragonite&lines=50"

# Execute SQL query
curl -X POST -H "Content-Type: application/json" \
  -d '{"database":"golbat","query":"SELECT COUNT(*) FROM pokemon"}' \
  http://localhost:5050/api/ai-debug/sql

# Execute shell command
curl -X POST -H "Content-Type: application/json" \
  -d '{"cmd":"docker ps"}' \
  http://localhost:5050/api/ai-debug/exec
```

---

## Related Documentation

- [MCP_SERVER.md](MCP_SERVER.md) - MCP server for Cursor/Claude
- [CONTEXT.md](CONTEXT.md) - Project overview

