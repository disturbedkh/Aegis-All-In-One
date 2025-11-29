#!/bin/bash

# =============================================================================
# Poracle Setup Script for Aegis All-in-One
# =============================================================================
# This script configures PoracleJS for Discord and/or Telegram notifications
# for Pokemon spawns, raids, quests, and other Pokemon GO events.
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() { echo -e "\n${CYAN}=== $1 ===${NC}\n"; }

# Get the original user who called sudo (to fix file ownership later)
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    REAL_GROUP=$(id -gn "$SUDO_USER")
else
    REAL_USER="$USER"
    REAL_GROUP=$(id -gn)
fi

echo ""
echo "=============================================="
echo "  Poracle Setup - Pokemon Alert Notifications"
echo "  Aegis All-in-One by The Pokemod Group"
echo "  https://pokemod.dev/"
echo "=============================================="
echo ""

# =============================================================================
# Introduction
# =============================================================================
print_header "What is Poracle?"

echo "Poracle is a Pokemon GO notification service that sends alerts to Discord"
echo "or Telegram when Pokemon spawn, raids appear, quests reset, and more."
echo ""
echo "With Poracle, users can:"
echo "  • Track specific Pokemon (including IV, level, PVP ranks)"
echo "  • Get raid notifications for specific bosses or tiers"
echo "  • Receive quest alerts for specific rewards"
echo "  • Track Team Rocket invasions"
echo "  • Monitor gym changes and Pokemon nests"
echo ""
echo "You'll need to create a bot on Discord and/or Telegram to use this service."
echo ""

read -p "Press Enter to continue or Ctrl+C to cancel..."

# =============================================================================
# Prerequisites Check
# =============================================================================
print_header "Checking Prerequisites"

# Check if running from correct directory
if [ ! -f "docker-compose.yaml" ]; then
    print_error "Please run this script from the Aegis-All-In-One directory"
    exit 1
fi

print_success "Found docker-compose.yaml"

# Check if .env exists
if [ ! -f ".env" ]; then
    print_error ".env file not found. Have you run the initial setup script?"
    print_info "Run: sudo bash setup.sh"
    exit 1
fi

print_success "Found .env file"

# Source .env for database password
source .env

# Check for Poracle config
CONFIG_FILE="Poracle/config/local.json"
if [ ! -f "$CONFIG_FILE" ]; then
    print_error "Poracle config not found at $CONFIG_FILE"
    exit 1
fi

print_success "Found Poracle configuration file"

# Check if database password is set
if [ -z "$MYSQL_PASSWORD" ]; then
    print_error "MYSQL_PASSWORD not found in .env"
    exit 1
fi

print_success "Database credentials available"

# =============================================================================
# Platform Selection
# =============================================================================
print_header "Select Messaging Platform"

echo "Poracle can send notifications to Discord, Telegram, or both."
echo ""
echo "Which platform(s) would you like to configure?"
echo ""
echo "  1) Discord only"
echo "  2) Telegram only"
echo "  3) Both Discord and Telegram"
echo ""
read -p "Select option [1-3]: " PLATFORM_CHOICE

SETUP_DISCORD=false
SETUP_TELEGRAM=false

case $PLATFORM_CHOICE in
    1)
        SETUP_DISCORD=true
        print_info "Configuring Discord..."
        ;;
    2)
        SETUP_TELEGRAM=true
        print_info "Configuring Telegram..."
        ;;
    3)
        SETUP_DISCORD=true
        SETUP_TELEGRAM=true
        print_info "Configuring both Discord and Telegram..."
        ;;
    *)
        print_error "Invalid option. Please run the script again."
        exit 1
        ;;
esac

# =============================================================================
# Discord Configuration
# =============================================================================
if [ "$SETUP_DISCORD" = true ]; then
    print_header "Discord Bot Configuration"
    
    echo "To use Poracle with Discord, you need to create a Discord Bot."
    echo ""
    echo "How to create a Discord Bot:"
    echo "  1. Go to https://discord.com/developers/applications"
    echo "  2. Click 'New Application' and give it a name (e.g., 'Pokemon Alerts')"
    echo "  3. Go to the 'Bot' section in the left menu"
    echo "  4. Click 'Add Bot' and confirm"
    echo "  5. Under 'Token', click 'Copy' to get your bot token"
    echo "  6. IMPORTANT: Enable these 'Privileged Gateway Intents':"
    echo "     - MESSAGE CONTENT INTENT"
    echo "     - SERVER MEMBERS INTENT"
    echo "  7. Go to OAuth2 > URL Generator"
    echo "  8. Select 'bot' scope and these permissions:"
    echo "     - Send Messages, Embed Links, Attach Files, Read Message History"
    echo "  9. Copy the generated URL and open it to invite the bot to your server"
    echo ""
    
    # Bot Token
    echo -e "${CYAN}Discord Bot Token${NC}"
    echo "This is the secret token that allows Poracle to control your bot."
    echo "Keep this private! Never share it publicly."
    echo ""
    read -p "Enter your Discord Bot Token: " DISCORD_TOKEN
    
    if [ -z "$DISCORD_TOKEN" ]; then
        print_error "Discord Bot Token is required"
        exit 1
    fi
    
    echo ""
    
    # Command Prefix
    echo -e "${CYAN}Command Prefix${NC}"
    echo "This is the character users type before commands (e.g., !track pikachu)"
    echo "Common choices: ! . $ ?"
    echo ""
    read -p "Enter command prefix [default: !]: " DISCORD_PREFIX
    DISCORD_PREFIX=${DISCORD_PREFIX:-!}
    
    echo ""
    
    # Admin User IDs
    echo -e "${CYAN}Admin User ID(s)${NC}"
    echo "Admins can manage Poracle settings and have full control."
    echo ""
    echo "How to get your Discord User ID:"
    echo "  1. Enable Developer Mode in Discord (Settings > Advanced > Developer Mode)"
    echo "  2. Right-click on your username and select 'Copy ID'"
    echo ""
    echo "Enter admin Discord User IDs (comma-separated for multiple)"
    echo "Example: 123456789012345678,987654321098765432"
    echo ""
    read -p "Enter Admin User ID(s): " DISCORD_ADMINS_INPUT
    
    if [ -z "$DISCORD_ADMINS_INPUT" ]; then
        print_warning "No admin IDs provided. You can add them later in the config file."
        DISCORD_ADMINS="[]"
    else
        # Convert comma-separated to JSON array
        DISCORD_ADMINS=$(echo "$DISCORD_ADMINS_INPUT" | sed 's/,/","/g' | sed 's/^/["/' | sed 's/$/"]/')
    fi
    
    echo ""
    
    # Allowed Channels (optional)
    echo -e "${CYAN}Allowed Channel ID(s) (Optional)${NC}"
    echo "Restrict which channels the bot responds in."
    echo "Leave empty to allow the bot to work in all channels it can see."
    echo ""
    echo "How to get a Channel ID:"
    echo "  1. Right-click on the channel name"
    echo "  2. Select 'Copy ID'"
    echo ""
    read -p "Enter Channel ID(s) [leave empty for all]: " DISCORD_CHANNELS_INPUT
    
    if [ -z "$DISCORD_CHANNELS_INPUT" ]; then
        DISCORD_CHANNELS="[]"
    else
        DISCORD_CHANNELS=$(echo "$DISCORD_CHANNELS_INPUT" | sed 's/,/","/g' | sed 's/^/["/' | sed 's/$/"]/')
    fi
    
    print_success "Discord configuration collected"
fi

# =============================================================================
# Telegram Configuration
# =============================================================================
if [ "$SETUP_TELEGRAM" = true ]; then
    print_header "Telegram Bot Configuration"
    
    echo "To use Poracle with Telegram, you need to create a Telegram Bot."
    echo ""
    echo "How to create a Telegram Bot:"
    echo "  1. Open Telegram and search for @BotFather"
    echo "  2. Send /newbot command"
    echo "  3. Follow the prompts to name your bot"
    echo "  4. BotFather will give you an API token - copy it"
    echo ""
    
    # Bot Token
    echo -e "${CYAN}Telegram Bot Token${NC}"
    echo "This is the API token from BotFather (looks like: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz)"
    echo ""
    read -p "Enter your Telegram Bot Token: " TELEGRAM_TOKEN
    
    if [ -z "$TELEGRAM_TOKEN" ]; then
        print_error "Telegram Bot Token is required"
        exit 1
    fi
    
    echo ""
    
    # Admin User IDs
    echo -e "${CYAN}Admin User ID(s)${NC}"
    echo "Admins can manage Poracle settings and have full control."
    echo ""
    echo "How to get your Telegram User ID:"
    echo "  1. Search for @userinfobot on Telegram"
    echo "  2. Start a chat and it will show your User ID"
    echo "  Alternative: Search for @getmyid_bot"
    echo ""
    echo "Enter admin Telegram User IDs (comma-separated for multiple)"
    echo "Example: 123456789,987654321"
    echo ""
    read -p "Enter Admin User ID(s): " TELEGRAM_ADMINS_INPUT
    
    if [ -z "$TELEGRAM_ADMINS_INPUT" ]; then
        print_warning "No admin IDs provided. You can add them later in the config file."
        TELEGRAM_ADMINS="[]"
    else
        # Convert comma-separated to JSON array (Telegram IDs are numbers, not strings)
        TELEGRAM_ADMINS=$(echo "$TELEGRAM_ADMINS_INPUT" | sed 's/,/,/g' | sed 's/^/[/' | sed 's/$/]/')
    fi
    
    echo ""
    
    # Allowed Channels/Groups (optional)
    echo -e "${CYAN}Allowed Chat ID(s) (Optional)${NC}"
    echo "Restrict which chats/groups the bot responds in."
    echo "Leave empty to allow the bot to work in all chats."
    echo ""
    echo "How to get a Chat ID:"
    echo "  1. Add @getmyid_bot to your group"
    echo "  2. It will show the group's Chat ID"
    echo ""
    read -p "Enter Chat ID(s) [leave empty for all]: " TELEGRAM_CHANNELS_INPUT
    
    if [ -z "$TELEGRAM_CHANNELS_INPUT" ]; then
        TELEGRAM_CHANNELS="[]"
    else
        TELEGRAM_CHANNELS=$(echo "$TELEGRAM_CHANNELS_INPUT" | sed 's/,/,/g' | sed 's/^/[/' | sed 's/$/]/')
    fi
    
    print_success "Telegram configuration collected"
fi

# =============================================================================
# Notification Preferences
# =============================================================================
print_header "Notification Types"

echo "Choose which types of notifications to enable by default."
echo "Users can still customize their personal preferences."
echo ""
echo "Enter 'y' for yes or 'n' for no (press Enter for default)"
echo ""

read -p "Enable Pokemon spawn alerts? [Y/n]: " ENABLE_POKEMON
ENABLE_POKEMON=${ENABLE_POKEMON:-y}
[ "$ENABLE_POKEMON" = "y" ] || [ "$ENABLE_POKEMON" = "Y" ] && POKEMON_ENABLED=true || POKEMON_ENABLED=false

read -p "Enable Raid alerts? [Y/n]: " ENABLE_RAIDS
ENABLE_RAIDS=${ENABLE_RAIDS:-y}
[ "$ENABLE_RAIDS" = "y" ] || [ "$ENABLE_RAIDS" = "Y" ] && RAIDS_ENABLED=true || RAIDS_ENABLED=false

read -p "Enable Quest alerts? [Y/n]: " ENABLE_QUESTS
ENABLE_QUESTS=${ENABLE_QUESTS:-y}
[ "$ENABLE_QUESTS" = "y" ] || [ "$ENABLE_QUESTS" = "Y" ] && QUESTS_ENABLED=true || QUESTS_ENABLED=false

read -p "Enable Team Rocket invasion alerts? [Y/n]: " ENABLE_INVASIONS
ENABLE_INVASIONS=${ENABLE_INVASIONS:-y}
[ "$ENABLE_INVASIONS" = "y" ] || [ "$ENABLE_INVASIONS" = "Y" ] && INVASIONS_ENABLED=true || INVASIONS_ENABLED=false

read -p "Enable Nest alerts? [y/N]: " ENABLE_NESTS
ENABLE_NESTS=${ENABLE_NESTS:-n}
[ "$ENABLE_NESTS" = "y" ] || [ "$ENABLE_NESTS" = "Y" ] && NESTS_ENABLED=true || NESTS_ENABLED=false

read -p "Enable Lure alerts? [y/N]: " ENABLE_LURES
ENABLE_LURES=${ENABLE_LURES:-n}
[ "$ENABLE_LURES" = "y" ] || [ "$ENABLE_LURES" = "Y" ] && LURES_ENABLED=true || LURES_ENABLED=false

read -p "Enable Gym alerts? [y/N]: " ENABLE_GYMS
ENABLE_GYMS=${ENABLE_GYMS:-n}
[ "$ENABLE_GYMS" = "y" ] || [ "$ENABLE_GYMS" = "Y" ] && GYMS_ENABLED=true || GYMS_ENABLED=false

read -p "Enable Weather alerts? [y/N]: " ENABLE_WEATHER
ENABLE_WEATHER=${ENABLE_WEATHER:-n}
[ "$ENABLE_WEATHER" = "y" ] || [ "$ENABLE_WEATHER" = "Y" ] && WEATHER_ENABLED=true || WEATHER_ENABLED=false

# =============================================================================
# Language Selection
# =============================================================================
print_header "Language"

echo "Select the language for Poracle messages:"
echo ""
echo "  en - English"
echo "  de - German"
echo "  fr - French"
echo "  es - Spanish"
echo "  it - Italian"
echo "  ja - Japanese"
echo "  ko - Korean"
echo "  pt-br - Portuguese (Brazil)"
echo "  zh-tw - Chinese (Traditional)"
echo ""
read -p "Enter language code [default: en]: " LOCALE
LOCALE=${LOCALE:-en}

# =============================================================================
# Generate Configuration
# =============================================================================
print_header "Generating Configuration"

# Backup original config
print_info "Creating backup of current configuration..."
cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"

# Get database user from .env or default
DB_USER=${MYSQL_USER:-dbuser}

# Build the new configuration
print_info "Building new configuration..."

cat > "$CONFIG_FILE" << EOF
{
  "database": {
    "client": "mysql",
    "conn": {
      "host": "database",
      "port": 3306,
      "user": "$DB_USER",
      "password": "$MYSQL_PASSWORD",
      "database": "poracle"
    }
  },
  "server": {
    "host": "0.0.0.0",
    "port": 3030
  },
  "general": {
    "locale": "$LOCALE",
    "pokemon": $POKEMON_ENABLED,
    "pokestops": true,
    "lures": $LURES_ENABLED,
    "pokestopLures": $LURES_ENABLED,
    "invasions": $INVASIONS_ENABLED,
    "pokestopInvasions": $INVASIONS_ENABLED,
    "gyms": $GYMS_ENABLED,
    "raids": $RAIDS_ENABLED,
    "nests": $NESTS_ENABLED,
    "quests": $QUESTS_ENABLED,
    "weather": $WEATHER_ENABLED,
    "greeting": true,
    "alterPokemon": true,
    "roleCheckDPokemon": false,
    "monsterDefaults": {},
    "raidDefaults": {},
    "eggDefaults": {},
    "questDefaults": {},
    "lureDefaults": {},
    "invasionDefaults": {},
    "nestDefaults": {},
    "gymDefaults": {},
    "weatherDefaults": {}
  },
  "discord": {
    "enabled": $SETUP_DISCORD,
    "prefix": ["$DISCORD_PREFIX"],
    "token": ["${DISCORD_TOKEN:-YOUR_DISCORD_BOT_TOKEN}"],
    "channels": ${DISCORD_CHANNELS:-[]},
    "admins": ${DISCORD_ADMINS:-[]},
    "limitSec": 0,
    "limitAmount": 0,
    "pokemonRole": [],
    "pokestopRole": [],
    "invasionRole": [],
    "lureRole": [],
    "questRole": [],
    "gymRole": [],
    "raidRole": [],
    "eggRole": [],
    "nestRole": [],
    "weatherRole": []
  },
  "telegram": {
    "enabled": $SETUP_TELEGRAM,
    "token": "${TELEGRAM_TOKEN:-YOUR_TELEGRAM_BOT_TOKEN}",
    "channels": ${TELEGRAM_CHANNELS:-[]},
    "admins": ${TELEGRAM_ADMINS:-[]},
    "pokemonRole": [],
    "pokestopRole": [],
    "invasionRole": [],
    "lureRole": [],
    "questRole": [],
    "gymRole": [],
    "raidRole": [],
    "eggRole": [],
    "nestRole": [],
    "weatherRole": []
  },
  "geocoding": {
    "provider": "nominatim",
    "providerURL": "https://nominatim.openstreetmap.org/",
    "cacheDetail": "city"
  },
  "logging": {
    "logLevel": "info"
  },
  "pvp": {
    "pokemon": true,
    "pokemon_best": true,
    "pokemon_worst": true,
    "pokemon_value": true
  }
}
EOF

print_success "Configuration file generated"

# =============================================================================
# Enable in Docker Compose
# =============================================================================
print_header "Enabling Poracle Service"

if grep -q "^# poracle:" docker-compose.yaml; then
    print_info "Uncommenting Poracle in docker-compose.yaml..."
    
    # Uncomment poracle service
    sed -i 's/^# poracle:/poracle:/g' docker-compose.yaml
    sed -i 's/^  # image: ghcr.io\/kartuludus\/poraclejs/  image: ghcr.io\/kartuludus\/poraclejs/g' docker-compose.yaml
    sed -i 's/^  # container_name: poracle/  container_name: poracle/g' docker-compose.yaml
    sed -i 's/^  # restart: unless-stopped/  restart: unless-stopped/g' docker-compose.yaml
    sed -i 's/^  # depends_on:/  depends_on:/g' docker-compose.yaml
    sed -i 's/^    # - database/    - database/g' docker-compose.yaml
    sed -i 's/^  # volumes:/  volumes:/g' docker-compose.yaml
    sed -i 's/^    # - .\/Poracle/    - .\/Poracle/g' docker-compose.yaml
    sed -i 's/^    # - \/etc\/localtime/    - \/etc\/localtime/g' docker-compose.yaml
    sed -i 's/^  # ports:/  ports:/g' docker-compose.yaml
    sed -i 's/^    # - 6007:3030/    - 6007:3030/g' docker-compose.yaml
    sed -i 's/^  # environment:/  environment:/g' docker-compose.yaml
    sed -i 's/^    # - NODE_ENV=production/    - NODE_ENV=production/g' docker-compose.yaml
    
    print_success "Poracle enabled in docker-compose.yaml"
else
    print_info "Poracle already enabled in docker-compose.yaml"
fi

# =============================================================================
# Configure Golbat Webhook (optional)
# =============================================================================
print_header "Golbat Webhook Configuration"

echo "For Poracle to receive Pokemon data, Golbat needs to send webhooks to it."
echo ""
read -p "Would you like to add Poracle webhook to Golbat config? (y/n) [y]: " ADD_WEBHOOK
ADD_WEBHOOK=${ADD_WEBHOOK:-y}

if [ "$ADD_WEBHOOK" = "y" ] || [ "$ADD_WEBHOOK" = "Y" ]; then
    GOLBAT_CONFIG="unown/golbat_config.toml"
    
    if [ -f "$GOLBAT_CONFIG" ]; then
        # Check if webhook already exists
        if grep -q "poracle:3030" "$GOLBAT_CONFIG"; then
            print_info "Poracle webhook already configured in Golbat"
        else
            print_info "Adding Poracle webhook to Golbat config..."
            
            # Add webhook configuration at end of file
            cat >> "$GOLBAT_CONFIG" << 'EOF'

# Poracle webhook for Discord/Telegram notifications
[[webhooks]]
url = "http://poracle:3030"
types = ["pokemon_iv", "pokemon_no_iv", "raid", "quest", "invasion", "pokestop", "gym", "weather", "nest"]
EOF
            
            print_success "Poracle webhook added to Golbat config"
            print_warning "Remember to restart Golbat: docker compose restart golbat"
        fi
    else
        print_warning "Golbat config not found. You'll need to manually add the webhook."
        echo ""
        echo "Add this to your golbat_config.toml:"
        echo ""
        echo '[[webhooks]]'
        echo 'url = "http://poracle:3030"'
        echo 'types = ["pokemon_iv", "pokemon_no_iv", "raid", "quest", "invasion", "pokestop", "gym", "weather", "nest"]'
    fi
fi

# =============================================================================
# Restore File Ownership
# =============================================================================
print_info "Restoring file ownership..."
chown "$REAL_USER:$REAL_GROUP" "$CONFIG_FILE" 2>/dev/null || true
chown "$REAL_USER:$REAL_GROUP" "${CONFIG_FILE}.backup."* 2>/dev/null || true
chown "$REAL_USER:$REAL_GROUP" docker-compose.yaml 2>/dev/null || true
chown "$REAL_USER:$REAL_GROUP" unown/golbat_config.toml 2>/dev/null || true
print_success "File ownership restored"

# =============================================================================
# Start Container
# =============================================================================
print_header "Starting Poracle"

read -p "Would you like to start the Poracle container now? (y/n) [y]: " START_NOW
START_NOW=${START_NOW:-y}

if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
    # Detect docker compose command
    if docker compose version &> /dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        print_error "Docker Compose not found"
        exit 1
    fi
    
    print_info "Starting Poracle container..."
    $COMPOSE_CMD up -d poracle
    
    if [ $? -eq 0 ]; then
        print_success "Poracle container started!"
        
        # Wait for container to initialize
        print_info "Waiting for Poracle to initialize..."
        sleep 5
        
        # Check if running
        if docker ps | grep -q poracle; then
            print_success "Poracle is running!"
        else
            print_warning "Poracle may have failed to start. Check logs with:"
            echo "  docker compose logs poracle"
        fi
    else
        print_error "Failed to start Poracle container"
    fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================================="
print_success "Poracle Setup Complete!"
echo "=============================================="
echo ""
echo "  Configuration Summary:"
echo "  ├── Config File: $CONFIG_FILE"
echo "  ├── Language: $LOCALE"
if [ "$SETUP_DISCORD" = true ]; then
echo "  ├── Discord: Enabled"
echo "  │   ├── Prefix: $DISCORD_PREFIX"
echo "  │   └── Token: ****${DISCORD_TOKEN: -8}"
fi
if [ "$SETUP_TELEGRAM" = true ]; then
echo "  ├── Telegram: Enabled"
echo "  │   └── Token: ****${TELEGRAM_TOKEN: -8}"
fi
echo "  └── Port: 6007"
echo ""
echo "  Enabled Notifications:"
echo "  ├── Pokemon: $POKEMON_ENABLED"
echo "  ├── Raids: $RAIDS_ENABLED"
echo "  ├── Quests: $QUESTS_ENABLED"
echo "  ├── Invasions: $INVASIONS_ENABLED"
echo "  ├── Nests: $NESTS_ENABLED"
echo "  ├── Lures: $LURES_ENABLED"
echo "  ├── Gyms: $GYMS_ENABLED"
echo "  └── Weather: $WEATHER_ENABLED"
echo ""

print_header "Next Steps"

if [ "$SETUP_DISCORD" = true ]; then
    echo "Discord Setup:"
    echo "  1. Make sure your bot is invited to your Discord server"
    echo "  2. In Discord, type: ${DISCORD_PREFIX}help"
    echo "  3. Set your location: ${DISCORD_PREFIX}location <address>"
    echo "  4. Start tracking: ${DISCORD_PREFIX}track pokemon pikachu"
    echo ""
fi

if [ "$SETUP_TELEGRAM" = true ]; then
    echo "Telegram Setup:"
    echo "  1. Start a chat with your bot on Telegram"
    echo "  2. Send: /help"
    echo "  3. Set your location: /location <address>"
    echo "  4. Start tracking: /track pokemon pikachu"
    echo ""
fi

echo "Useful Commands:"
echo "  View logs:      docker compose logs -f poracle"
echo "  Restart:        docker compose restart poracle"
echo "  Stop:           docker compose stop poracle"
echo "  Edit config:    nano $CONFIG_FILE"
echo ""
echo "Documentation:"
echo "  https://poracle.pokemon.pokemon.pokemon/"
echo "  https://github.com/KartulUdus/PoracleJS"
echo ""

if [ "$ADD_WEBHOOK" = "y" ] || [ "$ADD_WEBHOOK" = "Y" ]; then
    print_warning "Don't forget to restart Golbat to enable webhooks:"
    echo "  docker compose restart golbat"
    echo ""
fi

print_success "Enjoy your Pokemon alerts!"

