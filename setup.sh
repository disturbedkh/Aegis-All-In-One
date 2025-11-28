#!/bin/bash
set -e  # Exit on error
echo "Setting up Aegis-All-In-One..."

# Auto-copy defaults if missing
[[ ! -f .env ]] && cp env-default .env && echo "Copied .env – edit secrets!"
[[ ! -f reactmap/local.json ]] && cp reactmap/local-default.json reactmap/local.json
[[ ! -f unown/dragonite_config.toml ]] && cp unown/dragonite_config-default.toml unown/dragonite_config.toml
[[ ! -f unown/golbat_config.toml ]] && cp unown/golbat_config-default.toml unown/golbat_config.toml
[[ ! -f unown/rotom_config.json ]] && cp unown/rotom_config-default.json unown/rotom_config.json

# Prompt for key secrets (append to .env if missing)
read -p "Enter PTC API key (or Enter for default): " ptc_key
[[ -n "$ptc_key" ]] && echo "PTC_API_KEY=$ptc_key" >> .env

# Validate Dragonite/Golbat password match (simple grep check)
if grep -q "password=" unown/dragonite_config.toml && grep -q "password=" unown/golbat_config.toml; then
  d_pass=$(grep "password=" unown/dragonite_config.toml | cut -d= -f2 | tr -d '"')
  g_pass=$(grep "password=" unown/golbat_config.toml | cut -d= -f2 | tr -d '"')
  [[ "$d_pass" != "$g_pass" ]] && echo "Warning: Dragonite/Golbat passwords mismatch – fix manually!"
fi

echo "Setup complete! Run: docker compose up -d"
