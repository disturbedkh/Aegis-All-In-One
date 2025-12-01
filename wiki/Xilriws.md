# Xilriws Operation

Xilriws handles Pokemon GO authentication requests. Proper proxy management is essential.

---

## Accessing Xilriws Management

```bash
# Via Shellder
sudo bash ./shellder.sh
# Select 5) Log Manager, then press 'x'

# Or directly
sudo bash ./Shellder/logs.sh -x
```

---

## Status Dashboard

| Metric | Description |
|--------|-------------|
| **Successful Logins** | Accounts with cookies obtained |
| **Auth-Banned** | Accounts flagged as banned |
| **Invalid Credentials** | Wrong password/username |
| **Tunneling Errors** | Proxy tunnel failures |
| **Code 15 Errors** | API error responses |
| **Rate Limited** | Blocked requests |
| **Timeouts** | Connection timeouts |
| **Connection Refused** | Proxy connection failures |
| **Proxy Errors** | General proxy failures |
| **Permanently Banned** | Flagged IPs |
| **Success Rate** | Percentage successful |

---

## Menu Options

| Option | Key | Description |
|--------|-----|-------------|
| View Recent Errors | `1` | Last 50 error entries |
| Live Monitoring | `2` | Real-time stats, auto-restart |
| Clear Logs | `3` | Truncate logs |
| Restart Container | `4` | Restart Xilriws |
| Proxy Manager | `p` | Proxy management submenu |

---

## Proxy Manager

| Option | Key | Description |
|--------|-----|-------------|
| View Statistics | `1` | Count, IPs, distribution |
| Randomize List | `2` | Smart shuffle |
| View Banned IPs | `3` | IPs from ban messages |
| Find Failing Proxies | `4` | 25+ failures, no success |
| Remove Banned IPs | `5` | Clean proxy.txt |
| Remove Failing Proxies | `6` | Remove bad proxies |
| Remove Duplicates | `7` | Remove duplicates |
| View Sample | `8` | First/last 10 proxies |

---

## Proxy Randomization

The smart shuffle feature:
1. Groups proxies by IP subnet (first 3 octets) or domain
2. Shuffles avoiding consecutive same-group entries
3. Creates automatic backup
4. Reports unavoidable duplicates

**Benefits:**
- Distributes load across providers
- Reduces detection patterns
- Minimizes consecutive failures

**Example:**
```
Before: 192.168.1.10, 192.168.1.20, 192.168.1.30, 10.0.0.5
After:  192.168.1.10, 10.0.0.5, 192.168.1.20, 192.168.1.30
```

---

## Live Monitoring Mode

```bash
sudo bash ./Shellder/logs.sh --xilriws-monitor
```

**Features:**
- Real-time refresh (every 3 seconds)
- Watches for "30 consecutive failures" message
- Auto-restarts container when Xilriws stops
- Critical message highlighting
- Last 5 log entries
- Restart counter

**Auto-restart triggers on:**
```
30 consecutive failures in the browser! this is really bad
```

---

## Proxy File Format

Location: `unown/proxies.txt`

Supported formats:
```
# IP:Port
192.168.1.1:8080

# User:Pass@IP:Port
username:password@192.168.1.1:8080

# Protocol://IP:Port
http://192.168.1.1:8080
socks5://192.168.1.1:1080

# Full format
http://username:password@192.168.1.1:8080
```

---

## Best Practices

1. **Monitor Daily** - Check status dashboard
2. **Remove Bad Proxies** - Weekly cleanup
3. **Randomize Periodically** - After removals
4. **Keep Backups** - Auto-created on changes
5. **Target >50% Success Rate** - Investigate drops
6. **Remove Banned IPs** - Promptly

---

## Quick Commands

```bash
# Xilriws status menu
sudo bash ./Shellder/logs.sh -x

# Live monitoring
sudo bash ./Shellder/logs.sh --xilriws-monitor

# Quick health check
sudo bash ./Shellder/logs.sh -h
```

---

[[← Device Setup|Device-Setup]] | [[Next: Optional Features →|Optional-Features]]

