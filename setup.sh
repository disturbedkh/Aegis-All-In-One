#!/bin/bash

# Welcome message
echo "Welcome! This is the first-time setup script for Aegis All-in-One 2.0."
echo "It will guide you through copying default configs, setting up secure values (prompting for input or generating random ones), and updating the files accordingly."

# This script assumes you are in the root directory of the downloaded repo (Aegis-All-In-One)
# It copies the default config files, prompts for tokens and passwords (or generates random if enter is pressed), and replaces the defaults in the config files.

# Copy the default files as per README
cp env-default .env
cp reactmap/local-default.json reactmap/local.json
cp unown/dragonite_config-default.toml unown/dragonite_config.toml
cp unown/golbat_config-default.toml unown/golbat_config.toml
cp unown/rotom_config-default.json unown/rotom_config.json

# Function to generate random string
generate_random() {
    local length=$1
    local charset=$2
    openssl rand -base64 48 | tr -dc "$charset" | fold -w "$length" | head -n 1
}

# Prompt for each value or generate random

read -p "Enter DB_USER (or press enter for random): " DB_USER
if [ -z "$DB_USER" ]; then
    DB_USER=$(generate_random 16 'a-zA-Z0-9')
fi

read -p "Enter DB_PASSWORD (or press enter for random): " DB_PASSWORD
if [ -z "$DB_PASSWORD" ]; then
    DB_PASSWORD=$(generate_random 32 'a-zA-Z0-9')
fi

read -p "Enter MYSQL_ROOT_PASSWORD (or press enter for random): " MYSQL_ROOT_PASSWORD
if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
    MYSQL_ROOT_PASSWORD=$(generate_random 32 'a-zA-Z0-9')
fi

read -p "Enter KOJI_BEARER (or press enter for random): " KOJI_BEARER
if [ -z "$KOJI_BEARER" ]; then
    KOJI_BEARER=$(generate_random 32 'a-zA-Z0-9')
fi

read -p "Enter GOLBAT_RAW_SECRET (or press enter for random): " GOLBAT_RAW_SECRET
if [ -z "$GOLBAT_RAW_SECRET" ]; then
    GOLBAT_RAW_SECRET=$(generate_random 32 'a-zA-Z0-9')
fi

read -p "Enter GOLBAT_API_SECRET (or press enter for random): " GOLBAT_API_SECRET
if [ -z "$GOLBAT_API_SECRET" ]; then
    GOLBAT_API_SECRET=$(generate_random 32 'a-zA-Z0-9')
fi

read -p "Enter SESSION_SECRET (or press enter for random): " SESSION_SECRET
if [ -z "$SESSION_SECRET" ]; then
    SESSION_SECRET=$(generate_random 40 'a-zA-Z0-9~!@#^')
fi

read -p "Enter REACTMAP_SECRET (or press enter for random): " REACTMAP_SECRET
if [ -z "$REACTMAP_SECRET" ]; then
    REACTMAP_SECRET=$(generate_random 40 'a-zA-Z0-9~!@#^')
fi

read -p "Enter ROTOM_AUTH_BEARER (or press enter for random): " ROTOM_AUTH_BEARER
if [ -z "$ROTOM_AUTH_BEARER" ]; then
    ROTOM_AUTH_BEARER=$(generate_random 32 'a-zA-Z0-9')
fi

read -p "Enter DRAGONITE_PASSWORD (or press enter for random): " DRAGONITE_PASSWORD
if [ -z "$DRAGONITE_PASSWORD" ]; then
    DRAGONITE_PASSWORD=$(generate_random 32 'a-zA-Z0-9')
fi

read -p "Enter DRAGONITE_API_SECRET (or press enter for random): " DRAGONITE_API_SECRET
if [ -z "$DRAGONITE_API_SECRET" ]; then
    DRAGONITE_API_SECRET=$(generate_random 32 'a-zA-Z0-9')
fi

# Replace defaults in all relevant config files (including .env if it contains them)
# We use sed to replace exact string matches

# Replace DB user
sed -i "s/dbuser/${DB_USER}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# Replace DB password
sed -i "s/SuperSecuredbuserPassword/${DB_PASSWORD}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# Replace MySQL root password
sed -i "s/V3ryS3cUr3MYSQL_ROOT_P4ssw0rd/${MYSQL_ROOT_PASSWORD}/g" .env

# Replace Koji bearer token
sed -i "s/SuperSecureKojiSecret/${KOJI_BEARER}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# Replace Golbat raw secret
sed -i "s/SuperSecureGolbatRawSecret/${GOLBAT_RAW_SECRET}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# Replace Golbat API secret
sed -i "s/SuperSecureGolbatApiSecret/${GOLBAT_API_SECRET}/g" .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# Replace ReactMap session secret (specific default string)
sed -i 's/98ki^e72~!@#(85o3kXLI*#c9wu5l!ZUGA/'"${SESSION_SECRET}"'/g' .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# Replace ReactMap secret (specific default string)
sed -i 's/98ki^e72~!@#(85o3kXLI*#c9wu5l!Zx10venikyoa0/'"${REACTMAP_SECRET}"'/g' .env reactmap/local.json unown/dragonite_config.toml unown/golbat_config.toml unown/rotom_config.json

# Replace Rotom device secret
sed -i "s/SuperSecretAuthBearerForAegisDevices/${ROTOM_AUTH_BEARER}/g" unown/rotom_config.json

# Replace Dragonite admin password
sed -i "s/SuperSecureDragoniteAdminPassword/${DRAGONITE_PASSWORD}/g" .env

# Replace Dragonite API secret
sed -i "s/SuperSecureDragoniteApiSecret/${DRAGONITE_API_SECRET}/g" .env

echo "Setup complete. Config files have been copied and defaults replaced with provided or randomized values."
echo "Review the files for any additional manual changes, then run 'docker compose up -d --force-recreate --build' to start."
