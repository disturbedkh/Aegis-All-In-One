#!/bin/bash

# =============================================================================
# Shellder - File System Manager for Aegis AIO
# =============================================================================
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  Complete file system management for your Aegis AIO installation       │
# │                                                                         │
# │  Features:                                                              │
# │    • Browse and view files                                             │
# │    • Detect missing/deleted files                                      │
# │    • Restore files from GitHub                                         │
# │    • Compare local files with GitHub versions                          │
# │    • Monitor for upstream updates                                      │
# │    • Manage Git merges and conflicts                                   │
# │    • Backup and restore configurations                                 │
# └─────────────────────────────────────────────────────────────────────────┘
#
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Print functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Box drawing
draw_box_top() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
}
draw_box_bottom() {
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
}
draw_box_line() {
    printf "${CYAN}║${NC} %-72s ${CYAN}║${NC}\n" "$1"
}

# Source helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELLDER_SCRIPT_NAME="files.sh"

if [ -f "$SCRIPT_DIR/log_helper.sh" ]; then
    source "$SCRIPT_DIR/log_helper.sh"
    init_logging "files.sh"
    LOG_AVAILABLE=true
else
    LOG_AVAILABLE=false
fi

if [ -f "$SCRIPT_DIR/db_helper.sh" ]; then
    source "$SCRIPT_DIR/db_helper.sh"
    DB_AVAILABLE=true
else
    DB_AVAILABLE=false
fi

# GitHub repository info
GITHUB_REPO="disturbedkh/Aegis-All-In-One"
GITHUB_BRANCH="main"
GITHUB_RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}"

# Get original user
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
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

# Return to main menu
return_to_main() {
    if [ "$SHELLDER_LAUNCHER" = "1" ]; then
        echo ""
        echo -e "${CYAN}Returning to Shellder Control Panel...${NC}"
        sleep 1
    fi
    exit 0
}

press_enter() {
    echo ""
    read -p "  Press Enter to continue..."
}

# =============================================================================
# CORE FILE LISTS
# =============================================================================

# Essential Aegis AIO files that should exist
declare -a ESSENTIAL_FILES=(
    "docker-compose.yaml"
    ".env"
    "shellder.sh"
    "env-default"
    "init/01.sql"
)

# Shell scripts
declare -a SHELL_SCRIPTS=(
    "shellder.sh"
    "Shellder/setup.sh"
    "Shellder/check.sh"
    "Shellder/dbsetup.sh"
    "Shellder/logs.sh"
    "Shellder/nginx-setup.sh"
    "Shellder/poracle.sh"
    "Shellder/fletchling.sh"
    "Shellder/files.sh"
    "Shellder/db_helper.sh"
    "Shellder/log_helper.sh"
)

# Config files (templates)
declare -a CONFIG_TEMPLATES=(
    "env-default"
    "unown/dragonite_config-default.toml"
    "unown/golbat_config-default.toml"
    "unown/rotom_config-default.json"
    "reactmap/local-default.json"
    "mysql_data/mariadb.cnf"
)

# User config files (should NOT be overwritten without confirmation)
declare -a USER_CONFIGS=(
    ".env"
    "unown/dragonite_config.toml"
    "unown/golbat_config.toml"
    "unown/rotom_config.json"
    "reactmap/local.json"
    "proxy.txt"
)

# =============================================================================
# GIT FUNCTIONS
# =============================================================================

# Check if we're in a git repository
check_git_repo() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Get current git status
get_git_status() {
    if ! check_git_repo; then
        echo "not_a_repo"
        return
    fi
    
    local status=""
    
    # Check for uncommitted changes
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        status="modified"
    fi
    
    # Check if behind remote
    git fetch origin "$GITHUB_BRANCH" --quiet 2>/dev/null
    local behind=$(git rev-list HEAD..origin/$GITHUB_BRANCH --count 2>/dev/null)
    local ahead=$(git rev-list origin/$GITHUB_BRANCH..HEAD --count 2>/dev/null)
    
    if [ "$behind" -gt 0 ] && [ "$ahead" -gt 0 ]; then
        echo "diverged:$behind:$ahead"
    elif [ "$behind" -gt 0 ]; then
        echo "behind:$behind"
    elif [ "$ahead" -gt 0 ]; then
        echo "ahead:$ahead"
    elif [ -n "$status" ]; then
        echo "$status"
    else
        echo "up_to_date"
    fi
}

# Get list of changed files from remote
get_remote_changes() {
    git fetch origin "$GITHUB_BRANCH" --quiet 2>/dev/null
    git diff --name-only HEAD..origin/$GITHUB_BRANCH 2>/dev/null
}

# Get list of locally modified files
get_local_modifications() {
    git diff --name-only 2>/dev/null
    git diff --name-only --cached 2>/dev/null
}

# Get list of untracked files
get_untracked_files() {
    git ls-files --others --exclude-standard 2>/dev/null
}

# =============================================================================
# FILE DETECTION FUNCTIONS
# =============================================================================

# Check if a file exists in the GitHub repo
file_exists_on_github() {
    local file="$1"
    local url="${GITHUB_RAW_URL}/${file}"
    
    if curl --output /dev/null --silent --head --fail "$url"; then
        return 0
    else
        return 1
    fi
}

# Get file from GitHub
get_file_from_github() {
    local file="$1"
    local url="${GITHUB_RAW_URL}/${file}"
    
    curl -sL "$url" 2>/dev/null
}

# Find missing essential files
find_missing_files() {
    local missing=()
    
    for file in "${ESSENTIAL_FILES[@]}"; do
        if [ ! -f "$file" ]; then
            missing+=("$file")
        fi
    done
    
    for file in "${SHELL_SCRIPTS[@]}"; do
        if [ ! -f "$file" ]; then
            missing+=("$file")
        fi
    done
    
    echo "${missing[@]}"
}

# Find deleted files (were tracked by git but now missing)
find_deleted_files() {
    if ! check_git_repo; then
        return
    fi
    
    git ls-files --deleted 2>/dev/null
}

# Compare local file with GitHub version
compare_with_github() {
    local file="$1"
    
    if [ ! -f "$file" ]; then
        echo "missing_local"
        return
    fi
    
    local github_content=$(get_file_from_github "$file")
    if [ -z "$github_content" ]; then
        echo "not_on_github"
        return
    fi
    
    local local_hash=$(md5sum "$file" 2>/dev/null | cut -d' ' -f1)
    local github_hash=$(echo "$github_content" | md5sum | cut -d' ' -f1)
    
    if [ "$local_hash" = "$github_hash" ]; then
        echo "identical"
    else
        echo "different"
    fi
}

# =============================================================================
# FILE OPERATIONS
# =============================================================================

# Restore a file from GitHub
restore_file_from_github() {
    local file="$1"
    local backup="${2:-true}"
    
    # Create directory if needed
    local dir=$(dirname "$file")
    if [ ! -d "$dir" ] && [ "$dir" != "." ]; then
        mkdir -p "$dir"
    fi
    
    # Backup existing file if requested
    if [ "$backup" = "true" ] && [ -f "$file" ]; then
        local backup_file="${file}.backup.$(date +%Y%m%d%H%M%S)"
        cp "$file" "$backup_file"
        print_info "Backed up existing file to: $backup_file"
    fi
    
    # Download from GitHub
    local content=$(get_file_from_github "$file")
    if [ -z "$content" ]; then
        print_error "Could not download $file from GitHub"
        return 1
    fi
    
    echo "$content" > "$file"
    
    # Fix ownership
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        chown "$REAL_USER:$REAL_GROUP" "$file" 2>/dev/null
    fi
    
    # Make executable if it's a shell script
    if [[ "$file" == *.sh ]]; then
        chmod +x "$file"
    fi
    
    print_success "Restored: $file"
    [ "$LOG_AVAILABLE" = "true" ] && log_info "Restored file from GitHub" "$file"
    
    return 0
}

# Create backup of a file
backup_file() {
    local file="$1"
    local backup_dir="${2:-backups}"
    
    if [ ! -f "$file" ]; then
        print_error "File not found: $file"
        return 1
    fi
    
    mkdir -p "$backup_dir"
    
    local filename=$(basename "$file")
    local backup_path="$backup_dir/${filename}.$(date +%Y%m%d%H%M%S)"
    
    cp "$file" "$backup_path"
    
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        chown -R "$REAL_USER:$REAL_GROUP" "$backup_dir" 2>/dev/null
    fi
    
    echo "$backup_path"
}

# =============================================================================
# STATUS DASHBOARD
# =============================================================================

show_status_dashboard() {
    clear
    echo ""
    draw_box_top
    draw_box_line "          AEGIS AIO FILE SYSTEM MANAGER"
    draw_box_line ""
    draw_box_line "              By The Pokemod Group"
    draw_box_bottom
    echo ""
    
    # Git Status
    echo -e "  ${WHITE}${BOLD}Repository Status${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    
    if check_git_repo; then
        local git_status=$(get_git_status)
        
        case "$git_status" in
            up_to_date)
                echo -e "    Git Status:    ${GREEN}✓ Up to date${NC}"
                ;;
            behind:*)
                local count=$(echo "$git_status" | cut -d: -f2)
                echo -e "    Git Status:    ${YELLOW}↓ $count commits behind${NC}"
                ;;
            ahead:*)
                local count=$(echo "$git_status" | cut -d: -f2)
                echo -e "    Git Status:    ${CYAN}↑ $count commits ahead${NC}"
                ;;
            diverged:*)
                local behind=$(echo "$git_status" | cut -d: -f2)
                local ahead=$(echo "$git_status" | cut -d: -f3)
                echo -e "    Git Status:    ${RED}⚠ Diverged (↓$behind ↑$ahead)${NC}"
                ;;
            modified)
                echo -e "    Git Status:    ${YELLOW}Modified locally${NC}"
                ;;
            *)
                echo -e "    Git Status:    ${DIM}Unknown${NC}"
                ;;
        esac
        
        local branch=$(git branch --show-current 2>/dev/null)
        echo -e "    Branch:        ${CYAN}$branch${NC}"
        
        local last_commit=$(git log -1 --format="%h %s" 2>/dev/null | head -c 50)
        echo -e "    Last Commit:   ${DIM}$last_commit${NC}"
    else
        echo -e "    Git Status:    ${RED}Not a git repository${NC}"
    fi
    echo ""
    
    # File Status
    echo -e "  ${WHITE}${BOLD}File Status${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    
    local missing_count=0
    local deleted_count=0
    local modified_count=0
    
    # Count missing essential files
    for file in "${ESSENTIAL_FILES[@]}"; do
        [ ! -f "$file" ] && ((missing_count++))
    done
    
    # Count missing shell scripts
    for file in "${SHELL_SCRIPTS[@]}"; do
        [ ! -f "$file" ] && ((missing_count++))
    done
    
    if check_git_repo; then
        deleted_count=$(find_deleted_files | wc -l)
        modified_count=$(get_local_modifications | wc -l)
    fi
    
    if [ $missing_count -eq 0 ]; then
        echo -e "    Essential Files: ${GREEN}✓ All present${NC}"
    else
        echo -e "    Essential Files: ${RED}$missing_count missing${NC}"
    fi
    
    if [ $deleted_count -eq 0 ]; then
        echo -e "    Deleted Files:   ${GREEN}✓ None${NC}"
    else
        echo -e "    Deleted Files:   ${YELLOW}$deleted_count deleted${NC}"
    fi
    
    if [ $modified_count -eq 0 ]; then
        echo -e "    Modified Files:  ${GREEN}✓ None${NC}"
    else
        echo -e "    Modified Files:  ${CYAN}$modified_count modified${NC}"
    fi
    echo ""
}

# =============================================================================
# MENU FUNCTIONS
# =============================================================================

# Main menu
show_main_menu() {
    echo -e "  ${WHITE}${BOLD}File Management${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo "    1) Check for missing files"
    echo "    2) Restore missing files from GitHub"
    echo "    3) View file differences with GitHub"
    echo "    4) Browse files"
    echo ""
    echo -e "  ${WHITE}${BOLD}Git & Updates${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo "    5) Check for updates from GitHub"
    echo "    6) Pull updates (with stash)"
    echo "    7) View local changes"
    echo "    8) Manage merge conflicts"
    echo ""
    echo -e "  ${WHITE}${BOLD}Backup & Restore${NC}"
    echo -e "  ${DIM}────────────────────────────────────────${NC}"
    echo "    9) Backup configuration files"
    echo "    b) Restore from backup"
    echo ""
    echo "    r) Refresh"
    echo "    0) Exit"
    echo ""
}

# Check for missing files
check_missing_files_menu() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              MISSING FILES CHECK"
    draw_box_bottom
    echo ""
    
    local found_missing=false
    
    echo -e "  ${WHITE}Essential Files:${NC}"
    for file in "${ESSENTIAL_FILES[@]}"; do
        if [ -f "$file" ]; then
            echo -e "    ${GREEN}✓${NC} $file"
        else
            echo -e "    ${RED}✗${NC} $file ${RED}(MISSING)${NC}"
            found_missing=true
        fi
    done
    echo ""
    
    echo -e "  ${WHITE}Shell Scripts:${NC}"
    for file in "${SHELL_SCRIPTS[@]}"; do
        if [ -f "$file" ]; then
            echo -e "    ${GREEN}✓${NC} $file"
        else
            echo -e "    ${RED}✗${NC} $file ${RED}(MISSING)${NC}"
            found_missing=true
        fi
    done
    echo ""
    
    echo -e "  ${WHITE}Config Templates:${NC}"
    for file in "${CONFIG_TEMPLATES[@]}"; do
        if [ -f "$file" ]; then
            echo -e "    ${GREEN}✓${NC} $file"
        else
            echo -e "    ${YELLOW}○${NC} $file ${YELLOW}(not present)${NC}"
        fi
    done
    echo ""
    
    if check_git_repo; then
        local deleted=$(find_deleted_files)
        if [ -n "$deleted" ]; then
            echo -e "  ${WHITE}Deleted Files (tracked by Git):${NC}"
            echo "$deleted" | while read -r file; do
                echo -e "    ${RED}✗${NC} $file ${RED}(DELETED)${NC}"
            done
            echo ""
            found_missing=true
        fi
    fi
    
    if [ "$found_missing" = "false" ]; then
        echo -e "  ${GREEN}All essential files are present!${NC}"
    else
        echo -e "  ${YELLOW}Some files are missing. Use option 2 to restore from GitHub.${NC}"
    fi
    
    press_enter
}

# Restore missing files menu
restore_missing_files_menu() {
    clear
    echo ""
    draw_box_top
    draw_box_line "           RESTORE MISSING FILES FROM GITHUB"
    draw_box_bottom
    echo ""
    
    # Collect missing files
    local missing_files=()
    
    for file in "${SHELL_SCRIPTS[@]}"; do
        if [ ! -f "$file" ]; then
            missing_files+=("$file")
        fi
    done
    
    for file in "${CONFIG_TEMPLATES[@]}"; do
        if [ ! -f "$file" ]; then
            missing_files+=("$file")
        fi
    done
    
    # Add git-deleted files
    if check_git_repo; then
        while IFS= read -r file; do
            [ -n "$file" ] && missing_files+=("$file")
        done < <(find_deleted_files)
    fi
    
    if [ ${#missing_files[@]} -eq 0 ]; then
        echo -e "  ${GREEN}No missing files to restore!${NC}"
        press_enter
        return
    fi
    
    echo -e "  ${WHITE}Missing files that can be restored:${NC}"
    echo ""
    local i=1
    for file in "${missing_files[@]}"; do
        echo "    $i) $file"
        ((i++))
    done
    echo ""
    echo "    a) Restore ALL missing files"
    echo "    0) Cancel"
    echo ""
    read -p "  Select file(s) to restore: " choice
    
    case "$choice" in
        0|"")
            return
            ;;
        a|A)
            echo ""
            for file in "${missing_files[@]}"; do
                print_step "Restoring: $file"
                restore_file_from_github "$file" false
            done
            ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#missing_files[@]} ]; then
                local file="${missing_files[$((choice-1))]}"
                echo ""
                restore_file_from_github "$file" false
            else
                print_error "Invalid selection"
            fi
            ;;
    esac
    
    press_enter
}

# View differences with GitHub
view_differences_menu() {
    clear
    echo ""
    draw_box_top
    draw_box_line "           FILE COMPARISON WITH GITHUB"
    draw_box_bottom
    echo ""
    
    echo -e "  ${WHITE}Comparing local files with GitHub versions...${NC}"
    echo ""
    
    local files_to_check=("${SHELL_SCRIPTS[@]}" "${CONFIG_TEMPLATES[@]}")
    local different_files=()
    
    for file in "${files_to_check[@]}"; do
        if [ -f "$file" ]; then
            echo -n "  Checking: $file... "
            local result=$(compare_with_github "$file")
            
            case "$result" in
                identical)
                    echo -e "${GREEN}identical${NC}"
                    ;;
                different)
                    echo -e "${YELLOW}DIFFERENT${NC}"
                    different_files+=("$file")
                    ;;
                not_on_github)
                    echo -e "${DIM}local only${NC}"
                    ;;
                *)
                    echo -e "${DIM}error${NC}"
                    ;;
            esac
        fi
    done
    
    echo ""
    
    if [ ${#different_files[@]} -gt 0 ]; then
        echo -e "  ${WHITE}Files that differ from GitHub:${NC}"
        local i=1
        for file in "${different_files[@]}"; do
            echo "    $i) $file"
            ((i++))
        done
        echo ""
        echo "  Options:"
        echo "    • Enter number to view diff"
        echo "    • Enter 0 to go back"
        echo ""
        read -p "  Select: " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#different_files[@]} ]; then
            local file="${different_files[$((choice-1))]}"
            show_file_diff "$file"
        fi
    else
        echo -e "  ${GREEN}All files match GitHub!${NC}"
    fi
    
    press_enter
}

# Show diff for a specific file
show_file_diff() {
    local file="$1"
    
    clear
    echo ""
    echo -e "  ${WHITE}Difference: $file${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    echo ""
    
    local github_content=$(get_file_from_github "$file")
    
    if command -v diff &>/dev/null; then
        echo "$github_content" | diff --color=always -u "$file" - 2>/dev/null | head -50
    else
        echo -e "  ${YELLOW}diff command not available${NC}"
        echo ""
        echo "  Local file size: $(wc -c < "$file") bytes"
        echo "  GitHub file size: $(echo "$github_content" | wc -c) bytes"
    fi
    
    echo ""
    echo -e "  ${DIM}(Showing first 50 lines of diff)${NC}"
    echo ""
    echo "  Options:"
    echo "    1) Replace local with GitHub version"
    echo "    2) Keep local version"
    echo ""
    read -p "  Select [2]: " choice
    
    if [ "$choice" = "1" ]; then
        restore_file_from_github "$file" true
    fi
}

# Check for updates
check_updates_menu() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              CHECK FOR GITHUB UPDATES"
    draw_box_bottom
    echo ""
    
    if ! check_git_repo; then
        print_error "This is not a git repository"
        print_info "You may have downloaded the files without using git clone"
        echo ""
        echo "  To enable update features, run:"
        echo "    git init"
        echo "    git remote add origin https://github.com/$GITHUB_REPO.git"
        echo "    git fetch origin $GITHUB_BRANCH"
        press_enter
        return
    fi
    
    print_info "Fetching latest from GitHub..."
    git fetch origin "$GITHUB_BRANCH" --quiet 2>/dev/null
    
    local status=$(get_git_status)
    echo ""
    
    case "$status" in
        up_to_date)
            echo -e "  ${GREEN}✓ Your installation is up to date!${NC}"
            ;;
        behind:*)
            local count=$(echo "$status" | cut -d: -f2)
            echo -e "  ${YELLOW}↓ You are $count commit(s) behind GitHub${NC}"
            echo ""
            echo "  New changes available:"
            git log --oneline HEAD..origin/$GITHUB_BRANCH 2>/dev/null | head -10 | while read -r line; do
                echo "    • $line"
            done
            echo ""
            echo "  Files that will be updated:"
            get_remote_changes | head -20 | while read -r file; do
                echo "    - $file"
            done
            ;;
        ahead:*)
            local count=$(echo "$status" | cut -d: -f2)
            echo -e "  ${CYAN}↑ You are $count commit(s) ahead of GitHub${NC}"
            echo ""
            echo "  Your local commits:"
            git log --oneline origin/$GITHUB_BRANCH..HEAD 2>/dev/null | while read -r line; do
                echo "    • $line"
            done
            ;;
        diverged:*)
            local behind=$(echo "$status" | cut -d: -f2)
            local ahead=$(echo "$status" | cut -d: -f3)
            echo -e "  ${RED}⚠ Your branch has diverged from GitHub${NC}"
            echo ""
            echo "  You are $behind commits behind and $ahead commits ahead"
            echo "  This usually means you need to merge or rebase"
            ;;
        modified)
            echo -e "  ${YELLOW}You have local modifications${NC}"
            echo ""
            echo "  Modified files:"
            get_local_modifications | while read -r file; do
                echo "    - $file"
            done
            ;;
    esac
    
    press_enter
}

# Pull updates with stash
pull_updates_menu() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              PULL UPDATES FROM GITHUB"
    draw_box_bottom
    echo ""
    
    if ! check_git_repo; then
        print_error "This is not a git repository"
        press_enter
        return
    fi
    
    # Check for local changes
    local has_changes=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        has_changes=true
    fi
    
    if [ "$has_changes" = "true" ]; then
        echo -e "  ${YELLOW}You have local changes that need to be saved first.${NC}"
        echo ""
        echo "  Modified files:"
        get_local_modifications | while read -r file; do
            echo "    - $file"
        done
        echo ""
        echo "  Options:"
        echo "    1) Stash changes, pull updates, restore changes"
        echo "    2) Discard local changes and pull (DESTRUCTIVE)"
        echo "    0) Cancel"
        echo ""
        read -p "  Select [1]: " choice
        choice="${choice:-1}"
        
        case "$choice" in
            1)
                echo ""
                print_step "Stashing local changes..."
                git stash push -m "Shellder auto-stash $(date +%Y%m%d%H%M%S)"
                
                print_step "Pulling updates..."
                if git pull origin "$GITHUB_BRANCH"; then
                    print_success "Updates pulled successfully"
                    
                    print_step "Restoring your changes..."
                    if git stash pop; then
                        print_success "Your changes have been restored"
                    else
                        print_warning "There were conflicts restoring your changes"
                        echo "  Your changes are saved in git stash"
                        echo "  Run 'git stash list' to see them"
                    fi
                else
                    print_error "Pull failed"
                    print_step "Restoring your stashed changes..."
                    git stash pop
                fi
                ;;
            2)
                echo ""
                echo -e "  ${RED}WARNING: This will discard all local changes!${NC}"
                read -p "  Type 'DISCARD' to confirm: " confirm
                if [ "$confirm" = "DISCARD" ]; then
                    git checkout -- .
                    git clean -fd
                    git pull origin "$GITHUB_BRANCH"
                    print_success "Updates pulled (local changes discarded)"
                else
                    print_info "Cancelled"
                fi
                ;;
            *)
                print_info "Cancelled"
                ;;
        esac
    else
        print_step "Pulling updates from GitHub..."
        if git pull origin "$GITHUB_BRANCH"; then
            print_success "Updates pulled successfully"
        else
            print_error "Pull failed"
        fi
    fi
    
    press_enter
}

# View local changes
view_local_changes_menu() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              LOCAL CHANGES"
    draw_box_bottom
    echo ""
    
    if ! check_git_repo; then
        print_error "This is not a git repository"
        press_enter
        return
    fi
    
    echo -e "  ${WHITE}Modified Files:${NC}"
    local modified=$(get_local_modifications)
    if [ -n "$modified" ]; then
        echo "$modified" | while read -r file; do
            echo -e "    ${YELLOW}M${NC} $file"
        done
    else
        echo -e "    ${GREEN}No modifications${NC}"
    fi
    echo ""
    
    echo -e "  ${WHITE}Untracked Files:${NC}"
    local untracked=$(get_untracked_files)
    if [ -n "$untracked" ]; then
        echo "$untracked" | while read -r file; do
            echo -e "    ${CYAN}?${NC} $file"
        done
    else
        echo -e "    ${GREEN}No untracked files${NC}"
    fi
    echo ""
    
    echo -e "  ${WHITE}Stashed Changes:${NC}"
    local stash_count=$(git stash list 2>/dev/null | wc -l)
    if [ "$stash_count" -gt 0 ]; then
        git stash list | while read -r stash; do
            echo -e "    ${MAGENTA}$stash${NC}"
        done
    else
        echo -e "    ${GREEN}No stashed changes${NC}"
    fi
    
    press_enter
}

# Merge conflict management
manage_conflicts_menu() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              MERGE CONFLICT MANAGEMENT"
    draw_box_bottom
    echo ""
    
    if ! check_git_repo; then
        print_error "This is not a git repository"
        press_enter
        return
    fi
    
    # Check for merge conflicts
    local conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null)
    
    if [ -z "$conflicts" ]; then
        echo -e "  ${GREEN}No merge conflicts detected!${NC}"
        press_enter
        return
    fi
    
    echo -e "  ${RED}Merge conflicts found in:${NC}"
    echo ""
    local i=1
    local conflict_files=()
    echo "$conflicts" | while read -r file; do
        echo "    $i) $file"
        conflict_files+=("$file")
        ((i++))
    done
    
    echo ""
    echo "  Options:"
    echo "    • Enter number to resolve a file"
    echo "    • Enter 'a' to accept all remote (GitHub) versions"
    echo "    • Enter 'k' to keep all local versions"
    echo "    • Enter 0 to go back"
    echo ""
    read -p "  Select: " choice
    
    case "$choice" in
        a|A)
            echo ""
            echo "$conflicts" | while read -r file; do
                git checkout --theirs "$file" 2>/dev/null
                git add "$file"
                print_success "Accepted remote version: $file"
            done
            ;;
        k|K)
            echo ""
            echo "$conflicts" | while read -r file; do
                git checkout --ours "$file" 2>/dev/null
                git add "$file"
                print_success "Kept local version: $file"
            done
            ;;
        0|"")
            return
            ;;
    esac
    
    press_enter
}

# Backup configuration files
backup_configs_menu() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              BACKUP CONFIGURATION FILES"
    draw_box_bottom
    echo ""
    
    local backup_dir="backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    local backed_up=0
    
    echo -e "  ${WHITE}Backing up configuration files...${NC}"
    echo ""
    
    for file in "${USER_CONFIGS[@]}"; do
        if [ -f "$file" ]; then
            local dest_dir="$backup_dir/$(dirname "$file")"
            mkdir -p "$dest_dir"
            cp "$file" "$backup_dir/$file"
            echo -e "    ${GREEN}✓${NC} $file"
            ((backed_up++))
        fi
    done
    
    # Also backup Shellder database if it exists
    if [ -f "$SCRIPT_DIR/shellder.db" ]; then
        cp "$SCRIPT_DIR/shellder.db" "$backup_dir/shellder.db"
        echo -e "    ${GREEN}✓${NC} Shellder/shellder.db"
        ((backed_up++))
    fi
    
    # Fix ownership
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        chown -R "$REAL_USER:$REAL_GROUP" "backups" 2>/dev/null
    fi
    
    echo ""
    print_success "Backed up $backed_up files to: $backup_dir"
    
    [ "$LOG_AVAILABLE" = "true" ] && log_info "Created backup" "$backup_dir ($backed_up files)"
    
    press_enter
}

# Restore from backup
restore_from_backup_menu() {
    clear
    echo ""
    draw_box_top
    draw_box_line "              RESTORE FROM BACKUP"
    draw_box_bottom
    echo ""
    
    if [ ! -d "backups" ]; then
        print_error "No backups directory found"
        press_enter
        return
    fi
    
    local backups=($(ls -d backups/*/ 2>/dev/null | sort -r))
    
    if [ ${#backups[@]} -eq 0 ]; then
        print_error "No backups found"
        press_enter
        return
    fi
    
    echo -e "  ${WHITE}Available backups:${NC}"
    echo ""
    local i=1
    for backup in "${backups[@]}"; do
        local name=$(basename "$backup")
        local file_count=$(find "$backup" -type f | wc -l)
        echo "    $i) $name ($file_count files)"
        ((i++))
    done
    echo ""
    echo "    0) Cancel"
    echo ""
    read -p "  Select backup to restore: " choice
    
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
        return
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#backups[@]} ]; then
        local selected="${backups[$((choice-1))]}"
        
        echo ""
        echo -e "  ${YELLOW}This will overwrite current configuration files!${NC}"
        read -p "  Continue? (y/n) [n]: " confirm
        
        if [ "$confirm" = "y" ]; then
            echo ""
            find "$selected" -type f | while read -r backup_file; do
                local relative_path="${backup_file#$selected}"
                if [ -n "$relative_path" ]; then
                    local dest_dir=$(dirname "$relative_path")
                    [ "$dest_dir" != "." ] && mkdir -p "$dest_dir"
                    cp "$backup_file" "$relative_path"
                    echo -e "    ${GREEN}✓${NC} Restored: $relative_path"
                fi
            done
            print_success "Backup restored"
            
            [ "$LOG_AVAILABLE" = "true" ] && log_info "Restored backup" "$selected"
        fi
    fi
    
    press_enter
}

# Browse files
browse_files_menu() {
    local current_dir="."
    
    while true; do
        clear
        echo ""
        draw_box_top
        draw_box_line "              FILE BROWSER"
        draw_box_bottom
        echo ""
        echo -e "  ${WHITE}Current: ${CYAN}$current_dir${NC}"
        echo ""
        
        # List directories first, then files
        local i=1
        declare -a items=()
        
        # Parent directory option
        if [ "$current_dir" != "." ]; then
            echo -e "    0) ${DIM}../${NC} (parent directory)"
        fi
        
        # List directories
        for item in "$current_dir"/*/; do
            if [ -d "$item" ]; then
                local name=$(basename "$item")
                [[ "$name" == "*" ]] && continue
                echo -e "    $i) ${CYAN}$name/${NC}"
                items+=("$item")
                ((i++))
            fi
        done
        
        # List files
        for item in "$current_dir"/*; do
            if [ -f "$item" ]; then
                local name=$(basename "$item")
                local size=$(du -h "$item" 2>/dev/null | cut -f1)
                echo -e "    $i) $name ${DIM}($size)${NC}"
                items+=("$item")
                ((i++))
            fi
        done
        
        echo ""
        echo "    q) Back to main menu"
        echo ""
        read -p "  Select: " choice
        
        case "$choice" in
            q|Q) return ;;
            0)
                if [ "$current_dir" != "." ]; then
                    current_dir=$(dirname "$current_dir")
                    [ "$current_dir" = "" ] && current_dir="."
                fi
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#items[@]} ]; then
                    local selected="${items[$((choice-1))]}"
                    if [ -d "$selected" ]; then
                        current_dir="${selected%/}"
                    elif [ -f "$selected" ]; then
                        view_file "$selected"
                    fi
                fi
                ;;
        esac
    done
}

# View a file
view_file() {
    local file="$1"
    
    clear
    echo ""
    echo -e "  ${WHITE}File: ${CYAN}$file${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    echo ""
    
    if command -v less &>/dev/null; then
        less "$file"
    elif command -v more &>/dev/null; then
        more "$file"
    else
        head -100 "$file"
        echo ""
        echo -e "  ${DIM}(Showing first 100 lines)${NC}"
        press_enter
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    cd "$(dirname "$0")/.." || exit 1
    
    while true; do
        show_status_dashboard
        show_main_menu
        
        read -p "  Select option: " choice
        
        case $choice in
            1) check_missing_files_menu ;;
            2) restore_missing_files_menu ;;
            3) view_differences_menu ;;
            4) browse_files_menu ;;
            5) check_updates_menu ;;
            6) pull_updates_menu ;;
            7) view_local_changes_menu ;;
            8) manage_conflicts_menu ;;
            9) backup_configs_menu ;;
            b|B) restore_from_backup_menu ;;
            r|R) continue ;;
            0)
                if [ "$SHELLDER_LAUNCHER" = "1" ]; then
                    return_to_main
                else
                    exit 0
                fi
                ;;
        esac
    done
}

main "$@"

