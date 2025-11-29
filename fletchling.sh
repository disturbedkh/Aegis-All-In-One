#!/bin/bash

# Welcome message
echo "Welcome! This will setup fletchling, which imports pokemon nests to their reactmap."

# Inform user about prerequisites
echo "Before proceeding, you must have created the project with a geofence in Koji Admin."
read -p "Press enter to continue if you have done this, or Ctrl+C to abort."

# Check if .env exists
if [ ! -f ".env" ]; then
  echo "Error: .env file not found. Have you run the initial setup script?"
  exit 1
fi

# Source .env
source .env

# Check for DB_USER and DB_PASSWORD
if [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
  echo "Error: DB_USER or DB_PASSWORD not found in .env. Please ensure they are set."
  exit 1
fi

# Prompt for Koji project name
read -p "Enter your Koji project name: " KOJI_PROJECT
if [ -z "$KOJI_PROJECT" ]; then
  echo "Error: Koji project name is required."
  exit 1
fi

# Assume fletchling config file, copy if not exists (adjust path if needed)
if [ ! -f "fletchling/configs/fletchling.toml" ]; then
  cp fletchling/configs/fletchling.toml.example fletchling/configs/fletchling.toml
fi

# Replace DB user and password in config (assuming placeholders are 'dbuser' and 'SuperSecuredbuserPassword' like before)
sed -i "s/dbuser/${DB_USER}/g" fletchling/configs/fletchling.toml
sed -i "s/SuperSecuredbuserPassword/${DB_PASSWORD}/g" fletchling/configs/fletchling.toml

# Replace Koji project placeholder
sed -i "s/YOUR-PROJECT-IN-KOJI-ADMIN-HERE/${KOJI_PROJECT}/g" fletchling/configs/fletchling.toml

# Run docker-osm-importer.sh
echo "Running docker-osm-importer.sh..."
./docker-osm-importer.sh

if [ $? -eq 0 ]; then
  echo "docker-osm-importer.sh executed successfully."
else
  echo "Error: docker-osm-importer.sh failed. Check logs for details."
fi

echo "Fletchling setup complete. Review configurations and restart services if necessary."
