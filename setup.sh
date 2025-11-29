#!/bin/bash

# =============================================================================
# Aegis All-in-One 2.0 - Initial Setup Script
# =============================================================================
# This script handles:
#   1. Copying default config files
#   2. Generating/setting secure passwords and tokens
#   3. Installing MariaDB (optional)
#   4. Creating required databases
# =============================================================================

echo ""
echo "======================================"
echo "  Aegis All-in-One 2.0 - Setup"
echo "======================================"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (e.g., sudo bash setup.sh)"
  exit 1
fi

# Get the original user who called sudo (to fix file ownership later)
if [ -n "$SUDO_USER" ]; then
  REAL_USER="$SUDO_USER"
  REAL_GROUP=$(id -gn "$SUDO_USER")
else
  REAL_USER="$USER"
  REAL_GROUP=$(id -gn)
fi

# -----------------------------------------------------------------------------
# Step 1: Copy default config files
# -----------------------------------------------------------------------------
echo "[1/4] Copying default config files..."

cp env-default .env
cp reactmap/local-default.json reactmap/local.json
cp unown/dragonite_config-default.toml unown/dragonite_config.toml
cp unown/golbat_config-default.toml unown/golbat_config.toml
cp unown/rotom_config-default.json unown/rotom_config.json

echo "      Config files copied."
echo ""

# -----------------------------------------------------------------------------
# Step 2: Generate/prompt for secrets and passwords
# -----------------------------------------------------------------------------
echo "[2/4] Configuring secrets and passwords..."
echo "      (Press enter to auto-generate random values)"
echo ""

# Function to generate random string
generate_random() {
    local length=$1
    local charset=$2
    openssl rand -base64 48 | tr -dc "$charset" | fold -w "$length" | head -n 1
}

# Database credentials
read -p "  DB_USER: " DB_USER
[ -z "$DB_USER" ] && DB_USER=$(generate_random 16 'a-zA-Z0-9')

read -p "  DB_PASSWORD: " DB_PASSWORD
[ -z "$DB_PASSWORD" ] && DB_PASSWORD=$(generate_random 32 'a-zA-Z0-9')

read -p "  MYSQL_ROOT_PASSWORD: " MYSQL_ROOT_PASSWORD
[ -z "$MYSQL_ROOT_PASSWORD" ] && MYSQL_ROOT_PASSWORD=$(generate_random 32 'a-zA-Z0-9')

# Service secrets
read -p "  KOJI_BEARER: " KOJI_BEARER
[ -z "$KOJI_BEARER" ] && KOJI_BEARER=$(generate_random 32 'a-zA-Z0-9')

read -p "  GOLBAT_RAW_SECRET: " GOLBAT_RAW_SECRET
[ -z "$GOLBAT_RAW_SECRET" ] && GOLBAT_RAW_SECRET=$(generate_random 32 'a-zA-Z0-9')

read -p "  GOLBAT_API_SECRET: " GOLBAT_API_SECRET
[ -z "$GOLBAT_API_SECRET" ] && GOLBAT_API_SECRET=$(generate_random 32 'a-zA-Z0-9')

read -p "  SESSION_SECRET: " SESSION_SECRET
[ -z "$SESSION_SECRET" ] && SESSION_SECRET=$(generate_random 40 'a-zA-Z0-9')

read -p "  REACTMAP_SECRET: " REACTMAP_SECRET
[ -z "$REACTMAP_SECRET" ] && REACTMAP_SECRET=$(generate_random 40 'a-zA-Z0-9')

read -p "  ROTOM_AUTH_BEARER: " ROTOM_AUTH_BEARER
[ -z "$ROTOM_AUTH_BEARER" ] && ROTOM_AUTH_BEARER=$(generate_random 32 'a-zA-Z0-9')

read -p "  DRAGONITE_PASSWORD: " DRAGONITE_PASSWORD
[ -z "$DRAGONITE_PASSWORD" ] && DRAGONITE_PASSWORD=$(generate_random 32 'a-zA-Z0-9')

read -p "  DRAGONITE_API_SECRET: " DRAGONITE_API_SECRET
[ -z "$DRAGONITE_API_SECRET" ] && DRAGONITE_API_SECRET=$(generate_random 32 'a-zA-Z0-9')

echo ""
echo "      Applying secrets to config files..."

# Replace defaults in config files
# IMPORTANT: Replace password BEFORE username since "dbuser" appears inside "SuperSecuredbuserPassword"

# DB password (must be done before DB user)
sed -i "s/SuperSecuredbuserPassword/${DB_PASSWORD}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# DB user
sed -i "s/dbuser/${DB_USER}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# MySQL root password
sed -i "s/V3ryS3cUr3MYSQL_ROOT_P4ssw0rd/${MYSQL_ROOT_PASSWORD}/g" .env

# Koji bearer token
sed -i "s/SuperSecureKojiSecret/${KOJI_BEARER}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# Golbat secrets
sed -i "s/SuperSecureGolbatRawSecret/${GOLBAT_RAW_SECRET}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json
sed -i "s/SuperSecureGolbatApiSecret/${GOLBAT_API_SECRET}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# ReactMap secrets
sed -i 's/98ki^e72~!@#(85o3kXLI*#c9wu5l!ZUGA/'"${SESSION_SECRET}"'/g' reactmap/local.json
sed -i 's/98ki^e72~!@#(85o3kXLI*#c9wu5l!Zx10venikyoa0/'"${REACTMAP_SECRET}"'/g' reactmap/local.json

# Rotom device secret
sed -i "s/SuperSecretAuthBearerForAegisDevices/${ROTOM_AUTH_BEARER}/g" unown/rotom_config.json

# Dragonite secrets
sed -i "s/SuperSecureDragoniteAdminPassword/${DRAGONITE_PASSWORD}/g" .env
sed -i "s/SuperSecureDragoniteApiSecret/${DRAGONITE_API_SECRET}/g" .env

# Restore file ownership to the original user (not root)
chown "$REAL_USER:$REAL_GROUP" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

echo "      Secrets applied."
echo ""

# -----------------------------------------------------------------------------
# Step 3: MariaDB installation (optional)
# -----------------------------------------------------------------------------
echo "[3/4] Database setup..."

if ! command -v mysql &> /dev/null; then
  read -p "      MariaDB not found. Install it now? (y/n): " INSTALL_CHOICE
  if [ "$INSTALL_CHOICE" = "y" ] || [ "$INSTALL_CHOICE" = "Y" ]; then
    echo "      Installing MariaDB..."
    apt update -y
    apt install mariadb-server -y
    # Set root password on fresh install
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD'; FLUSH PRIVILEGES;"
    if [ $? -eq 0 ]; then
      echo "      MariaDB installed and root password set."
    else
      echo "      Error setting root password. Please check installation."
      exit 1
    fi
  else
    echo "      Skipping MariaDB installation."
    echo "      You will need to set up databases manually or use Docker's MariaDB."
    SKIP_DB_SETUP=true
  fi
else
  echo "      MariaDB is already installed."
fi

# -----------------------------------------------------------------------------
# Step 4: Create databases
# -----------------------------------------------------------------------------
if [ "$SKIP_DB_SETUP" != "true" ]; then
  echo ""
  echo "[4/4] Creating databases..."

  read -p "      DB root username (default: root): " ROOT_USER
  [ -z "$ROOT_USER" ] && ROOT_USER="root"

  # Databases to create
  DBS=("dragonite" "golbat" "reactmap" "koji")

  # Build SQL
  SQL=""
  for db in "${DBS[@]}"; do
    SQL+="CREATE DATABASE IF NOT EXISTS \`$db\`; "
  done

  # Create the application DB user with the credentials from config
  SQL+="CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD'; "
  SQL+="GRANT ALL PRIVILEGES ON *.* TO '$DB_USER'@'%' WITH GRANT OPTION; "
  SQL+="FLUSH PRIVILEGES; "

  # Execute SQL
  echo "$SQL" | mysql -u"$ROOT_USER" -p"$MYSQL_ROOT_PASSWORD" -h localhost

  if [ $? -eq 0 ]; then
    echo "      Databases created: ${DBS[*]}"
    echo "      DB user '$DB_USER' created with full privileges."
  else
    echo "      Error creating databases. Check credentials and try again."
    exit 1
  fi
else
  echo ""
  echo "[4/4] Skipped database creation (MariaDB not installed)."
fi

# -----------------------------------------------------------------------------
# Done!
# -----------------------------------------------------------------------------
echo ""
echo "======================================"
echo "  Setup Complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo "  1. Review config files for any manual changes needed"
echo "  2. Run: docker compose up -d --force-recreate --build"
echo ""
