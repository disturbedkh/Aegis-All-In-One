#!/bin/bash

# Welcome message
echo ""
echo "======================================"
echo "  Aegis All-in-One 2.0 - DB Setup"
echo "  By The Pokemod Group"
echo "  https://pokemod.dev/"
echo "======================================"
echo ""
echo "This is the database setup script for Aegis All-in-One 2.0."
echo "It assumes you have run the initial setup script and have MariaDB"
echo "either installed or ready to install on this machine."
echo ""
echo "Docker compose has not been run yet. This script will create the"
echo "necessary databases and optionally a non-root DB user."
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (e.g., sudo bash this_script.sh)"
  exit 1
fi

# Check if .env exists
if [ ! -f ".env" ]; then
  echo "Error: .env file not found. Have you run the initial setup script?"
  exit 1
fi

# Source .env (skip UID/GID which are readonly bash variables)
while IFS='=' read -r key value; do
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    [[ "$key" == "UID" ]] && continue
    [[ "$key" == "GID" ]] && continue
    export "$key=$value"
done < .env

# Check for MYSQL_ROOT_PASSWORD
if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
  echo "Error: MYSQL_ROOT_PASSWORD not found in .env. Please ensure it is set in .env (you may need to edit it manually if not generated)."
  exit 1
fi

# Check if MariaDB is installed
if ! command -v mysql &> /dev/null; then
  read -p "MariaDB is not installed. Do you want to install it now using apt-get? (y/n): " INSTALL_CHOICE
  if [ "$INSTALL_CHOICE" = "y" ] || [ "$INSTALL_CHOICE" = "Y" ]; then
    apt update -y
    apt install mariadb-server -y
    # After fresh install, set root password using the one from .env
    # Assume root username is 'root' and initial access without password
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD'; FLUSH PRIVILEGES;"
    if [ $? -eq 0 ]; then
      echo "MariaDB installed and root password set successfully."
    else
      echo "Error setting root password. Please check installation."
      exit 1
    fi
  else
    echo "Installation skipped. Please install MariaDB manually and rerun the script."
    exit 1
  fi
else
  echo "MariaDB is already installed."
fi

# Prompt for root DB username
read -p "Enter root DB username (or press enter for 'root'): " ROOT_USER
if [ -z "$ROOT_USER" ]; then
  ROOT_USER="root"
fi

# Prompt for non-root DB user
read -p "Enter non-root DB username to create (or press enter to skip): " NON_ROOT_USER
if [ -z "$NON_ROOT_USER" ]; then
  echo "Skipping non-root user creation."
else
  read -p "Enter password for $NON_ROOT_USER (or press enter for random): " NON_ROOT_PASS
  if [ -z "$NON_ROOT_PASS" ]; then
    NON_ROOT_PASS=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
    echo "Generated random password: $NON_ROOT_PASS"
    echo "Note: You will need to update your config files and .env with this user and password if different from existing DB_USER and DB_PASSWORD."
  fi
fi

# Databases from configs
DBS=("dragonite" "golbat" "reactmap" "koji" "poracle")

# Build SQL commands
SQL=""
for db in "${DBS[@]}"; do
  SQL+="CREATE DATABASE IF NOT EXISTS \`$db\`; "
done

if [ -n "$NON_ROOT_USER" ]; then
  SQL+="CREATE USER IF NOT EXISTS '$NON_ROOT_USER'@'%' IDENTIFIED BY '$NON_ROOT_PASS'; "
  SQL+="GRANT ALL PRIVILEGES ON *.* TO '$NON_ROOT_USER'@'%' WITH GRANT OPTION; "
  SQL+="FLUSH PRIVILEGES; "
fi

# Execute SQL on local MariaDB
echo "$SQL" | mysql -u"$ROOT_USER" -p"$MYSQL_ROOT_PASSWORD" -h localhost

if [ $? -eq 0 ]; then
  echo "Database setup complete. Databases have been created."
  if [ -n "$NON_ROOT_USER" ]; then
    echo "Non-root user '$NON_ROOT_USER' has been created with all privileges."
  fi
  echo "You can now run 'docker compose up -d --force-recreate --build' to start the services."
else
  echo "Error executing SQL commands. Check if MariaDB is running, and credentials are correct."
fi
