# Troubleshooting

Common issues and solutions.

---

## Quick Diagnostic

```bash
# Run the checker
sudo bash ./Shellder/check.sh

# View all container status
docker compose ps

# View logs for a service
docker logs <container_name>
```

---

## Common Issues

### Port Already in Use

```
Error: port is already allocated
```

**Solution**: Change port in `docker-compose.yaml` or stop conflicting service.

```bash
# Find what's using the port
sudo lsof -i :6001

# Kill the process or change your config
```

---

### Container Won't Start

```bash
# Check logs
docker logs <container_name>

# Restart
docker compose restart <service_name>

# Rebuild
docker compose up -d --force-recreate --build <service_name>
```

---

### Database Connection Failed

1. Verify MariaDB running:
   ```bash
   docker compose ps database
   ```

2. Check credentials match in `.env` and service configs

3. Ensure databases exist:
   ```bash
   docker exec -it database mysql -u root -p
   SHOW DATABASES;
   ```

4. Use dbsetup.sh maintenance mode to fix:
   ```bash
   sudo bash ./Shellder/dbsetup.sh
   # Select: Fix ALL Issues
   ```

---

### Device Not Connecting

1. **Verify port 7070 is open**:
   ```bash
   sudo ufw status
   ```

2. **Check Rotom logs**:
   ```bash
   docker logs rotom
   ```

3. **Verify bearer token** matches

4. **Test connectivity**:
   ```bash
   telnet your-server-ip 7070
   ```

---

### Nginx 502 Bad Gateway

1. Check backend service running
2. Verify port numbers in Nginx config match docker-compose
3. Check Nginx error log:
   ```bash
   sudo tail -f /var/log/nginx/error.log
   ```

---

### SSL Certificate Issues

```bash
# Test renewal
sudo certbot renew --dry-run

# Force renewal
sudo certbot renew --force-renewal

# Check status
sudo certbot certificates
```

---

### Permission Denied Errors

```bash
# Fix ownership
sudo chown -R $USER:$USER .

# Fix scripts
chmod +x shellder.sh shellderGUI.sh Shellder/*.sh
```

---

## Useful Commands

```bash
# View all container status
docker compose ps

# Follow all logs
docker compose logs -f

# Restart everything
docker compose restart

# Full rebuild
docker compose down && docker compose up -d --force-recreate --build

# Check disk usage
docker system df

# Clean unused resources
docker system prune -a
```

---

## Using Log Manager

```bash
sudo bash ./Shellder/logs.sh
```

Features:
- View logs per service
- Search across all logs
- Error analysis with context
- Xilriws proxy management
- Log maintenance (clear, size check)

---

## Getting Help

### Before Asking:

1. Run `./Shellder/check.sh`
2. Check container logs
3. Search Discord for similar issues
4. Collect error messages

### Community Discord:

| Server | Focus |
|--------|-------|
| [Unown# Discord](https://discord.gg/Vjze47qchG) | Dragonite, Golbat, Rotom |
| [ReactMap/Koji Discord](https://discord.gg/EYYsKPVawn) | ReactMap, Koji |
| [Pokemod Discord](https://discord.gg/pokemod) | Aegis, General |

---

## Export Errors for AI Debugging

```bash
bash Shellder/log_helper.sh --export-error
```

Creates `shellder_error_export.txt` with:
- Recent errors
- System state
- Context for debugging

Paste contents when asking for help!

---

[[← Optional Features|Optional-Features]] | [[Back to Home →|Home]]

