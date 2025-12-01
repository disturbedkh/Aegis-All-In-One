#!/bin/bash

# =============================================================================
# Shellder - Poracle Setup Script for Aegis AIO
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

# Source Shellder logging helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELLDER_SCRIPT_NAME="poracle.sh"
if [ -f "$SCRIPT_DIR/log_helper.sh" ]; then
    source "$SCRIPT_DIR/log_helper.sh"
    init_logging "poracle.sh"
    LOG_AVAILABLE=true
else
    LOG_AVAILABLE=false
fi

# Return to main menu function
return_to_main() {
    if [ "$SHELLDER_LAUNCHER" = "1" ]; then
        echo ""
        echo -e "${CYAN}Returning to Shellder Control Panel...${NC}"
        sleep 1
    fi
    exit 0
}

# Get the original user who called sudo (to fix file ownership later)
# Check if REAL_USER was passed from shellder.sh (preferred), otherwise use SUDO_USER
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    # REAL_USER was passed from shellder.sh - use it
    if [ -z "$REAL_GROUP" ]; then
        REAL_GROUP=$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")
    fi
elif [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    REAL_GROUP=$(id -gn "$SUDO_USER")
else
    REAL_USER="$USER"
    REAL_GROUP=$(id -gn)
fi

# Ensure we have a valid user
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    DIR_OWNER=$(stat -c '%U' "$PWD" 2>/dev/null || ls -ld "$PWD" | awk '{print $3}')
    if [ -n "$DIR_OWNER" ] && [ "$DIR_OWNER" != "root" ]; then
        REAL_USER="$DIR_OWNER"
        REAL_GROUP=$(id -gn "$DIR_OWNER" 2>/dev/null || echo "$DIR_OWNER")
    fi
fi

# Set up trap to restore ownership on exit
cleanup_on_exit() {
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        chown "$REAL_USER:$REAL_GROUP" docker-compose.yaml Shellder/*.sh *.yaml *.yml *.md 2>/dev/null || true
        chown -R "$REAL_USER:$REAL_GROUP" Poracle unown 2>/dev/null || true
    fi
}
trap cleanup_on_exit EXIT

# =============================================================================
# Helper Functions for JSON Parsing
# =============================================================================

# Extract simple string value from JSON
# Excludes keys starting with underscore (like _explanation, _description)
get_json_string() {
    local file=$1
    local key=$2
    # Match exact key (not _key_explanation variants) and extract value
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | grep -v "\"_${key}\|\"_.*_${key}" | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/'
}

# Extract boolean value from JSON
get_json_bool() {
    local file=$1
    local key=$2
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\(true\|false\)" "$file" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*\(true\|false\).*/\1/'
}

# Extract array from JSON (simple single-line arrays)
get_json_array() {
    local file=$1
    local key=$2
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\[[^]]*\]" "$file" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*\(\[[^]]*\]\).*/\1/'
}

# Extract first element of token array (for Discord which uses array)
get_json_token_array() {
    local file=$1
    local key=$2
    local arr=$(get_json_array "$file" "$key")
    echo "$arr" | sed 's/\["\([^"]*\)".*/\1/'
}

# Check if a value is a placeholder
is_placeholder() {
    local value=$1
    if [[ "$value" == *"YOUR_"* ]] || \
       [[ "$value" == *"CHANGE_ME"* ]] || \
       [[ "$value" == *"SuperSecure"* ]] || \
       [[ -z "$value" ]]; then
        return 0
    fi
    return 1
}

echo ""
echo "=============================================="
echo "  Poracle Setup - Pokemon Alert Notifications"
echo "  Shellder for Aegis AIO by The Pokemod Group"
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
    print_info "Run: sudo bash Shellder/setup.sh"
    exit 1
fi

print_success "Found .env file"

# Source .env for database password (skip UID/GID which are readonly bash variables)
while IFS='=' read -r key value; do
    # Skip comments, empty lines, and readonly variables (UID, GID)
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    [[ "$key" == "UID" ]] && continue
    [[ "$key" == "GID" ]] && continue
    export "$key=$value"
done < .env

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
# Parse Existing Configuration
# =============================================================================
print_header "Detecting Existing Configuration"

# Parse existing values from Poracle config
EXISTING_DISCORD_ENABLED=$(get_json_bool "$CONFIG_FILE" "enabled" | head -1)
EXISTING_DISCORD_TOKEN=$(get_json_token_array "$CONFIG_FILE" "token")
EXISTING_DISCORD_PREFIX=$(get_json_token_array "$CONFIG_FILE" "prefix")
EXISTING_DISCORD_ADMINS=$(get_json_array "$CONFIG_FILE" "admins" | head -1)
EXISTING_DISCORD_CHANNELS=$(grep -A5 '"discord"' "$CONFIG_FILE" | grep -o '"channels"[[:space:]]*:[[:space:]]*\[[^]]*\]' | head -1 | sed 's/.*:\s*\(\[.*\]\)/\1/')

# Telegram config (appears after discord section)
EXISTING_TELEGRAM_TOKEN=$(grep -A20 '"telegram"' "$CONFIG_FILE" | grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:\s*"\([^"]*\)".*/\1/')
EXISTING_TELEGRAM_ADMINS=$(grep -A20 '"telegram"' "$CONFIG_FILE" | grep -o '"admins"[[:space:]]*:[[:space:]]*\[[^]]*\]' | head -1 | sed 's/.*:\s*\(\[.*\]\)/\1/')
EXISTING_TELEGRAM_CHANNELS=$(grep -A20 '"telegram"' "$CONFIG_FILE" | grep -o '"channels"[[:space:]]*:[[:space:]]*\[[^]]*\]' | head -1 | sed 's/.*:\s*\(\[.*\]\)/\1/')
EXISTING_TELEGRAM_ENABLED=$(grep -A5 '"telegram"' "$CONFIG_FILE" | grep -o '"enabled"[[:space:]]*:[[:space:]]*\(true\|false\)' | head -1 | sed 's/.*:\s*\(true\|false\)/\1/')

# General settings
EXISTING_LOCALE=$(get_json_string "$CONFIG_FILE" "locale")
EXISTING_POKEMON=$(get_json_bool "$CONFIG_FILE" "pokemon")
EXISTING_RAIDS=$(get_json_bool "$CONFIG_FILE" "raids")
EXISTING_QUESTS=$(get_json_bool "$CONFIG_FILE" "quests")
EXISTING_INVASIONS=$(get_json_bool "$CONFIG_FILE" "invasions")
EXISTING_NESTS=$(get_json_bool "$CONFIG_FILE" "nests")
EXISTING_LURES=$(get_json_bool "$CONFIG_FILE" "lures")
EXISTING_GYMS=$(get_json_bool "$CONFIG_FILE" "gyms")
EXISTING_WEATHER=$(get_json_bool "$CONFIG_FILE" "weather")

# Database config from existing file
EXISTING_DB_USER=$(get_json_string "$CONFIG_FILE" "user")
EXISTING_DB_PASS=$(get_json_string "$CONFIG_FILE" "password")

# Display detected values
echo "Detected existing configuration:"
echo ""

# Check Discord
if [ "$EXISTING_DISCORD_ENABLED" = "true" ] && ! is_placeholder "$EXISTING_DISCORD_TOKEN"; then
    print_success "Discord: Configured (token ends with ...${EXISTING_DISCORD_TOKEN: -8})"
    DISCORD_PRECONFIGURED=true
else
    print_info "Discord: Not configured"
    DISCORD_PRECONFIGURED=false
fi

# Check Telegram
if [ "$EXISTING_TELEGRAM_ENABLED" = "true" ] && ! is_placeholder "$EXISTING_TELEGRAM_TOKEN"; then
    print_success "Telegram: Configured (token ends with ...${EXISTING_TELEGRAM_TOKEN: -8})"
    TELEGRAM_PRECONFIGURED=true
else
    print_info "Telegram: Not configured"
    TELEGRAM_PRECONFIGURED=false
fi

# Check database consistency
if [ "$EXISTING_DB_PASS" = "$MYSQL_PASSWORD" ]; then
    print_success "Database password: Matches .env"
else
    print_warning "Database password: Will be updated from .env"
fi

if [ -n "$EXISTING_LOCALE" ]; then
    print_info "Language: $EXISTING_LOCALE"
fi

echo ""

# =============================================================================
# Platform Selection
# =============================================================================
print_header "Select Messaging Platform"

echo "Poracle can send notifications to Discord, Telegram, or both."
echo ""

# Show current status
if [ "$DISCORD_PRECONFIGURED" = true ] || [ "$TELEGRAM_PRECONFIGURED" = true ]; then
    echo "Current configuration detected:"
    [ "$DISCORD_PRECONFIGURED" = true ] && echo "  • Discord is currently enabled"
    [ "$TELEGRAM_PRECONFIGURED" = true ] && echo "  • Telegram is currently enabled"
    echo ""
fi

echo "Which platform(s) would you like to configure?"
echo ""
echo "  1) Discord only"
echo "  2) Telegram only"
echo "  3) Both Discord and Telegram"

# Suggest default based on existing config
if [ "$DISCORD_PRECONFIGURED" = true ] && [ "$TELEGRAM_PRECONFIGURED" = true ]; then
    DEFAULT_PLATFORM=3
elif [ "$TELEGRAM_PRECONFIGURED" = true ]; then
    DEFAULT_PLATFORM=2
else
    DEFAULT_PLATFORM=1
fi

echo ""
read -p "Select option [1-3, default: $DEFAULT_PLATFORM]: " PLATFORM_CHOICE
PLATFORM_CHOICE=${PLATFORM_CHOICE:-$DEFAULT_PLATFORM}

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
    
    # Show existing values if available
    if [ "$DISCORD_PRECONFIGURED" = true ]; then
        echo -e "${GREEN}Existing Discord configuration detected!${NC}"
        echo "Press Enter to keep existing values, or enter new values to update."
        echo ""
    else
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
    fi
    
    # Bot Token
    echo -e "${CYAN}Discord Bot Token${NC}"
    echo "This is the secret token that allows Poracle to control your bot."
    echo "Keep this private! Never share it publicly."
    
    if ! is_placeholder "$EXISTING_DISCORD_TOKEN"; then
        echo -e "Current: ${GREEN}****${EXISTING_DISCORD_TOKEN: -8}${NC}"
        read -p "Enter new Discord Bot Token [Enter to keep current]: " DISCORD_TOKEN_INPUT
        DISCORD_TOKEN=${DISCORD_TOKEN_INPUT:-$EXISTING_DISCORD_TOKEN}
    else
        echo ""
        read -p "Enter your Discord Bot Token: " DISCORD_TOKEN
    fi
    
    if [ -z "$DISCORD_TOKEN" ]; then
        print_error "Discord Bot Token is required"
        exit 1
    fi
    
    echo ""
    
    # Command Prefix
    echo -e "${CYAN}Command Prefix${NC}"
    echo "This is the character users type before commands (e.g., !track pikachu)"
    echo "Common choices: ! . $ ?"
    
    EXISTING_PREFIX=${EXISTING_DISCORD_PREFIX:-!}
    read -p "Enter command prefix [default: $EXISTING_PREFIX]: " DISCORD_PREFIX_INPUT
    DISCORD_PREFIX=${DISCORD_PREFIX_INPUT:-$EXISTING_PREFIX}
    
    echo ""
    
    # Admin User IDs
    echo -e "${CYAN}Admin User ID(s)${NC}"
    echo "Admins can manage Poracle settings and have full control."
    echo ""
    echo "How to get your Discord User ID:"
    echo "  1. Enable Developer Mode in Discord (Settings > Advanced > Developer Mode)"
    echo "  2. Right-click on your username and select 'Copy ID'"
    echo ""
    
    # Show existing admins
    if [ -n "$EXISTING_DISCORD_ADMINS" ] && [ "$EXISTING_DISCORD_ADMINS" != "[]" ]; then
        echo -e "Current admins: ${GREEN}$EXISTING_DISCORD_ADMINS${NC}"
        echo "Enter new IDs to replace, or press Enter to keep current"
    fi
    
    echo "Enter admin Discord User IDs (comma-separated for multiple)"
    echo "Example: 123456789012345678,987654321098765432"
    read -p "Admin User ID(s): " DISCORD_ADMINS_INPUT
    
    if [ -z "$DISCORD_ADMINS_INPUT" ]; then
        if [ -n "$EXISTING_DISCORD_ADMINS" ] && [ "$EXISTING_DISCORD_ADMINS" != "[]" ]; then
            DISCORD_ADMINS="$EXISTING_DISCORD_ADMINS"
        else
            print_warning "No admin IDs provided. You can add them later in the config file."
            DISCORD_ADMINS="[]"
        fi
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
    
    if [ -n "$EXISTING_DISCORD_CHANNELS" ] && [ "$EXISTING_DISCORD_CHANNELS" != "[]" ]; then
        echo -e "Current channels: ${GREEN}$EXISTING_DISCORD_CHANNELS${NC}"
    fi
    
    read -p "Enter Channel ID(s) [leave empty for all/keep current]: " DISCORD_CHANNELS_INPUT
    
    if [ -z "$DISCORD_CHANNELS_INPUT" ]; then
        if [ -n "$EXISTING_DISCORD_CHANNELS" ]; then
            DISCORD_CHANNELS="$EXISTING_DISCORD_CHANNELS"
        else
            DISCORD_CHANNELS="[]"
        fi
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
    
    # Show existing values if available
    if [ "$TELEGRAM_PRECONFIGURED" = true ]; then
        echo -e "${GREEN}Existing Telegram configuration detected!${NC}"
        echo "Press Enter to keep existing values, or enter new values to update."
        echo ""
    else
        echo "To use Poracle with Telegram, you need to create a Telegram Bot."
        echo ""
        echo "How to create a Telegram Bot:"
        echo "  1. Open Telegram and search for @BotFather"
        echo "  2. Send /newbot command"
        echo "  3. Follow the prompts to name your bot"
        echo "  4. BotFather will give you an API token - copy it"
        echo ""
    fi
    
    # Bot Token
    echo -e "${CYAN}Telegram Bot Token${NC}"
    echo "This is the API token from BotFather (looks like: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz)"
    
    if ! is_placeholder "$EXISTING_TELEGRAM_TOKEN"; then
        echo -e "Current: ${GREEN}****${EXISTING_TELEGRAM_TOKEN: -8}${NC}"
        read -p "Enter new Telegram Bot Token [Enter to keep current]: " TELEGRAM_TOKEN_INPUT
        TELEGRAM_TOKEN=${TELEGRAM_TOKEN_INPUT:-$EXISTING_TELEGRAM_TOKEN}
    else
        echo ""
        read -p "Enter your Telegram Bot Token: " TELEGRAM_TOKEN
    fi
    
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
    
    if [ -n "$EXISTING_TELEGRAM_ADMINS" ] && [ "$EXISTING_TELEGRAM_ADMINS" != "[]" ]; then
        echo -e "Current admins: ${GREEN}$EXISTING_TELEGRAM_ADMINS${NC}"
        echo "Enter new IDs to replace, or press Enter to keep current"
    fi
    
    echo "Enter admin Telegram User IDs (comma-separated for multiple)"
    echo "Example: 123456789,987654321"
    read -p "Admin User ID(s): " TELEGRAM_ADMINS_INPUT
    
    if [ -z "$TELEGRAM_ADMINS_INPUT" ]; then
        if [ -n "$EXISTING_TELEGRAM_ADMINS" ] && [ "$EXISTING_TELEGRAM_ADMINS" != "[]" ]; then
            TELEGRAM_ADMINS="$EXISTING_TELEGRAM_ADMINS"
        else
            print_warning "No admin IDs provided. You can add them later in the config file."
            TELEGRAM_ADMINS="[]"
        fi
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
    
    if [ -n "$EXISTING_TELEGRAM_CHANNELS" ] && [ "$EXISTING_TELEGRAM_CHANNELS" != "[]" ]; then
        echo -e "Current channels: ${GREEN}$EXISTING_TELEGRAM_CHANNELS${NC}"
    fi
    
    read -p "Enter Chat ID(s) [leave empty for all/keep current]: " TELEGRAM_CHANNELS_INPUT
    
    if [ -z "$TELEGRAM_CHANNELS_INPUT" ]; then
        if [ -n "$EXISTING_TELEGRAM_CHANNELS" ]; then
            TELEGRAM_CHANNELS="$EXISTING_TELEGRAM_CHANNELS"
        else
            TELEGRAM_CHANNELS="[]"
        fi
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
echo "Enter 'y' for yes or 'n' for no (press Enter for default/current)"
echo ""

# Use existing values as defaults, or sensible defaults if not set
DEFAULT_POKEMON=${EXISTING_POKEMON:-true}
DEFAULT_RAIDS=${EXISTING_RAIDS:-true}
DEFAULT_QUESTS=${EXISTING_QUESTS:-true}
DEFAULT_INVASIONS=${EXISTING_INVASIONS:-true}
DEFAULT_NESTS=${EXISTING_NESTS:-false}
DEFAULT_LURES=${EXISTING_LURES:-false}
DEFAULT_GYMS=${EXISTING_GYMS:-false}
DEFAULT_WEATHER=${EXISTING_WEATHER:-false}

# Convert to y/n for display
[ "$DEFAULT_POKEMON" = "true" ] && DEF_POK="Y/n" || DEF_POK="y/N"
[ "$DEFAULT_RAIDS" = "true" ] && DEF_RAID="Y/n" || DEF_RAID="y/N"
[ "$DEFAULT_QUESTS" = "true" ] && DEF_QUEST="Y/n" || DEF_QUEST="y/N"
[ "$DEFAULT_INVASIONS" = "true" ] && DEF_INV="Y/n" || DEF_INV="y/N"
[ "$DEFAULT_NESTS" = "true" ] && DEF_NEST="Y/n" || DEF_NEST="y/N"
[ "$DEFAULT_LURES" = "true" ] && DEF_LURE="Y/n" || DEF_LURE="y/N"
[ "$DEFAULT_GYMS" = "true" ] && DEF_GYM="Y/n" || DEF_GYM="y/N"
[ "$DEFAULT_WEATHER" = "true" ] && DEF_WEATH="Y/n" || DEF_WEATH="y/N"

read -p "Enable Pokemon spawn alerts? [$DEF_POK]: " ENABLE_POKEMON
if [ -z "$ENABLE_POKEMON" ]; then
    POKEMON_ENABLED=$DEFAULT_POKEMON
elif [ "$ENABLE_POKEMON" = "y" ] || [ "$ENABLE_POKEMON" = "Y" ]; then
    POKEMON_ENABLED=true
else
    POKEMON_ENABLED=false
fi

read -p "Enable Raid alerts? [$DEF_RAID]: " ENABLE_RAIDS
if [ -z "$ENABLE_RAIDS" ]; then
    RAIDS_ENABLED=$DEFAULT_RAIDS
elif [ "$ENABLE_RAIDS" = "y" ] || [ "$ENABLE_RAIDS" = "Y" ]; then
    RAIDS_ENABLED=true
else
    RAIDS_ENABLED=false
fi

read -p "Enable Quest alerts? [$DEF_QUEST]: " ENABLE_QUESTS
if [ -z "$ENABLE_QUESTS" ]; then
    QUESTS_ENABLED=$DEFAULT_QUESTS
elif [ "$ENABLE_QUESTS" = "y" ] || [ "$ENABLE_QUESTS" = "Y" ]; then
    QUESTS_ENABLED=true
else
    QUESTS_ENABLED=false
fi

read -p "Enable Team Rocket invasion alerts? [$DEF_INV]: " ENABLE_INVASIONS
if [ -z "$ENABLE_INVASIONS" ]; then
    INVASIONS_ENABLED=$DEFAULT_INVASIONS
elif [ "$ENABLE_INVASIONS" = "y" ] || [ "$ENABLE_INVASIONS" = "Y" ]; then
    INVASIONS_ENABLED=true
else
    INVASIONS_ENABLED=false
fi

read -p "Enable Nest alerts? [$DEF_NEST]: " ENABLE_NESTS
if [ -z "$ENABLE_NESTS" ]; then
    NESTS_ENABLED=$DEFAULT_NESTS
elif [ "$ENABLE_NESTS" = "y" ] || [ "$ENABLE_NESTS" = "Y" ]; then
    NESTS_ENABLED=true
else
    NESTS_ENABLED=false
fi

read -p "Enable Lure alerts? [$DEF_LURE]: " ENABLE_LURES
if [ -z "$ENABLE_LURES" ]; then
    LURES_ENABLED=$DEFAULT_LURES
elif [ "$ENABLE_LURES" = "y" ] || [ "$ENABLE_LURES" = "Y" ]; then
    LURES_ENABLED=true
else
    LURES_ENABLED=false
fi

read -p "Enable Gym alerts? [$DEF_GYM]: " ENABLE_GYMS
if [ -z "$ENABLE_GYMS" ]; then
    GYMS_ENABLED=$DEFAULT_GYMS
elif [ "$ENABLE_GYMS" = "y" ] || [ "$ENABLE_GYMS" = "Y" ]; then
    GYMS_ENABLED=true
else
    GYMS_ENABLED=false
fi

read -p "Enable Weather alerts? [$DEF_WEATH]: " ENABLE_WEATHER
if [ -z "$ENABLE_WEATHER" ]; then
    WEATHER_ENABLED=$DEFAULT_WEATHER
elif [ "$ENABLE_WEATHER" = "y" ] || [ "$ENABLE_WEATHER" = "Y" ]; then
    WEATHER_ENABLED=true
else
    WEATHER_ENABLED=false
fi

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

DEFAULT_LOCALE=${EXISTING_LOCALE:-en}
read -p "Enter language code [default: $DEFAULT_LOCALE]: " LOCALE_INPUT
LOCALE=${LOCALE_INPUT:-$DEFAULT_LOCALE}

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

# Set defaults for platforms not being configured
if [ "$SETUP_DISCORD" = false ]; then
    DISCORD_TOKEN="YOUR_DISCORD_BOT_TOKEN"
    DISCORD_PREFIX="!"
    DISCORD_ADMINS="[]"
    DISCORD_CHANNELS="[]"
fi

if [ "$SETUP_TELEGRAM" = false ]; then
    TELEGRAM_TOKEN="YOUR_TELEGRAM_BOT_TOKEN"
    TELEGRAM_ADMINS="[]"
    TELEGRAM_CHANNELS="[]"
fi

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
    "token": ["$DISCORD_TOKEN"],
    "channels": $DISCORD_CHANNELS,
    "admins": $DISCORD_ADMINS,
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
    "token": "$TELEGRAM_TOKEN",
    "channels": $TELEGRAM_CHANNELS,
    "admins": $TELEGRAM_ADMINS,
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

GOLBAT_CONFIG="unown/golbat_config.toml"
WEBHOOK_EXISTS=false

# Check if webhook already exists
if [ -f "$GOLBAT_CONFIG" ]; then
    if grep -q "poracle:3030" "$GOLBAT_CONFIG"; then
        WEBHOOK_EXISTS=true
        print_success "Poracle webhook already configured in Golbat"
    fi
fi

if [ "$WEBHOOK_EXISTS" = false ]; then
    echo "For Poracle to receive Pokemon data, Golbat needs to send webhooks to it."
    echo ""
    read -p "Would you like to add Poracle webhook to Golbat config? (y/n) [y]: " ADD_WEBHOOK
    ADD_WEBHOOK=${ADD_WEBHOOK:-y}
    
    if [ "$ADD_WEBHOOK" = "y" ] || [ "$ADD_WEBHOOK" = "Y" ]; then
        if [ -f "$GOLBAT_CONFIG" ]; then
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
else
    ADD_WEBHOOK="n"
fi

# =============================================================================
# Restore File Ownership
# =============================================================================
print_info "Restoring file ownership..."
chown "$REAL_USER:$REAL_GROUP" "$CONFIG_FILE" 2>/dev/null || true
chown "$REAL_USER:$REAL_GROUP" "${CONFIG_FILE}.backup."* 2>/dev/null || true
chown "$REAL_USER:$REAL_GROUP" docker-compose.yaml 2>/dev/null || true
chown "$REAL_USER:$REAL_GROUP" "$GOLBAT_CONFIG" 2>/dev/null || true
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
echo "  ├── Database User: $DB_USER"
echo "  ├── Database: poracle"
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
echo "  https://github.com/KartulUdus/PoracleJS"
echo ""

if [ "$ADD_WEBHOOK" = "y" ] || [ "$ADD_WEBHOOK" = "Y" ]; then
    print_warning "Don't forget to restart Golbat to enable webhooks:"
    echo "  docker compose restart golbat"
    echo ""
fi

print_success "Enjoy your Pokemon alerts!"

# Return to main menu or exit
if [ "$SHELLDER_LAUNCHER" = "1" ]; then
    echo ""
    read -p "Press Enter to return to main menu..."
    return_to_main
fi
