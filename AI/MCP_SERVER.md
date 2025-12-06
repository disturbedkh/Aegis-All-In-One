# Shellder MCP Server Documentation

> Model Context Protocol (MCP) server providing AI assistants with direct access to Aegis AIO debugging tools.

---

## Overview

The Shellder MCP Server (`Shellder/mcp-server/`) allows AI assistants (Cursor, Claude, etc.) to interact directly with your Aegis AIO infrastructure through a standardized protocol.

**Location:** `Shellder/mcp-server/`  
**Backend:** Shellder Service at `http://localhost:5000` (or remote server IP)  
**Protocol:** Model Context Protocol (MCP) via stdio

> **Note:** The MCP server connects to Shellder's web dashboard port (5000), not a separate port.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        AI ASSISTANT                              │
│               (Cursor, Claude Desktop, etc.)                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ MCP Protocol (stdio)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    SHELLDER MCP SERVER                           │
│                  (Shellder/mcp-server/)                          │
│                                                                  │
│   Tools: diagnose, read_file, write_file, exec, docker,         │
│          sql, logs, system, help                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ HTTP REST API
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    SHELLDER SERVICE                              │
│              (shellder_service.py on port 5050)                  │
│                                                                  │
│   /api/ai-debug/* endpoints                                      │
│   Docker socket access, file system, database connections        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     AEGIS AIO STACK                              │
│    Containers, Databases, Config Files, Logs                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## Installation

### Prerequisites
- Node.js 18+ installed
- Shellder service running (port 5050)

### Setup

```bash
# 1. Install dependencies
cd Shellder/mcp-server
npm install

# 2. Test the server
node index.js
# Should output: "Shellder MCP Server running"
```

### Cursor Configuration

**Windows:** `%APPDATA%\Cursor\User\globalStorage\cursor.mcp\mcp.json`  
**Mac/Linux:** `~/.cursor/mcp.json` or equivalent

**Local Development (Shellder on same machine):**
```json
{
  "mcpServers": {
    "shellder": {
      "command": "node",
      "args": ["C:\\path\\to\\Aegis-All-In-One\\Shellder\\mcp-server\\index.js"],
      "env": {
        "SHELLDER_URL": "http://localhost:5000"
      }
    }
  }
}
```

**Remote Server (Cursor on Windows, Shellder on Linux):**
```json
{
  "mcpServers": {
    "shellder": {
      "command": "node",
      "args": ["C:\\Users\\khutt\\Aegis-All-In-One\\Shellder\\mcp-server\\index.js"],
      "env": {
        "SHELLDER_URL": "http://<your-server-ip>:5000"
      }
    }
  }
}
```

**Important:** 
- Restart Cursor after creating/modifying this file
- Port is **5000** (same as web dashboard), not 5050
- For remote servers, ensure port 5000 is open in firewall

---

## Available Tools

### `shellder_diagnose`
Run comprehensive system diagnostics.

**Returns:** CPU, memory, disk usage, container status, port availability, service health.

**Use when:** Starting a debugging session, checking overall system health.

---

### `shellder_read_file`
Read files from the Aegis directory.

**Parameters:**
| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `path` | string | Yes | Relative path from Aegis root |
| `lines` | number | No | Limit to last N lines |

**Examples:**
```
path: ".env"
path: "docker-compose.yaml"
path: "unown/dragonite_config.toml"
```

---

### `shellder_write_file`
Write content to files in the Aegis directory.

**Parameters:**
| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `path` | string | Yes | Relative path from Aegis root |
| `content` | string | Yes | File content to write |
| `append` | boolean | No | Append instead of overwrite |

---

### `shellder_exec`
Execute shell commands on the Aegis server.

**Parameters:**
| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `cmd` | string | Yes | Shell command to execute |
| `timeout` | number | No | Timeout in seconds (default: 30) |

**Returns:** stdout, stderr, return code

---

### `shellder_docker`
Docker operations.

**Parameters:**
| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `cmd` | string | Yes | Command: ps, logs, inspect, stats, images |
| `container` | string | Conditional | Container name (required for logs/inspect) |
| `lines` | number | No | Number of log lines (default: 100) |

**Commands:**
- `ps` - List all containers with status
- `logs` - Get container logs (requires `container`)
- `inspect` - Get container details (requires `container`)
- `stats` - Get resource statistics
- `images` - List Docker images

---

### `shellder_sql`
Execute SQL queries on MariaDB databases.

**Parameters:**
| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `database` | string | Yes | golbat, dragonite, reactmap, or koji |
| `query` | string | Yes | SQL query to execute |

**Note:** Read-only queries recommended for safety.

**Examples:**
```sql
-- Count active Pokemon
database: golbat
query: SELECT COUNT(*) FROM pokemon WHERE expire_timestamp > UNIX_TIMESTAMP()

-- Check account status
database: dragonite
query: SELECT username, level, banned FROM pokemon_account LIMIT 10
```

---

### `shellder_logs`
Get system logs.

**Parameters:**
| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | Yes | Log type (see below) |
| `lines` | number | No | Number of lines (default: 100) |
| `container` | string | Conditional | Container name (for type: container) |

**Log types:**
- `shellder` - Shellder service logs
- `docker` - Docker daemon logs
- `nginx` - Nginx access/error logs
- `system` - System journal logs
- `container` - Specific container logs (requires `container` param)

---

### `shellder_system`
Get detailed system information.

**Returns:**
- Hostname and platform
- CPU count and model
- Memory total/available
- Disk usage
- Git status (branch, commit)
- Shellder version

---

### `shellder_help`
Get complete API documentation.

**Returns:** Full documentation of all endpoints with examples.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SHELLDER_URL` | `http://localhost:5050` | URL of Shellder service |

---

## Troubleshooting

### MCP server not connecting

1. **Check Shellder service is running:**
   ```bash
   curl http://localhost:5050/api/ai-debug/help
   ```

2. **Check Node.js is installed:**
   ```bash
   node --version
   ```

3. **Check dependencies installed:**
   ```bash
   cd Shellder/mcp-server && npm install
   ```

4. **Restart Cursor** after config changes

### Tools returning errors

1. **Check SHELLDER_URL** points to correct host/port
2. **Verify Docker is running** for Docker-related tools
3. **Check file permissions** for file operations

---

## Security Considerations

- MCP server runs locally with your permissions
- Shellder service has Docker socket access
- SQL queries should be read-only in production
- File write operations affect live configs

---

## Related Documentation

- [AI_DEBUG_API.md](AI_DEBUG_API.md) - Full REST API reference
- [DEEP_ANALYSIS.md](DEEP_ANALYSIS.md) - System analysis
- [STACK_SIMULATION.md](STACK_SIMULATION.md) - Data flow simulation

