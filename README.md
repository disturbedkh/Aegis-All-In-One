# Aegis All in One Mapping Solution

## Introduction

This repository is meant to help newbies to give their first steps into the Pokémon Mapping world using Aegis (https://www.pokemod.dev) and the Unown# (https://github.com/UnownHash) stack.

For people rather interested in Atlas (https://www.pokemod.dev) and RDM (https://github.com/RealDeviceMap), you should head over to our other repository (https://github.com/The-Pokemod-Group/Atlas-All-In-One)

## Disclaimer

This repository is meant to be used as a **learning tool** to help you understand how the different services interact with each other. For production use, please follow the security setup instructions in Step 3.

## Pre-installation

Make sure you have a Linux environment available. Albeit it is possible to run Docker under Windows, this AIO hasn't been tested in that environment so no support can be provided.

Moreover, you will need to have Docker Engine and Docker Compose plugin updated to a recent version in order for services used in this AIO repository to work correctly!!!

Regarding Docker configurations, due to the massive logs size that can accumulate over time, it is strongly recommended that you configure your Docker service to limit and rotate logs. You can achieve this by creating or editing the daemon.json file in your system:

```
sudo nano /etc/docker/daemon.json
```

and placing inside:

```
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
```

This will limit the logs to a total of 300Mbytes and rotate them every 100Mbytes.

Don't forget to restart the docker service once you've edited/create the file above with

```
sudo systemctl restart docker
```

## Installation

### 1. Clone the repository

```
git clone https://github.com/The-Pokemod-Group/Aegis-All-In-One.git
cd Aegis-All-In-One
```

### 2. Run the setup script

```
sudo bash ./setup.sh
```

This will prompt you to create all needed environmental and config variables and import them into relevant configs and the docker compose file. The script will also create the initial databases.

### 3. Start the stack

```
docker compose up -d --force-recreate --build
```

(\*) You might need to run the above command with sudo if your local user doesn't have permissions over the docker service

You should check each running container for errors after first start in the form of:

```
docker logs <name_of_container>
```

It's normal that after the first start some errors appear as, for example, Koji needs to have at least one project for dragonite/reactmap to pull the areas from but overall, all containers should boot up normally.

### 4. Check if all systems are running

Point your browser to the following addresses. Replace localhost with your server's IP address, if needed:

| Service | URL | Description |
|---------|-----|-------------|
| ReactMap | http://localhost:6001 | Pokemon Map Frontend |
| Dragonite Admin | http://localhost:6002 | Scanner Management |
| Rotom | http://localhost:6003 | Device Manager |
| Koji | http://localhost:6004 | Geofence & Area Management |
| phpMyAdmin | http://localhost:6005 | Database Management |
| Grafana | http://localhost:6006 | Statistics & Monitoring |
| Poracle* | http://localhost:6007 | Discord/Telegram Alerts (optional) |

*Poracle is commented out by default. Uncomment in `docker-compose.yaml` if you want Discord/Telegram alerts.

#### Special note

On some occasions one or more of these ports may already be assigned to other services which largely depends on each specific machine. If you're presented with a **_"port already in use"_** error, please change the corresponding container port in the `docker-compose.yaml` file.

### 5. (Optional) Setup Poracle for Discord/Telegram Alerts

If you want Pokemon spawn, raid, and quest alerts sent to Discord or Telegram:

```
sudo bash ./poracle.sh
```

The script will guide you through:
- Creating a Discord or Telegram bot
- Configuring bot tokens and admin users
- Selecting which notification types to enable
- Setting up webhooks from Golbat

More info: https://github.com/KartulUdus/PoracleJS

### 6. (Optional) Setup Fletchling for Pokemon Nests

If you want Pokemon nests displayed on ReactMap, you'll need to setup Fletchling:

1. First, create a project with geofences in Koji Admin (http://localhost:6004)
2. Run the Fletchling setup script:

```
sudo bash ./fletchling.sh
```

The script will:
- Configure Fletchling with your Koji project
- Import park data from OpenStreetMap
- Enable nest tracking in your scanning area

More info: https://github.com/UnownHash/Fletchling

### 7. (Recommended) Secure Your Setup for External Access

If you plan to access your setup from outside localhost or expose it to the internet, run the nginx security setup script:

```
sudo bash ./nginx-setup.sh
```

This script provides:

- **Nginx Reverse Proxy** - Proper domain-based access to all services
- **SSL/TLS Certificates** - Free Let's Encrypt certificates via Certbot
- **Basic Authentication** - Password protection for sensitive services
- **Authelia SSO** (Optional) - Single Sign-On with Two-Factor Authentication
- **Fail2Ban Protection** - Brute-force and bot protection

The script will guide you through:
1. Domain/subdomain configuration
2. SSL certificate setup
3. Authentication options (Basic Auth or Authelia 2FA)
4. Fail2Ban jail configuration

**For production use, this step is highly recommended!**

### 8. Validate Your Configuration

Run the configuration checker to ensure everything is properly set up:

```
sudo bash ./check.sh
```

This script validates:
- Environment variables match across configs
- Database passwords are consistent
- API secrets are properly configured
- Docker containers are running
- Required files exist

### 9. Working with Grafana

Albeit not critical to normal operation, it's always nice and informative to have some kind of performance metrics of your setup. In order to get a glimpse of what you can get with it, you should import our custom example dashboard that's inside the grafana folder (based on Dragonite's default prometheus dashboard but with some other metrics).

1. Point your browser to http://localhost:6006
2. Login with the default admin/admin credentials (**change them once you've logged in!**)
3. Add a new prometheus datasource and point it to `victoriametrics:8428`
4. Tap on Dashboards → Add New → Import and select `Dragonite-Emi-v5.json`
5. Tap save

That's it. If you want more dashboards, you can find them at Unown#'s github.

### 10. What now?

Now comes the fun part. Start reading and learning how all of this works. We recommend you to head over to:

- **Unown# Discord** - Help with Dragonite, Golbat and Rotom: https://discord.gg/Vjze47qchG
- **ReactMap/Koji Discord** - Help with ReactMap and Koji: https://discord.gg/EYYsKPVawn
- **Pokemod Discord** - Help with Aegis and general questions: https://discord.gg/pokemod

In general terms, you will need to:

1. Add accounts to Dragonite (lots of them! Account usage depends on each setup and use case including active options like `recycle_on_jail=true` but to be safe, consider at least 100 per worker x `minimum_account_reuse_hours` / 24)
2. Add at least one project with areas in Koji (check the image below for an example of a full running setup)
3. Sync the project with Dragonite and Reactmap
4. Add at least one Aegis Device (should be autodetected by Rotom once you configure the ATV and Aegis properly)
5. Map away

### 11. Aegis Device Configuration

This is typically unnecessary, because filling in the details in the app is usually sufficient.

The configuration file for Aegis is placed in `/data/local/tmp/aegis_config.json`, and the same goes for the logs at `/data/local/tmp/aegis.log`.

As for the configuration file, here is an example:

```json
{
    "authBearer": "bearer_for_rotom",
    "deviceAuthToken": "your_unique_auth_token_from_aegis_portal",
    "deviceName": "your_device_name",
    "email": "your_email_from_aegis_portal",
    "rotomUrl": "ip:port",
    "runOnBoot": true
}
```

## Screenshots

_Koji Projects:_

![Koji Sample Projects](https://i.ibb.co/YhdSWCq/koji-projects.png)

_ReactMap:_

![Reactmap Sample Area](https://i.ibb.co/b7BS6Ww/reactmap.png)

_Dragonite:_

![Dragonite Sample](https://i.ibb.co/7SDmxrm/dragonite.png)

_Rotom:_

![Rotom Sample](https://i.ibb.co/6FPB2ry/rotom.png)

_Grafana:_

![Grafana Sample](https://i.ibb.co/qr1v3CP/grafana.png)

## Support

Debugging is a big part of the process, so don't be afraid to ask for help in our Discord server: https://discord.gg/pokemod

---

**Aegis All-in-One** by [The Pokemod Group](https://pokemod.dev/)
