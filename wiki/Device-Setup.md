# Device Setup

Configure Aegis app on your Android devices.

---

## Aegis App Configuration

1. **Install Aegis** on your Android device
2. **Open the app** and enter connection details:
   - **Rotom URL**: `your-server-ip:7070`
   - **Auth Bearer**: Token from your setup
   - **Device Name**: Unique identifier

---

## Manual Configuration (Advanced)

Configuration file location:
```
/data/local/tmp/aegis_config.json
```

Example:
```json
{
    "authBearer": "your_rotom_auth_bearer",
    "deviceAuthToken": "your_unique_device_token",
    "deviceName": "device-01",
    "email": "your_aegis_portal_email",
    "rotomUrl": "your-server-ip:7070",
    "runOnBoot": true
}
```

Log file:
```
/data/local/tmp/aegis.log
```

---

## Connection Flow

```
1. Device connects to Rotom (port 7070)
           │
           ▼
2. Rotom authenticates using bearer token
           │
           ▼
3. Device appears in Rotom dashboard
           │
           ▼
4. Dragonite assigns scan tasks
           │
           ▼
5. Device executes tasks, reports data
           │
           ▼
6. Golbat processes and stores data
           │
           ▼
7. ReactMap displays results
```

---

## Requirements

### Server Side
- Port 7070 open and accessible
- Rotom container running
- Valid auth bearer configured

### Device Side
- Aegis app installed
- Correct server IP/hostname
- Matching auth bearer
- Unique device name

---

## Troubleshooting

### Device Not Connecting

1. **Verify port 7070 is open**:
   ```bash
   sudo ufw status
   # Should show: 7070 ALLOW
   ```

2. **Check Rotom logs**:
   ```bash
   docker logs rotom
   ```

3. **Verify bearer token** matches in:
   - Device config
   - `rotom_config.json`

4. **Test connectivity**:
   ```bash
   telnet your-server-ip 7070
   ```

### Device Keeps Disconnecting

- Check device stability
- Review Rotom logs for errors
- Monitor via Shellder logs.sh → Device disconnect monitor

---

## Multiple Devices

Each device needs:
- Unique device name
- Same auth bearer (shared)
- Unique device auth token (optional)

Example naming:
- `scanner-01`
- `scanner-02`
- `home-device`

---

[[← Configuration|Configuration]] | [[Next: Xilriws →|Xilriws]]

