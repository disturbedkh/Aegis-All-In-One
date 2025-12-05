#!/usr/bin/env python3
"""
Shellder Service - Live Monitoring & Control Panel for Aegis AIO
=================================================================

This is the MAIN service that provides:
- Web Dashboard (GUI) on port 5000
- Real-time container stats via WebSocket
- Xilriws proxy monitoring and stats
- Log aggregation and streaming
- System resource monitoring
- SQLite database access for historical stats
- File system browsing
- Port scanning
- System services status (nginx, fail2ban, ufw)

Run via Docker:
    docker compose up -d shellder

Or standalone:
    python shellder_service.py
"""

# =============================================================================
# VERSION - Update this with each significant change for debugging
# =============================================================================
SHELLDER_VERSION = "1.0.36"  # 2025-12-03: Add Setup & Config page with GitHub manager, config editor, env manager
SHELLDER_BUILD = "20251203-12"  # Date-based build number

# =============================================================================
# EVENTLET MUST BE FIRST - Before any other imports!
# =============================================================================
# Eventlet monkey_patch() must happen before importing anything else
# to avoid "monkey_patching after imports" errors
try:
    import eventlet
    eventlet.monkey_patch()
    ASYNC_MODE = 'eventlet'
except ImportError:
    ASYNC_MODE = 'threading'
except Exception as e:
    # If eventlet fails, fall back to threading
    print(f"Warning: eventlet monkey_patch failed: {e}")
    ASYNC_MODE = 'threading'

# =============================================================================
# STANDARD LIBRARY IMPORTS
# =============================================================================
import os
import sys
import json
import time
import threading
import re
import signal
import sqlite3
import subprocess
import socket
from datetime import datetime, timedelta
from pathlib import Path
from collections import defaultdict
from functools import wraps
import shutil

# =============================================================================
# DEBUG LOGGER - MUST BE EARLY
# =============================================================================
try:
    from debug_logger import (
        log, trace, debug, info, warn, error, fatal,
        logged, log_system_state, log_docker_state, log_client_logs,
        get_recent_logs, get_log_path, clear_log, track_websocket
    )
    DEBUG_LOGGING = True
    info('STARTUP', 'Debug logger loaded successfully')
except ImportError as e:
    DEBUG_LOGGING = False
    print(f"Warning: debug_logger not available: {e}")
    # Stub functions
    def log(*args, **kwargs): pass
    def trace(*args, **kwargs): pass
    def debug(*args, **kwargs): pass
    def info(*args, **kwargs): pass
    def warn(*args, **kwargs): pass
    def error(*args, **kwargs): pass
    def fatal(*args, **kwargs): pass
    def logged(cat=None): return lambda f: f
    def log_system_state(): pass
    def log_docker_state(): pass
    def log_client_logs(d): pass
    def get_recent_logs(n=100): return []
    def get_log_path(): return ''
    def clear_log(): pass
    def track_websocket(event, sid, data=None): pass

# =============================================================================
# THIRD-PARTY IMPORTS
# =============================================================================

# Flask and WebSocket
try:
    from flask import Flask, render_template, jsonify, request, Response, send_from_directory
    from flask_cors import CORS
except ImportError:
    print("Error: Flask is not installed.")
    print("Run: pip install flask flask-cors")
    sys.exit(1)

try:
    from flask_socketio import SocketIO, emit
    SOCKETIO_AVAILABLE = True
except ImportError:
    SOCKETIO_AVAILABLE = False
    print("Warning: flask-socketio not available, WebSocket disabled")

# Docker and System
try:
    import docker
    DOCKER_AVAILABLE = True
except ImportError:
    DOCKER_AVAILABLE = False
    print("Warning: docker package not available, using subprocess fallback")

try:
    import psutil
    PSUTIL_AVAILABLE = True
except ImportError:
    PSUTIL_AVAILABLE = False
    print("Warning: psutil not available, limited system stats")

# =============================================================================
# CONFIGURATION
# =============================================================================

SHELLDER_PORT = int(os.environ.get('SHELLDER_PORT', 5000))
AEGIS_ROOT = Path(os.environ.get('AEGIS_ROOT', '/aegis'))

# Local testing mode - provides mock data when Docker/stack not available
LOCAL_MODE = os.environ.get('SHELLDER_LOCAL_MODE', '0') == '1'

# When running locally, find the root directory
if not AEGIS_ROOT.exists():
    SCRIPT_DIR = Path(__file__).parent
    AEGIS_ROOT = SCRIPT_DIR.parent

SHELLDER_DIR = AEGIS_ROOT / 'Shellder'
TEMPLATES_DIR = SHELLDER_DIR / 'gui_templates'
STATIC_DIR = SHELLDER_DIR / 'gui_static'

# Data directories - prefer /app paths in Docker (writable), fall back to Shellder dir
# Note: /aegis is mounted read-only in Docker, so we MUST use /app/data for writable data
DATA_DIR = Path('/app/data') if Path('/app/data').exists() else SHELLDER_DIR / 'data'
LOG_DIR = Path('/app/logs') if Path('/app/logs').exists() else SHELLDER_DIR / 'logs'

# Database and log MUST be in writable directories
# In Docker: /app/data (mounted from ./Shellder/data)
# Locally: Shellder/data
SHELLDER_DB = DATA_DIR / 'shellder.db'
SHELLDER_LOG = LOG_DIR / 'shellder.log'

# Ensure directories exist (with graceful error handling for permission issues)
try:
    DATA_DIR.mkdir(exist_ok=True, mode=0o775)
except PermissionError:
    print(f"Warning: Cannot create {DATA_DIR} - using existing or will retry")
except Exception as e:
    print(f"Warning: Error creating {DATA_DIR}: {e}")

try:
    LOG_DIR.mkdir(exist_ok=True, mode=0o775)
except PermissionError:
    print(f"Warning: Cannot create {LOG_DIR} - using existing or will retry")
except Exception as e:
    print(f"Warning: Error creating {LOG_DIR}: {e}")

# =============================================================================
# FLASK APP SETUP
# =============================================================================

app = Flask(__name__,
            template_folder=str(TEMPLATES_DIR),
            static_folder=str(STATIC_DIR))
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'shellder-secret-key')
CORS(app)

# =============================================================================
# HTTP REQUEST/RESPONSE LOGGING
# =============================================================================
try:
    from debug_logger import log_http_request, log_http_response, log_http_error
    
    @app.before_request
    def before_request_logging():
        """Log all incoming HTTP requests"""
        log_http_request(request)
    
    @app.after_request
    def after_request_logging(response):
        """Log all HTTP responses"""
        return log_http_response(response, request)
    
    info('FLASK', 'HTTP request/response logging enabled')
except ImportError:
    pass  # Debug logger not available

# Track API requests for adaptive polling (keeps polling active when UI is used)
@app.before_request
def track_api_activity():
    """Track API activity to keep adaptive polling active"""
    # Only track /api/ requests (not static files)
    if request.path.startswith('/api/') and stats_collector:
        stats_collector.record_api_request()

if SOCKETIO_AVAILABLE:
    socketio = SocketIO(app, cors_allowed_origins="*", async_mode=ASYNC_MODE)
else:
    socketio = None

# =============================================================================
# SIMPLE TOML PARSER (fallback when tomli/toml not available)
# =============================================================================

def parse_simple_toml(file_path):
    """
    Simple TOML parser for basic key=value and [section] syntax.
    Used as fallback when tomli/toml modules are not available.
    """
    result = {}
    current_section = result
    section_path = []
    
    try:
        with open(file_path, 'r') as f:
            for line in f:
                line = line.strip()
                
                # Skip comments and empty lines
                if not line or line.startswith('#'):
                    continue
                
                # Section header
                if line.startswith('[') and line.endswith(']'):
                    section_name = line[1:-1].strip()
                    section_path = section_name.split('.')
                    
                    # Navigate/create nested sections
                    current_section = result
                    for part in section_path:
                        if part not in current_section:
                            current_section[part] = {}
                        current_section = current_section[part]
                    continue
                
                # Key = value
                if '=' in line:
                    key, value = line.split('=', 1)
                    key = key.strip()
                    value = value.strip()
                    
                    # Remove quotes
                    if (value.startswith('"') and value.endswith('"')) or \
                       (value.startswith("'") and value.endswith("'")):
                        value = value[1:-1]
                    
                    # Convert types
                    if value.lower() == 'true':
                        value = True
                    elif value.lower() == 'false':
                        value = False
                    elif value.isdigit():
                        value = int(value)
                    
                    current_section[key] = value
        
        return result
    except Exception as e:
        print(f"Simple TOML parse error: {e}")
        return {}

# =============================================================================
# FILE WRITE HELPER (preserves ownership when using sudo)
# =============================================================================

def safe_write_file(file_path, content, preserve_ownership=True):
    """
    Write a file using sudo tee while preserving original ownership.
    Returns (success, error_message)
    """
    try:
        original_uid = 1000
        original_gid = 1000
        
        if preserve_ownership and os.path.exists(file_path):
            try:
                stat_info = os.stat(file_path)
                original_uid = stat_info.st_uid
                original_gid = stat_info.st_gid
            except:
                pass
        
        # Write using sudo tee
        result = subprocess.run(
            ['sudo', 'tee', file_path],
            input=content,
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode != 0:
            return False, result.stderr[:200]
        
        # Restore ownership
        if preserve_ownership:
            try:
                subprocess.run(
                    ['sudo', 'chown', f'{original_uid}:{original_gid}', file_path],
                    capture_output=True,
                    timeout=5
                )
            except:
                pass  # Best effort
        
        return True, None
    except Exception as e:
        return False, str(e)

# =============================================================================
# DOCKER CLIENT
# =============================================================================

docker_client = None
if DOCKER_AVAILABLE:
    try:
        docker_client = docker.from_env()
    except Exception as e:
        print(f"Warning: Could not connect to Docker: {e}")

# =============================================================================
# MARIADB STACK DATABASE ACCESS (Cross-Reference with Live Stack Data)
# =============================================================================

class StackDB:
    """
    Direct access to the Unown Stack's MariaDB databases for cross-referencing
    Databases: golbat, dragonite, koji, reactmap
    
    This allows Shellder to query actual stack data for comprehensive monitoring
    """
    
    def __init__(self):
        self.connection_params = None
        self._load_connection_params()
    
    def _load_connection_params(self):
        """Load MariaDB connection parameters from .env file"""
        env_file = AEGIS_ROOT / '.env'
        if not env_file.exists():
            return
        
        params = {}
        try:
            with open(env_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        key, value = line.split('=', 1)
                        value = value.strip('"\'')
                        if key == 'POKEMON_DB_HOST':
                            params['host'] = value
                        elif key == 'POKEMON_DB_PORT':
                            params['port'] = int(value) if value else 3306
                        elif key == 'POKEMON_DB_USER':
                            params['user'] = value
                        elif key == 'POKEMON_DB_PASS':
                            params['password'] = value
                        elif key == 'POKEMON_DB_NAME':
                            params['database'] = value
            
            if params.get('host') and params.get('user'):
                self.connection_params = params
        except Exception as e:
            print(f"Error loading MariaDB params: {e}")
    
    def _connect(self, database=None):
        """Create a connection to MariaDB"""
        if not self.connection_params:
            return None
        
        try:
            import pymysql
            params = dict(self.connection_params)
            if database:
                params['database'] = database
            params['connect_timeout'] = 5
            params['read_timeout'] = 10
            return pymysql.connect(**params)
        except ImportError:
            print("pymysql not available - install with: pip install pymysql")
            return None
        except Exception as e:
            print(f"MariaDB connection error: {e}")
            return None
    
    def test_connection(self):
        """Test if MariaDB is accessible"""
        conn = self._connect()
        if conn:
            try:
                cursor = conn.cursor()
                cursor.execute("SELECT VERSION()")
                version = cursor.fetchone()[0]
                conn.close()
                return {'connected': True, 'version': version}
            except Exception as e:
                return {'connected': False, 'error': str(e)}
        return {'connected': False, 'error': 'No connection params'}
    
    def get_available_databases(self):
        """List all databases in the stack"""
        conn = self._connect()
        if not conn:
            return []
        try:
            cursor = conn.cursor()
            cursor.execute("SHOW DATABASES")
            dbs = [row[0] for row in cursor.fetchall()]
            # Filter to stack databases
            stack_dbs = [db for db in dbs if db in ['golbat', 'dragonite', 'koji', 'reactmap', 'mysql', 'information_schema']]
            conn.close()
            return stack_dbs
        except Exception as e:
            print(f"Error listing databases: {e}")
            return []
    
    # =========================================================================
    # GOLBAT DATABASE QUERIES (Pokemon/Gym/Pokestop data)
    # =========================================================================
    
    def get_golbat_stats(self):
        """Get Golbat database statistics"""
        conn = self._connect('golbat')
        if not conn:
            return {'error': 'Cannot connect to golbat database'}
        
        try:
            cursor = conn.cursor()
            stats = {}
            
            # Pokemon stats
            try:
                cursor.execute("SELECT COUNT(*) FROM pokemon")
                stats['pokemon_count'] = cursor.fetchone()[0]
                
                cursor.execute("SELECT COUNT(*) FROM pokemon WHERE pokemon_id IS NOT NULL AND expire_timestamp > UNIX_TIMESTAMP()")
                stats['active_pokemon'] = cursor.fetchone()[0]
            except:
                stats['pokemon_count'] = 'N/A'
                stats['active_pokemon'] = 'N/A'
            
            # Pokestop stats
            try:
                cursor.execute("SELECT COUNT(*) FROM pokestop")
                stats['pokestop_count'] = cursor.fetchone()[0]
                
                cursor.execute("SELECT COUNT(*) FROM pokestop WHERE quest_type IS NOT NULL")
                stats['pokestops_with_quests'] = cursor.fetchone()[0]
            except:
                stats['pokestop_count'] = 'N/A'
            
            # Gym stats
            try:
                cursor.execute("SELECT COUNT(*) FROM gym")
                stats['gym_count'] = cursor.fetchone()[0]
                
                cursor.execute("SELECT team_id, COUNT(*) as cnt FROM gym GROUP BY team_id")
                teams = {0: 'Neutral', 1: 'Mystic', 2: 'Valor', 3: 'Instinct'}
                stats['gyms_by_team'] = {teams.get(row[0], f'Team {row[0]}'): row[1] for row in cursor.fetchall()}
            except:
                stats['gym_count'] = 'N/A'
            
            # Raid stats
            try:
                cursor.execute("""
                    SELECT COUNT(*) FROM gym 
                    WHERE raid_end_timestamp > UNIX_TIMESTAMP() 
                    AND raid_level IS NOT NULL
                """)
                stats['active_raids'] = cursor.fetchone()[0]
            except:
                stats['active_raids'] = 'N/A'
            
            # Spawnpoint stats
            try:
                cursor.execute("SELECT COUNT(*) FROM spawnpoint")
                stats['spawnpoint_count'] = cursor.fetchone()[0]
            except:
                stats['spawnpoint_count'] = 'N/A'
            
            # Recent activity
            try:
                cursor.execute("""
                    SELECT COUNT(*) FROM pokemon 
                    WHERE first_seen_timestamp > UNIX_TIMESTAMP() - 3600
                """)
                stats['pokemon_last_hour'] = cursor.fetchone()[0]
            except:
                stats['pokemon_last_hour'] = 'N/A'
            
            conn.close()
            stats['timestamp'] = datetime.now().isoformat()
            return stats
        except Exception as e:
            return {'error': str(e)}
    
    def get_pokemon_summary(self, hours=24):
        """Get Pokemon spawn summary"""
        conn = self._connect('golbat')
        if not conn:
            return []
        
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT pokemon_id, COUNT(*) as cnt 
                FROM pokemon 
                WHERE first_seen_timestamp > UNIX_TIMESTAMP() - %s
                GROUP BY pokemon_id 
                ORDER BY cnt DESC 
                LIMIT 20
            """, (hours * 3600,))
            
            results = [{'pokemon_id': row[0], 'count': row[1]} for row in cursor.fetchall()]
            conn.close()
            return results
        except Exception as e:
            print(f"Error getting pokemon summary: {e}")
            return []
    
    # =========================================================================
    # DRAGONITE DATABASE QUERIES (Scanner/Worker data)
    # =========================================================================
    
    def get_dragonite_stats(self):
        """Get Dragonite scanner statistics"""
        conn = self._connect('dragonite')
        if not conn:
            return {'error': 'Cannot connect to dragonite database'}
        
        try:
            cursor = conn.cursor()
            stats = {}
            
            # Account stats - based on actual schema
            # Columns: username, password, email, provider, level, warn, warn_expiration,
            #          suspended, banned, invalid, auth_banned, ar_ban_state, ar_ban_last_checked,
            #          last_selected, last_released, last_disabled, last_banned, last_suspended,
            #          consecutive_disable_count, refresh_token, last_refreshed, next_available_time
            try:
                cursor.execute("SELECT COUNT(*) FROM account")
                stats['total_accounts'] = cursor.fetchone()[0]
                
                # Active = not banned, not suspended, not invalid, not auth_banned
                cursor.execute("""
                    SELECT COUNT(*) FROM account 
                    WHERE banned = '0' AND suspended = '0' AND invalid = '0' AND auth_banned = '0'
                """)
                stats['active_accounts'] = cursor.fetchone()[0]
                
                cursor.execute("SELECT COUNT(*) FROM account WHERE banned != '0'")
                stats['banned_accounts'] = cursor.fetchone()[0]
                
                cursor.execute("SELECT COUNT(*) FROM account WHERE auth_banned != '0'")
                stats['auth_banned_accounts'] = cursor.fetchone()[0]
                
                cursor.execute("SELECT COUNT(*) FROM account WHERE warn != '0'")
                stats['warned_accounts'] = cursor.fetchone()[0]
                
                cursor.execute("SELECT COUNT(*) FROM account WHERE suspended != '0'")
                stats['suspended_accounts'] = cursor.fetchone()[0]
                
                cursor.execute("SELECT COUNT(*) FROM account WHERE invalid != '0'")
                stats['invalid_accounts'] = cursor.fetchone()[0]
                
                # Level distribution
                cursor.execute("""
                    SELECT level, COUNT(*) as cnt FROM account 
                    WHERE banned = '0' 
                    GROUP BY level 
                    ORDER BY level
                """)
                stats['level_distribution'] = {row[0]: row[1] for row in cursor.fetchall()}
                
                # Provider breakdown
                cursor.execute("""
                    SELECT provider, COUNT(*) as cnt FROM account 
                    GROUP BY provider
                """)
                stats['by_provider'] = {row[0] or 'unknown': row[1] for row in cursor.fetchall()}
                
                # AR ban states
                cursor.execute("""
                    SELECT ar_ban_state, COUNT(*) as cnt FROM account 
                    WHERE ar_ban_state IS NOT NULL 
                    GROUP BY ar_ban_state
                """)
                stats['ar_ban_states'] = {row[0]: row[1] for row in cursor.fetchall()}
                
                # Recently active (last_selected in last hour)
                cursor.execute("""
                    SELECT COUNT(*) FROM account 
                    WHERE last_selected > UNIX_TIMESTAMP() - 3600
                """)
                stats['active_last_hour'] = cursor.fetchone()[0]
                
                # Accounts with valid refresh tokens
                cursor.execute("""
                    SELECT COUNT(*) FROM account 
                    WHERE refresh_token IS NOT NULL AND refresh_token != ''
                """)
                stats['with_refresh_token'] = cursor.fetchone()[0]
                
            except Exception as e:
                stats['account_error'] = str(e)
            
            # Device stats
            try:
                cursor.execute("SELECT COUNT(*) FROM device")
                stats['total_devices'] = cursor.fetchone()[0]
                
                cursor.execute("""
                    SELECT COUNT(*) FROM device 
                    WHERE last_seen > UNIX_TIMESTAMP() - 300
                """)
                stats['online_devices'] = cursor.fetchone()[0]
            except:
                stats['total_devices'] = 'N/A'
            
            # Instance stats
            try:
                cursor.execute("SELECT COUNT(*) FROM instance")
                stats['total_instances'] = cursor.fetchone()[0]
                
                cursor.execute("SELECT name, type FROM instance")
                stats['instances'] = [{'name': row[0], 'type': row[1]} for row in cursor.fetchall()]
            except:
                stats['total_instances'] = 'N/A'
            
            conn.close()
            stats['timestamp'] = datetime.now().isoformat()
            return stats
        except Exception as e:
            return {'error': str(e)}
    
    def get_device_status(self):
        """Get detailed device status"""
        conn = self._connect('dragonite')
        if not conn:
            return []
        
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT uuid, instance_name, last_host, last_seen,
                       account_username, last_lat, last_lon
                FROM device 
                ORDER BY last_seen DESC
            """)
            
            devices = []
            for row in cursor.fetchall():
                last_seen = row[3]
                is_online = last_seen and (time.time() - last_seen) < 300
                devices.append({
                    'uuid': row[0],
                    'instance': row[1],
                    'host': row[2],
                    'last_seen': datetime.fromtimestamp(last_seen).isoformat() if last_seen else None,
                    'account': row[4],
                    'lat': row[5],
                    'lon': row[6],
                    'online': is_online
                })
            
            conn.close()
            return devices
        except Exception as e:
            print(f"Error getting device status: {e}")
            return []
    
    def get_account_health(self):
        """Get account health summary"""
        conn = self._connect('dragonite')
        if not conn:
            return {}
        
        try:
            cursor = conn.cursor()
            
            # Account level distribution
            cursor.execute("""
                SELECT level, COUNT(*) FROM account 
                WHERE banned = 0 
                GROUP BY level 
                ORDER BY level
            """)
            level_dist = {row[0]: row[1] for row in cursor.fetchall()}
            
            # Recently banned
            cursor.execute("""
                SELECT COUNT(*) FROM account 
                WHERE banned = 1 
                AND last_modified > UNIX_TIMESTAMP() - 86400
            """)
            recently_banned = cursor.fetchone()[0]
            
            # Recently warned
            cursor.execute("""
                SELECT COUNT(*) FROM account 
                WHERE warn_expiration IS NOT NULL 
                AND warn_expiration > UNIX_TIMESTAMP()
            """)
            currently_warned = cursor.fetchone()[0]
            
            conn.close()
            return {
                'level_distribution': level_dist,
                'recently_banned_24h': recently_banned,
                'currently_warned': currently_warned,
                'timestamp': datetime.now().isoformat()
            }
        except Exception as e:
            print(f"Error getting account health: {e}")
            return {'error': str(e)}
    
    # =========================================================================
    # KOJI DATABASE QUERIES (Geofence/Route data)
    # =========================================================================
    
    def get_koji_stats(self):
        """Get Koji geofence statistics"""
        conn = self._connect('koji')
        if not conn:
            return {'error': 'Cannot connect to koji database'}
        
        try:
            cursor = conn.cursor()
            stats = {}
            
            # Geofence stats
            try:
                cursor.execute("SELECT COUNT(*) FROM geofence")
                stats['total_geofences'] = cursor.fetchone()[0]
                
                cursor.execute("SELECT mode, COUNT(*) FROM geofence GROUP BY mode")
                stats['geofences_by_mode'] = {row[0]: row[1] for row in cursor.fetchall()}
            except:
                stats['total_geofences'] = 'N/A'
            
            # Route stats
            try:
                cursor.execute("SELECT COUNT(*) FROM route")
                stats['total_routes'] = cursor.fetchone()[0]
            except:
                stats['total_routes'] = 'N/A'
            
            # Project stats
            try:
                cursor.execute("SELECT COUNT(*) FROM project")
                stats['total_projects'] = cursor.fetchone()[0]
            except:
                stats['total_projects'] = 'N/A'
            
            conn.close()
            stats['timestamp'] = datetime.now().isoformat()
            return stats
        except Exception as e:
            return {'error': str(e)}
    
    # =========================================================================
    # REACTMAP DATABASE QUERIES (User/Session data)
    # =========================================================================
    
    def get_reactmap_stats(self):
        """Get Reactmap user/session statistics"""
        conn = self._connect('reactmap')
        if not conn:
            return {'error': 'Cannot connect to reactmap database'}
        
        try:
            cursor = conn.cursor()
            stats = {}
            
            # User stats
            try:
                cursor.execute("SELECT COUNT(*) FROM users")
                stats['total_users'] = cursor.fetchone()[0]
            except:
                stats['total_users'] = 'N/A'
            
            # Session stats
            try:
                cursor.execute("SELECT COUNT(*) FROM session")
                stats['total_sessions'] = cursor.fetchone()[0]
                
                cursor.execute("""
                    SELECT COUNT(*) FROM session 
                    WHERE updated_at > DATE_SUB(NOW(), INTERVAL 1 HOUR)
                """)
                stats['active_sessions'] = cursor.fetchone()[0]
            except:
                stats['total_sessions'] = 'N/A'
            
            conn.close()
            stats['timestamp'] = datetime.now().isoformat()
            return stats
        except Exception as e:
            return {'error': str(e)}
    
    # =========================================================================
    # CROSS-REFERENCE QUERIES (Combining data from multiple databases)
    # =========================================================================
    
    def get_full_stack_summary(self):
        """Get a comprehensive summary across all stack databases"""
        summary = {
            'golbat': self.get_golbat_stats(),
            'dragonite': self.get_dragonite_stats(),
            'koji': self.get_koji_stats(),
            'reactmap': self.get_reactmap_stats(),
            'connection_test': self.test_connection(),
            'available_databases': self.get_available_databases(),
            'generated_at': datetime.now().isoformat()
        }
        return summary
    
    def get_scanner_efficiency(self):
        """
        Cross-reference scanner data with pokemon spawns
        to calculate scanning efficiency
        """
        golbat = self.get_golbat_stats()
        dragonite = self.get_dragonite_stats()
        
        if 'error' in golbat or 'error' in dragonite:
            return {'error': 'Could not get data from both databases'}
        
        try:
            pokemon_per_hour = golbat.get('pokemon_last_hour', 0)
            online_devices = dragonite.get('online_devices', 0)
            active_accounts = dragonite.get('active_accounts', 0)
            
            efficiency = {
                'pokemon_per_hour': pokemon_per_hour,
                'online_devices': online_devices,
                'active_accounts': active_accounts,
                'pokemon_per_device_hour': round(pokemon_per_hour / max(online_devices, 1), 2),
                'pokemon_per_account_hour': round(pokemon_per_hour / max(active_accounts, 1), 2),
                'account_utilization': round((active_accounts / max(dragonite.get('total_accounts', 1), 1)) * 100, 1),
                'device_utilization': round((online_devices / max(dragonite.get('total_devices', 1), 1)) * 100, 1),
                'timestamp': datetime.now().isoformat()
            }
            return efficiency
        except Exception as e:
            return {'error': str(e)}
    
    def get_health_dashboard(self):
        """
        Comprehensive health dashboard combining all metrics
        """
        return {
            'scanner': {
                'devices': self.get_device_status()[:10],  # Top 10
                'accounts': self.get_account_health()
            },
            'data': {
                'golbat': self.get_golbat_stats()
            },
            'geofencing': self.get_koji_stats(),
            'frontend': self.get_reactmap_stats(),
            'efficiency': self.get_scanner_efficiency(),
            'generated_at': datetime.now().isoformat()
        }

# Initialize stack database accessor
stack_db = StackDB()

# =============================================================================
# DEVICE MANAGER - Cross-Reference Devices Across Logs & Database
# =============================================================================

class DeviceManager:
    """
    Comprehensive device tracking that cross-references:
    - Rotom logs (connection, disconnect, memory)
    - Dragonite logs (task assignment, errors, crashes)
    - Dragonite database (device table)
    - Shellder SQLite (persistent stats, crash history)
    
    Tracks: crashes, disconnects, uptime, reconnects with log line references
    """
    
    def __init__(self, shellder_db_path, aegis_root):
        self.db_path = shellder_db_path
        self.aegis_root = aegis_root
        self.devices = {}  # In-memory device cache
        self.lock = threading.Lock()
        
        # Crash patterns to detect in logs
        self.crash_patterns = {
            'rotom': [
                (re.compile(r'(\S+)/\d+:\s*Disconnected.*performing disconnection activities'), 'disconnect'),
                (re.compile(r'CONTROLLER:\s*Disconnected worker\s+(\S+)'), 'worker_disconnect'),
                (re.compile(r'(\S+):\s*error|Error|ERROR'), 'error'),
                (re.compile(r'(\S+):\s*crash|Crash|CRASH'), 'crash'),
                (re.compile(r'(\S+):\s*timeout|Timeout|TIMEOUT'), 'timeout'),
                (re.compile(r'(\S+):\s*failed|Failed|FAILED'), 'failed'),
            ],
            'dragonite': [
                (re.compile(r'device.*(\S+).*disconnect', re.I), 'disconnect'),
                (re.compile(r'worker.*(\S+).*error', re.I), 'worker_error'),
                (re.compile(r'device.*(\S+).*timeout', re.I), 'timeout'),
                (re.compile(r'(\S+).*account.*banned', re.I), 'account_banned'),
                (re.compile(r'(\S+).*no.*suitable.*account', re.I), 'no_account'),
                (re.compile(r'(\S+).*failed.*task', re.I), 'task_failed'),
                (re.compile(r'(\S+).*connection.*refused', re.I), 'connection_refused'),
            ]
        }
    
    def _connect_sqlite(self):
        """Connect to Shellder's SQLite database"""
        if not self.db_path.exists():
            return None
        return sqlite3.connect(str(self.db_path), timeout=10)
    
    def get_all_devices(self):
        """Get comprehensive device list from all sources"""
        devices = {}
        
        # 1. Get from Dragonite database (authoritative source)
        db_devices = stack_db.get_device_status()
        for dev in db_devices:
            name = dev.get('uuid', '')
            if name:
                devices[name] = {
                    'uuid': name,
                    'source': 'dragonite_db',
                    'instance': dev.get('instance'),
                    'account': dev.get('account'),
                    'host': dev.get('host'),
                    'last_seen': dev.get('last_seen'),
                    'lat': dev.get('lat'),
                    'lon': dev.get('lon'),
                    'online': dev.get('online', False),
                    'stats': self._get_device_stats(name)
                }
        
        # 2. Merge with Shellder persistent data
        conn = self._connect_sqlite()
        if conn:
            try:
                cursor = conn.cursor()
                cursor.execute("""
                    SELECT device_name, worker_id, origin, version, 
                           total_connections, total_disconnections,
                           total_crashes, total_errors, total_uptime_seconds,
                           is_online, first_seen, last_seen,
                           last_connect_time, last_disconnect_time
                    FROM rotom_devices
                """)
                for row in cursor.fetchall():
                    name = row[0]
                    if name not in devices:
                        devices[name] = {
                            'uuid': name,
                            'source': 'shellder_db',
                            'online': bool(row[9])
                        }
                    devices[name].update({
                        'worker_id': row[1],
                        'origin': row[2],
                        'version': row[3],
                        'total_connections': row[4] or 0,
                        'total_disconnections': row[5] or 0,
                        'total_crashes': row[6] or 0,
                        'total_errors': row[7] or 0,
                        'total_uptime_seconds': row[8] or 0,
                        'first_seen': row[10],
                        'last_seen_shellder': row[11],
                        'last_connect': row[12],
                        'last_disconnect': row[13]
                    })
            except Exception as e:
                print(f"Error getting device data from SQLite: {e}")
            finally:
                conn.close()
        
        # 3. Calculate derived stats
        for name, dev in devices.items():
            dev['uptime_percent'] = self._calculate_uptime_percent(dev)
            dev['crash_rate'] = self._calculate_crash_rate(dev)
            dev['recent_crashes'] = self._get_recent_crashes(name, limit=5)
        
        return list(devices.values())
    
    def _get_device_stats(self, device_name):
        """Get device stats from SQLite"""
        conn = self._connect_sqlite()
        if not conn:
            return {}
        
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT total_connections, total_disconnections, 
                       total_crashes, total_errors, total_uptime_seconds
                FROM rotom_devices WHERE device_name = ?
            """, (device_name,))
            row = cursor.fetchone()
            if row:
                return {
                    'connections': row[0] or 0,
                    'disconnections': row[1] or 0,
                    'crashes': row[2] or 0,
                    'errors': row[3] or 0,
                    'uptime_seconds': row[4] or 0
                }
            return {}
        except:
            return {}
        finally:
            conn.close()
    
    def _calculate_uptime_percent(self, device):
        """Calculate uptime percentage based on sessions"""
        total_uptime = device.get('total_uptime_seconds', 0)
        first_seen = device.get('first_seen')
        if not first_seen or total_uptime == 0:
            return 0.0
        
        try:
            first = datetime.fromisoformat(first_seen.replace('Z', '+00:00'))
            total_possible = (datetime.now(first.tzinfo or None) - first).total_seconds()
            if total_possible > 0:
                return round((total_uptime / total_possible) * 100, 1)
        except:
            pass
        return 0.0
    
    def _calculate_crash_rate(self, device):
        """Calculate crashes per hour"""
        crashes = device.get('total_crashes', 0)
        uptime = device.get('total_uptime_seconds', 0)
        if uptime > 0:
            return round((crashes / (uptime / 3600)), 2)
        return 0.0
    
    def _get_recent_crashes(self, device_name, limit=10):
        """Get recent crashes for a device"""
        conn = self._connect_sqlite()
        if not conn:
            return []
        
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT id, crash_type, error_message, log_source,
                       log_line_start, log_line_end, is_during_startup, created_at
                FROM device_crashes
                WHERE device_name = ?
                ORDER BY created_at DESC
                LIMIT ?
            """, (device_name, limit))
            return [
                {
                    'id': row[0],
                    'type': row[1],
                    'message': row[2],
                    'log_source': row[3],
                    'line_start': row[4],
                    'line_end': row[5],
                    'is_startup': bool(row[6]),
                    'time': row[7]
                }
                for row in cursor.fetchall()
            ]
        except Exception as e:
            print(f"Error getting crashes: {e}")
            return []
        finally:
            conn.close()
    
    def get_device_crash_history(self, device_name=None, limit=100):
        """Get crash history, optionally filtered by device"""
        conn = self._connect_sqlite()
        if not conn:
            return []
        
        try:
            cursor = conn.cursor()
            if device_name:
                cursor.execute("""
                    SELECT id, device_name, crash_type, error_message, log_source,
                           log_line_start, log_line_end, is_during_startup, 
                           resolved, created_at
                    FROM device_crashes
                    WHERE device_name = ?
                    ORDER BY created_at DESC
                    LIMIT ?
                """, (device_name, limit))
            else:
                cursor.execute("""
                    SELECT id, device_name, crash_type, error_message, log_source,
                           log_line_start, log_line_end, is_during_startup,
                           resolved, created_at
                    FROM device_crashes
                    ORDER BY created_at DESC
                    LIMIT ?
                """, (limit,))
            
            return [
                {
                    'id': row[0],
                    'device': row[1],
                    'type': row[2],
                    'message': row[3],
                    'log_source': row[4],
                    'line_start': row[5],
                    'line_end': row[6],
                    'is_startup': bool(row[7]),
                    'resolved': bool(row[8]),
                    'time': row[9]
                }
                for row in cursor.fetchall()
            ]
        except Exception as e:
            print(f"Error getting crash history: {e}")
            return []
        finally:
            conn.close()
    
    def get_crash_log_context(self, crash_id, context_lines=50):
        """Get log context for a specific crash"""
        conn = self._connect_sqlite()
        if not conn:
            return {'error': 'Database not available'}
        
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT device_name, crash_type, error_message, log_source,
                       log_line_start, log_line_end, log_context, created_at
                FROM device_crashes
                WHERE id = ?
            """, (crash_id,))
            row = cursor.fetchone()
            
            if not row:
                return {'error': 'Crash not found'}
            
            result = {
                'device': row[0],
                'type': row[1],
                'message': row[2],
                'log_source': row[3],
                'line_start': row[4],
                'line_end': row[5],
                'stored_context': row[6],
                'time': row[7]
            }
            
            # Try to get fresh context from Docker logs
            if docker_client and row[3]:
                try:
                    container = docker_client.containers.get(row[3])
                    if container.status == 'running':
                        logs = container.logs(tail=2000, timestamps=True).decode('utf-8', errors='ignore')
                        lines = logs.split('\n')
                        
                        # Find the crash line and get context
                        crash_line = row[4] or 0
                        start = max(0, crash_line - context_lines)
                        end = min(len(lines), crash_line + context_lines)
                        
                        result['live_context'] = '\n'.join(lines[start:end])
                        result['context_range'] = {'start': start, 'end': end, 'crash_line': crash_line}
                except Exception as e:
                    result['live_context_error'] = str(e)
            
            return result
        except Exception as e:
            return {'error': str(e)}
        finally:
            conn.close()
    
    def record_device_event(self, device_name, event_type, details=None, 
                           log_source=None, log_line=None):
        """Record a device event"""
        conn = self._connect_sqlite()
        if not conn:
            return
        
        try:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO rotom_events (event_type, device_name, details, 
                                         log_source, log_line_number)
                VALUES (?, ?, ?, ?, ?)
            """, (event_type, device_name, json.dumps(details) if details else None,
                  log_source, log_line))
            
            # Update device stats based on event type
            if event_type == 'connect':
                cursor.execute("""
                    UPDATE rotom_devices SET 
                        total_connections = total_connections + 1,
                        is_online = 1,
                        last_connect_time = CURRENT_TIMESTAMP,
                        current_session_start = CURRENT_TIMESTAMP,
                        last_seen = CURRENT_TIMESTAMP
                    WHERE device_name = ?
                """, (device_name,))
                
            elif event_type in ('disconnect', 'worker_disconnect'):
                # Calculate session duration and update uptime
                cursor.execute("""
                    SELECT current_session_start FROM rotom_devices WHERE device_name = ?
                """, (device_name,))
                row = cursor.fetchone()
                session_duration = 0
                if row and row[0]:
                    try:
                        start = datetime.fromisoformat(row[0])
                        session_duration = int((datetime.now() - start).total_seconds())
                    except:
                        pass
                
                cursor.execute("""
                    UPDATE rotom_devices SET 
                        total_disconnections = total_disconnections + 1,
                        is_online = 0,
                        last_disconnect_time = CURRENT_TIMESTAMP,
                        total_uptime_seconds = total_uptime_seconds + ?,
                        last_seen = CURRENT_TIMESTAMP
                    WHERE device_name = ?
                """, (session_duration, device_name))
                
                # Record session
                cursor.execute("""
                    INSERT INTO device_sessions (device_name, session_start, session_end, 
                                                duration_seconds, end_reason)
                    VALUES (?, (SELECT current_session_start FROM rotom_devices WHERE device_name = ?),
                            CURRENT_TIMESTAMP, ?, ?)
                """, (device_name, device_name, session_duration, event_type))
                
            elif event_type in ('crash', 'error', 'timeout', 'failed'):
                cursor.execute("""
                    UPDATE rotom_devices SET 
                        total_crashes = total_crashes + 1,
                        last_seen = CURRENT_TIMESTAMP
                    WHERE device_name = ?
                """, (device_name,))
            
            conn.commit()
        except Exception as e:
            print(f"Error recording device event: {e}")
        finally:
            conn.close()
    
    def record_crash(self, device_name, crash_type, error_message, log_source,
                    log_line_start=None, log_line_end=None, log_context=None,
                    is_during_startup=False):
        """Record a device crash with log reference"""
        conn = self._connect_sqlite()
        if not conn:
            return None
        
        try:
            cursor = conn.cursor()
            
            # Check for similar recent crash (deduplication)
            cursor.execute("""
                SELECT id FROM device_crashes 
                WHERE device_name = ? AND crash_type = ? 
                AND error_message = ? AND log_source = ?
                AND created_at > datetime('now', '-5 minutes')
            """, (device_name, crash_type, error_message, log_source))
            existing = cursor.fetchone()
            
            if existing:
                # Link to existing crash instead of creating duplicate
                return existing[0]
            
            cursor.execute("""
                INSERT INTO device_crashes (device_name, crash_type, error_message,
                                           log_source, log_line_start, log_line_end,
                                           log_context, is_during_startup)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, (device_name, crash_type, error_message, log_source,
                  log_line_start, log_line_end, log_context, int(is_during_startup)))
            
            crash_id = cursor.lastrowid
            
            # Update device crash count
            cursor.execute("""
                INSERT INTO rotom_devices (device_name, total_crashes)
                VALUES (?, 1)
                ON CONFLICT(device_name) DO UPDATE SET
                    total_crashes = total_crashes + 1,
                    last_seen = CURRENT_TIMESTAMP
            """, (device_name,))
            
            conn.commit()
            return crash_id
        except Exception as e:
            print(f"Error recording crash: {e}")
            return None
        finally:
            conn.close()
    
    def get_device_summary(self):
        """Get summary statistics across all devices"""
        conn = self._connect_sqlite()
        if not conn:
            return {}
        
        try:
            cursor = conn.cursor()
            
            # Overall stats
            cursor.execute("""
                SELECT 
                    COUNT(*) as total_devices,
                    SUM(CASE WHEN is_online = 1 THEN 1 ELSE 0 END) as online_devices,
                    SUM(total_connections) as total_connections,
                    SUM(total_disconnections) as total_disconnections,
                    SUM(total_crashes) as total_crashes,
                    SUM(total_uptime_seconds) as total_uptime,
                    AVG(total_uptime_seconds) as avg_uptime
                FROM rotom_devices
            """)
            row = cursor.fetchone()
            
            summary = {
                'total_devices': row[0] or 0,
                'online_devices': row[1] or 0,
                'offline_devices': (row[0] or 0) - (row[1] or 0),
                'total_connections': row[2] or 0,
                'total_disconnections': row[3] or 0,
                'total_crashes': row[4] or 0,
                'total_uptime_seconds': row[5] or 0,
                'avg_uptime_seconds': row[6] or 0
            }
            
            # Recent crashes (last 24h)
            cursor.execute("""
                SELECT COUNT(*) FROM device_crashes
                WHERE created_at > datetime('now', '-24 hours')
            """)
            summary['crashes_24h'] = cursor.fetchone()[0] or 0
            
            # Devices with most crashes
            cursor.execute("""
                SELECT device_name, total_crashes 
                FROM rotom_devices 
                WHERE total_crashes > 0
                ORDER BY total_crashes DESC
                LIMIT 5
            """)
            summary['worst_devices'] = [
                {'device': row[0], 'crashes': row[1]} 
                for row in cursor.fetchall()
            ]
            
            # Recent events
            cursor.execute("""
                SELECT event_type, device_name, created_at 
                FROM rotom_events
                ORDER BY created_at DESC
                LIMIT 20
            """)
            summary['recent_events'] = [
                {'type': row[0], 'device': row[1], 'time': row[2]}
                for row in cursor.fetchall()
            ]
            
            summary['timestamp'] = datetime.now().isoformat()
            return summary
        except Exception as e:
            print(f"Error getting device summary: {e}")
            return {'error': str(e)}
        finally:
            conn.close()
    
    def parse_logs_for_crashes(self, container_name, log_content, line_offset=0):
        """Parse log content for device-related crashes and errors"""
        patterns = self.crash_patterns.get(container_name, [])
        crashes_found = []
        
        lines = log_content.split('\n')
        for i, line in enumerate(lines):
            line_num = line_offset + i
            
            for pattern, crash_type in patterns:
                match = pattern.search(line)
                if match:
                    device_name = match.group(1) if match.groups() else 'unknown'
                    
                    # Get context (5 lines before and after)
                    context_start = max(0, i - 5)
                    context_end = min(len(lines), i + 6)
                    context = '\n'.join(lines[context_start:context_end])
                    
                    crashes_found.append({
                        'device': device_name,
                        'type': crash_type,
                        'message': line.strip()[:500],  # Limit message length
                        'line': line_num,
                        'context': context
                    })
        
        return crashes_found

# Initialize device manager (will be done after ShellderDB is available)
device_manager = None

# =============================================================================
# DEVICE MONITOR - Real-Time Activity Listener
# =============================================================================

class DeviceMonitor:
    """
    Real-time monitor for the device scanning workflow:
    
    ┌──────────────┐      WebSocket      ┌──────────────┐      WebSocket      ┌──────────────┐
    │ Phone/Aegis  │◄──────:7070────────►│    Rotom     │◄──────:7071────────►│  Dragonite   │
    │   Device     │                     │   Manager    │                     │   Scanner    │
    └──────────────┘                     └──────────────┘                     └──────────────┘
    
    Tracks the complete lifecycle:
    1. Device connects to Rotom (port 7070)
    2. Rotom assigns worker ID, notifies Dragonite (port 7071)
    3. Dragonite assigns account and tasks
    4. Device scans, data flows: Device → Rotom → Dragonite → Golbat
    5. Disconnects/errors correlated across both containers
    
    Cross-references logs, database, and Docker to find disconnects.
    """
    
    def __init__(self, device_manager_ref, shellder_db_ref):
        self.device_manager = device_manager_ref
        self.shellder_db = shellder_db_ref
        self.running = False
        self.lock = threading.Lock()
        
        # Device state tracking (core purpose)
        self.devices = {}  # {device_name: DeviceState dict}
        self.workers = {}  # {worker_id: device_name} - Rotom worker mapping
        
        # Activity feed for GUI
        self.activity_feed = []  # Recent events (max 200)
        
        # Legacy compatibility
        self.device_states = self.devices  # Alias
        
        # Cross-correlation
        self.pending_tasks = {}  # {device: task info}
        self.recent_disconnects = {}  # For correlating disconnect → error chains
        self.correlation_window = 30  # seconds
        
        # Container health (secondary)
        self.container_states = {}
        self.error_counts = defaultdict(int)
        self.recent_events = []
        
        # Only stream logs from Rotom and Dragonite (device workflow)
        self.monitored_containers = ['rotom', 'dragonite']
        
        # All containers for health dashboard
        self.health_containers = ['rotom', 'dragonite', 'golbat', 'database', 'koji', 'reactmap', 'xilriws']
        
        self.log_threads = {}
        self.health_thread = None
        self.db_poll_thread = None
        
        # Compile regex patterns
        self._compile_patterns()
    
    def _compile_patterns(self):
        """Compile regex patterns for log parsing"""
        self.patterns = {
            'rotom': {
                # Real log format: [2025-12-01T09:09:26.082Z] [INFO] [rotom] CONTROLLER: Found OrangePi5 connects to workerId OrangePi5-1
                'device_connect': re.compile(
                    r'\[([^\]]+)\].*CONTROLLER:\s*Found\s+(\S+)\s+connects\s+to\s+workerId\s+(\S+)'
                ),
                # Worker allocation: CONTROLLER: New connection from ::ffff:172.18.0.11 - will allocate OrangePi5-1
                'worker_allocate': re.compile(
                    r'\[([^\]]+)\].*CONTROLLER:\s*New connection from\s+(\S+)\s*-\s*will allocate\s+(\S+)'
                ),
                # Device disconnect: OrangePi5-1/1041: Disconnected; performing disconnection activities
                'device_disconnect': re.compile(
                    r'\[([^\]]+)\].*(\S+)/(\d+):\s*Disconnected.*disconnection activities'
                ),
                # Controller disconnect: CONTROLLER: Disconnected worker New York_01/Gti6h7/1013 device
                'worker_disconnect': re.compile(
                    r'\[([^\]]+)\].*CONTROLLER:\s*Disconnected worker\s+(\S+)/(\S+)/(\d+)\s+device'
                ),
                # No spare workers: CONTROLLER: New connection from X - no spare Workers
                'connection_rejected': re.compile(
                    r'\[([^\]]+)\].*CONTROLLER:\s*New connection from\s+(\S+)\s*-\s*no spare Workers'
                ),
                # New device connection: Device: New connection from ::ffff:162.231.202.34 url /
                'new_connection': re.compile(
                    r'\[([^\]]+)\].*Device:\s*New connection from\s+(\S+)\s+url'
                ),
                # ID packet: OrangePi5-1/1042: Received id packet origin PokemodAegis-OrangePi5 - version 25112701
                'device_id': re.compile(
                    r'\[([^\]]+)\].*(\S+)/(\d+):\s*Received id packet origin\s+(\S+)\s*-\s*version\s+(\d+)'
                ),
                # Memory report: OrangePi5/572:Memory = {"memFree":13038528,"memMitm":651628,"memStart":510180}
                'memory': re.compile(
                    r'\[([^\]]+)\].*(\S+)/(\d+):Memory\s*=\s*(\{[^}]+\})'
                ),
                # Unallocated connections: OrangePi5-1: unallocated connections = OrangePi5-1
                'unallocated': re.compile(
                    r'\[([^\]]+)\].*(\S+):\s*unallocated connections\s*=\s*(.*)'
                ),
                # Errors
                'error': re.compile(
                    r'\[([^\]]+)\].*\[(ERROR|error)\].*rotom.*(.+)', re.I
                ),
                'timeout': re.compile(
                    r'\[([^\]]+)\].*(timeout|timed out)', re.I
                ),
            },
            'dragonite': {
                # Real Dragonite log format: INFO 2025-12-01 09:38:15 [New York_01] Catching PIKACHU
                
                # Catch attempt: Catching POKEMON (ball: ITEM_X, capture rate: 0.XXX)
                'catch_attempt': re.compile(
                    r'INFO.*\[([^\]]+)\]\s*Catching\s+(\S+)\s*\(ball:\s*(\S+),\s*capture rate:\s*([\d.]+)\)'
                ),
                # Catch result: Catch: CATCH_SUCCESS/CATCH_FLEE/CATCH_ESCAPE POKEMON Wild/Lure
                'catch_result': re.compile(
                    r'INFO.*\[([^\]]+)\]\s*Catch:\s+(CATCH_SUCCESS|CATCH_FLEE|CATCH_ESCAPE)\s+(\S+)\s+(Wild|Lure)'
                ),
                # Location complete: Done with level location after X.XXs: X spins, X encounters, X catches
                'location_complete': re.compile(
                    r'INFO.*\[([^\]]+)\]\s*Done with level location after ([\d.]+)s:\s*(\d+)\s*spins,\s*(\d+)\s*encounters,\s*(\d+)\s*catches,\s*(\d+)\s*fled,\s*(\d+)\s*escaped'
                ),
                # Fort spin success: Successfully spun Fort XXXXX
                'fort_spin': re.compile(
                    r'INFO.*\[([^\]]+)\]\s*Successfully spun Fort\s+(\S+)'
                ),
                # Level up: Leveled up to X
                'level_up': re.compile(
                    r'INFO.*\[([^\]]+)\]\s*Leveled up to\s+(\d+)'
                ),
                # Player stats: [Player stats] [Session: Xm Ys ID] Level: X -> Y | XP made: X
                'player_stats': re.compile(
                    r'INFO.*\[([^\]]+)\]\s*\[Player stats\].*Level:\s*(\d+)\s*->\s*(\d+)\s*\|\s*XP made:\s*(\d+).*Stops spun:\s*(\d+).*Mons caught:\s*(\d+)'
                ),
                # GMO received: Got a GMO: X cells | Y pokemon
                'gmo_received': re.compile(
                    r'INFO.*\[([^\]]+)\]\s*Got a GMO:\s*(\d+)\s*cells\s*\|\s*(\d+)\s*pokemon'
                ),
                # Movement: Moving to X.X/82 LAT, LON
                'movement': re.compile(
                    r'INFO.*\[([^\]]+)\]\s*Moving to\s+([\d.]+)/(\d+)\s+([\d.-]+),\s*([\d.-]+)'
                ),
                # APICHECK: APICHECK: X is OK/not reachable
                'api_check': re.compile(
                    r'INFO.*\[\]\s*APICHECK:\s*(\S+).*is\s+(OK|not reachable)'
                ),
                # Auth error: PTC Auth - Remote Auth for USER - Error
                'auth_error': re.compile(
                    r'ERRO.*\[([^\]]+)\]\s*PTC Auth.*for\s+(\S+)\s*-\s*Error.*?:\s*(.+)'
                ),
                # Auth failed warning
                'auth_failed': re.compile(
                    r'WARN.*\[([^\]]+)\].*Authentication failed for user\s+(\S+)'
                ),
                # Token refresh: Background token refresher
                'token_refresh': re.compile(
                    r'INFO.*\[([^\]]+)\]\s*Background token (initer|refresher):\s*(.+)'
                ),
                # Scout queue
                'scout_queue': re.compile(
                    r'INFO.*\[\]\s*SCOUT:\s*(\d+)\s*locations in queue'
                ),
                # Fatal error
                'fatal': re.compile(
                    r'FATL.*\[([^\]]*)\]\s*(.+)'
                ),
                # General error
                'error': re.compile(
                    r'ERRO.*\[([^\]]+)\]\s*(.+)'
                ),
            },
            'golbat': {
                'pokemon_received': re.compile(
                    r'\[([^\]]+)\].*received.*pokemon', re.I
                ),
                'webhook_sent': re.compile(
                    r'\[([^\]]+)\].*webhook.*(sent|success|failed)', re.I
                ),
                'error': re.compile(
                    r'\[([^\]]+)\].*\[(ERROR|error)\].*(.+)', re.I
                ),
            },
            'koji': {
                # Koji/Rust log format: [2025-11-28T03:54:15Z LEVEL module] message
                'startup': re.compile(
                    r'\[([^\]]+)\]\s+INFO\s+actix_server::server\].*starting service.*listening on:\s*([^\s]+)'
                ),
                'scanner_type': re.compile(
                    r'\[([^\]]+)\]\s+INFO\s+model::utils\].*Determined Scanner Type:\s*(\w+)'
                ),
                'slow_db_acquire': re.compile(
                    r'\[([^\]]+)\]\s+WARN\s+sqlx::pool::acquire\].*acquired_after_secs=([0-9.]+)'
                ),
                'migration': re.compile(
                    r'\[([^\]]+)\]\s+INFO\s+sea_orm_migration::migrator\]\s*(.+)'
                ),
                'http_request': re.compile(
                    r'\[([^\]]+)\]\s+INFO\s+actix_web::middleware::logger\]\s*(\d+)\s*\|\s*(\w+)\s+([^\s]+)'
                ),
                'stream_error': re.compile(
                    r'\[([^\]]+)\]\s+ERROR\s+actix_http::h1::dispatcher\].*stream error.*parse error:\s*(.+)'
                ),
                'geofence': re.compile(
                    r'\[([^\]]+)\]\s+INFO\s+api::public::v1::geofence\].*Returning\s+(\d+)\s+instances'
                ),
                'error': re.compile(
                    r'\[([^\]]+)\]\s+ERROR\s+(?!actix_http::h1::dispatcher).*\]\s*(.+)'
                ),
            },
            'database': {
                # MariaDB log format: 2025-11-27 22:54:09-05:00 [Note] message
                # or: 2025-11-27 22:54:10 0 [Note] message
                'ready': re.compile(
                    r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*ready for connections'
                ),
                'aborted_connection': re.compile(
                    r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*Aborted connection \d+ to db: \'(\w+)\' user: \'(\w+)\' host: \'([^\']+)\' \((.+)\)'
                ),
                'timeout': re.compile(
                    r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*(timeout|timed out)', re.I
                ),
                'startup': re.compile(
                    r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*Starting MariaDB ([^ ]+)'
                ),
                'warning': re.compile(
                    r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*\[Warn(?:ing)?\].*(.+)'
                ),
                'error': re.compile(
                    r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*\[ERROR\].*(.+)', re.I
                ),
                'innodb': re.compile(
                    r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*InnoDB: (.+)'
                ),
                'socket_listen': re.compile(
                    r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*Server socket created.*port: \'(\d+)\''
                ),
            }
        }
    
    def start(self):
        """Start the real-time monitor"""
        if self.running:
            return
        
        self.running = True
        print("[DeviceMonitor] Starting device activity monitor...")
        print("[DeviceMonitor] Tracking: Phone ↔ Rotom ↔ Dragonite workflow")
        
        # Start log streaming threads for Rotom and Dragonite only
        for container in self.monitored_containers:
            thread = threading.Thread(
                target=self._stream_container_logs,
                args=(container,),
                daemon=True,
                name=f"DeviceMonitor-{container}"
            )
            self.log_threads[container] = thread
            thread.start()
        
        # Start container health monitor
        self.health_thread = threading.Thread(
            target=self._monitor_container_health,
            daemon=True,
            name="DeviceMonitor-Health"
        )
        self.health_thread.start()
        
        # Start database polling for device status
        self.db_poll_thread = threading.Thread(
            target=self._poll_database_devices,
            daemon=True,
            name="DeviceMonitor-DB"
        )
        self.db_poll_thread.start()
        
        print(f"[DeviceMonitor] Streaming logs from: {', '.join(self.monitored_containers)}")
    
    def stop(self):
        """Stop the monitor"""
        self.running = False
        print("[DeviceMonitor] Stopped")
    
    def _stream_container_logs(self, container_name):
        """Stream logs from a container in real-time"""
        while self.running:
            if not docker_client:
                time.sleep(30)
                continue
            
            try:
                container = docker_client.containers.get(container_name)
                
                # Update container state
                self._update_container_state(container_name, container)
                
                if container.status != 'running':
                    self._emit_event({
                        'type': 'container_down',
                        'container': container_name,
                        'status': container.status,
                        'severity': 'warning'
                    })
                    time.sleep(10)
                    continue
                
                # Stream logs with follow=True for real-time
                log_stream = container.logs(
                    stream=True,
                    follow=True,
                    tail=0,  # Only new logs
                    timestamps=True
                )
                
                for log_line in log_stream:
                    if not self.running:
                        break
                    
                    try:
                        line = log_line.decode('utf-8', errors='ignore').strip()
                        if line:
                            self._process_log_line(container_name, line)
                    except Exception as e:
                        print(f"[DeviceMonitor] Error processing log line: {e}")
                
            except Exception as e:
                error_msg = str(e)
                if 'No such container' not in error_msg:
                    print(f"[DeviceMonitor] Error streaming {container_name}: {e}")
                    self._emit_event({
                        'type': 'container_error',
                        'container': container_name,
                        'error': error_msg,
                        'severity': 'error'
                    })
                time.sleep(5)
    
    def _process_log_line(self, container, line):
        """Process a single log line and detect events"""
        patterns = self.patterns.get(container, {})
        
        for event_type, pattern in patterns.items():
            match = pattern.search(line)
            if match:
                event = self._create_event(container, event_type, match, line)
                if event:
                    self._handle_event(event)
                    return  # Only process first match
    
    def _create_event(self, container, event_type, match, raw_line):
        """Create an event object from a regex match"""
        groups = match.groups()
        timestamp = groups[0] if groups else datetime.now().isoformat()
        
        event = {
            'id': f"{container}-{event_type}-{int(time.time()*1000)}",
            'type': event_type,
            'container': container,
            'timestamp': timestamp,
            'raw': raw_line[:500],  # Limit size
            'created_at': datetime.now().isoformat()
        }
        
        # Extract device/worker info based on event type
        if container == 'rotom':
            # Device connected to worker: Found OrangePi5 connects to workerId OrangePi5-1
            if event_type == 'device_connect':
                event['device'] = groups[1] if len(groups) > 1 else None
                event['worker'] = groups[2] if len(groups) > 2 else None
                event['severity'] = 'success'
            
            # Worker allocation: New connection from ::ffff:172.18.0.11 - will allocate OrangePi5-1
            elif event_type == 'worker_allocate':
                event['source_ip'] = groups[1] if len(groups) > 1 else None
                event['worker'] = groups[2] if len(groups) > 2 else None
                event['severity'] = 'info'
            
            # Device disconnect: OrangePi5-1/1041: Disconnected
            elif event_type == 'device_disconnect':
                event['device'] = groups[1] if len(groups) > 1 else None
                event['connection_id'] = groups[2] if len(groups) > 2 else None
                event['severity'] = 'warning'
            
            # Worker disconnect: Disconnected worker New York_01/Gti6h7/1013 device
            elif event_type == 'worker_disconnect':
                event['instance'] = groups[1] if len(groups) > 1 else None  # New York_01
                event['session'] = groups[2] if len(groups) > 2 else None   # Gti6h7
                event['connection_id'] = groups[3] if len(groups) > 3 else None  # 1013
                event['severity'] = 'warning'
            
            # Connection rejected - no spare workers
            elif event_type == 'connection_rejected':
                event['ip'] = groups[1] if len(groups) > 1 else None
                event['severity'] = 'warning'
            
            # New connection from device IP
            elif event_type == 'new_connection':
                event['device_ip'] = groups[1] if len(groups) > 1 else None
                event['severity'] = 'info'
            
            # ID packet: Received id packet origin PokemodAegis-OrangePi5 - version 25112701
            elif event_type == 'device_id':
                event['device'] = groups[1] if len(groups) > 1 else None
                event['connection_id'] = groups[2] if len(groups) > 2 else None
                event['origin'] = groups[3] if len(groups) > 3 else None
                event['version'] = groups[4] if len(groups) > 4 else None
                event['severity'] = 'info'
            
            # Memory report: OrangePi5/572:Memory = {"memFree":13038528,"memMitm":651628,"memStart":510180}
            elif event_type == 'memory':
                device_name = groups[1] if len(groups) > 1 else None
                event['device'] = device_name
                event['connection_id'] = groups[2] if len(groups) > 2 else None
                try:
                    mem_data = json.loads(groups[3]) if len(groups) > 3 else {}
                    event['memory'] = mem_data
                    event['mem_free_mb'] = round(mem_data.get('memFree', 0) / 1024, 1)
                    event['mem_mitm_mb'] = round(mem_data.get('memMitm', 0) / 1024, 1)
                    
                    # Track memory in device state (silently)
                    if device_name:
                        self._update_device_memory(device_name, mem_data)
                except:
                    pass
                event['severity'] = 'info'
                return None  # Don't emit memory events (too noisy), just track
            
            # Unallocated connections
            elif event_type == 'unallocated':
                event['device'] = groups[1] if len(groups) > 1 else None
                event['unallocated'] = groups[2].strip() if len(groups) > 2 else ''
                event['severity'] = 'info'
                return None  # Don't emit, just track
            
            elif event_type in ('error', 'timeout'):
                event['message'] = groups[-1] if len(groups) > 1 else raw_line
                event['severity'] = 'error'
        
        elif container == 'dragonite':
            # Instance name from most events
            instance = groups[0] if groups else None
            event['instance'] = instance
            
            if event_type == 'catch_attempt':
                # Catching POKEMON (ball: X, capture rate: Y)
                event['pokemon'] = groups[1] if len(groups) > 1 else None
                event['ball'] = groups[2] if len(groups) > 2 else None
                event['capture_rate'] = float(groups[3]) if len(groups) > 3 else None
                event['severity'] = 'info'
                self._update_instance_stats(instance, 'catch_attempts', 1)
                return None  # Don't emit, too noisy
            
            elif event_type == 'catch_result':
                # Catch: CATCH_SUCCESS/FLEE/ESCAPE POKEMON Wild/Lure
                event['result'] = groups[1] if len(groups) > 1 else None
                event['pokemon'] = groups[2] if len(groups) > 2 else None
                event['spawn_type'] = groups[3] if len(groups) > 3 else None
                event['severity'] = 'success' if 'SUCCESS' in str(event['result']) else 'info'
                self._update_instance_stats(instance, 'catches' if 'SUCCESS' in str(event['result']) else 'fled', 1)
                return None  # Don't emit, too noisy
            
            elif event_type == 'location_complete':
                # Done with level location after X.XXs: X spins, X encounters, X catches
                event['duration'] = float(groups[1]) if len(groups) > 1 else 0
                event['spins'] = int(groups[2]) if len(groups) > 2 else 0
                event['encounters'] = int(groups[3]) if len(groups) > 3 else 0
                event['catches'] = int(groups[4]) if len(groups) > 4 else 0
                event['fled'] = int(groups[5]) if len(groups) > 5 else 0
                event['escaped'] = int(groups[6]) if len(groups) > 6 else 0
                event['severity'] = 'info'
                self._update_instance_stats(instance, 'locations', 1)
                return None  # Track but don't emit
            
            elif event_type == 'fort_spin':
                event['fort_id'] = groups[1] if len(groups) > 1 else None
                event['severity'] = 'info'
                self._update_instance_stats(instance, 'spins', 1)
                return None  # Track but don't emit
            
            elif event_type == 'level_up':
                event['new_level'] = int(groups[1]) if len(groups) > 1 else None
                event['severity'] = 'success'
                # Emit level ups - these are interesting
            
            elif event_type == 'player_stats':
                # [Player stats] Level: X -> Y | XP made: Z
                event['old_level'] = int(groups[1]) if len(groups) > 1 else None
                event['new_level'] = int(groups[2]) if len(groups) > 2 else None
                event['xp_made'] = int(groups[3]) if len(groups) > 3 else 0
                event['stops_spun'] = int(groups[4]) if len(groups) > 4 else 0
                event['mons_caught'] = int(groups[5]) if len(groups) > 5 else 0
                event['severity'] = 'success'
                # Emit player stats - useful summary
            
            elif event_type == 'gmo_received':
                event['cells'] = int(groups[1]) if len(groups) > 1 else 0
                event['pokemon'] = int(groups[2]) if len(groups) > 2 else 0
                event['severity'] = 'info'
                return None  # Too noisy
            
            elif event_type == 'movement':
                event['step'] = groups[1] if len(groups) > 1 else None
                event['total_steps'] = groups[2] if len(groups) > 2 else None
                event['lat'] = groups[3] if len(groups) > 3 else None
                event['lon'] = groups[4] if len(groups) > 4 else None
                event['severity'] = 'info'
                return None  # Too noisy
            
            elif event_type == 'api_check':
                event['service'] = groups[0] if groups else None
                event['status'] = groups[1] if len(groups) > 1 else None
                event['severity'] = 'success' if event['status'] == 'OK' else 'error'
                # Only emit failures
                if event['status'] == 'OK':
                    return None
            
            elif event_type == 'auth_error':
                event['worker'] = groups[0] if groups else None
                event['username'] = groups[1] if len(groups) > 1 else None
                event['error_msg'] = groups[2] if len(groups) > 2 else None
                event['severity'] = 'error'
                # Emit auth errors
            
            elif event_type == 'auth_failed':
                event['worker'] = groups[0] if groups else None
                event['username'] = groups[1] if len(groups) > 1 else None
                event['severity'] = 'warning'
            
            elif event_type == 'token_refresh':
                event['worker'] = groups[0] if groups else None
                event['action'] = groups[1] if len(groups) > 1 else None
                event['message'] = groups[2] if len(groups) > 2 else None
                event['severity'] = 'info'
                return None  # Routine
            
            elif event_type == 'scout_queue':
                event['queue_size'] = int(groups[0]) if groups else 0
                event['severity'] = 'info'
                return None  # Routine
            
            elif event_type == 'fatal':
                event['message'] = groups[1] if len(groups) > 1 else raw_line
                event['severity'] = 'critical'
                # Always emit fatal errors
            
            elif event_type == 'error':
                event['message'] = groups[1] if len(groups) > 1 else raw_line
                event['severity'] = 'error'
                # Emit errors
        
        elif container == 'golbat':
            event['severity'] = 'error' if 'error' in event_type else 'info'
        
        elif container == 'koji':
            if event_type == 'startup':
                event['listen_address'] = groups[1] if len(groups) > 1 else None
                event['severity'] = 'success'
            elif event_type == 'scanner_type':
                event['scanner_type'] = groups[1] if len(groups) > 1 else None
                event['severity'] = 'info'
            elif event_type == 'slow_db_acquire':
                event['acquire_seconds'] = groups[1] if len(groups) > 1 else None
                event['severity'] = 'warning'
            elif event_type == 'migration':
                event['message'] = groups[1] if len(groups) > 1 else None
                event['severity'] = 'info'
            elif event_type == 'http_request':
                event['status_code'] = groups[1] if len(groups) > 1 else None
                event['method'] = groups[2] if len(groups) > 2 else None
                event['path'] = groups[3] if len(groups) > 3 else None
                # Only log non-200 or interesting paths
                status = int(event.get('status_code', 200) or 200)
                if status >= 400:
                    event['severity'] = 'warning'
                else:
                    return None  # Skip normal 200 requests
            elif event_type == 'stream_error':
                # These are usually from bots/scanners - mark as info not error
                event['parse_error'] = groups[1] if len(groups) > 1 else None
                event['severity'] = 'info'  # Not a real error
                event['note'] = 'Bot/scanner probe (harmless)'
            elif event_type == 'geofence':
                event['instance_count'] = groups[1] if len(groups) > 1 else None
                event['severity'] = 'info'
            elif event_type == 'error':
                event['message'] = groups[1] if len(groups) > 1 else raw_line
                event['severity'] = 'error'
        
        elif container == 'database':
            if event_type == 'ready':
                event['severity'] = 'success'
                event['message'] = 'Database ready for connections'
            elif event_type == 'aborted_connection':
                event['database'] = groups[1] if len(groups) > 1 else None
                event['db_user'] = groups[2] if len(groups) > 2 else None
                event['host'] = groups[3] if len(groups) > 3 else None
                event['reason'] = groups[4] if len(groups) > 4 else None
                event['severity'] = 'warning'
                # Try to identify which service this connection was from
                if event.get('database'):
                    event['affected_service'] = event['database']
            elif event_type == 'timeout':
                event['severity'] = 'warning'
            elif event_type == 'startup':
                event['version'] = groups[1] if len(groups) > 1 else None
                event['severity'] = 'info'
            elif event_type == 'warning':
                event['message'] = groups[1] if len(groups) > 1 else raw_line
                event['severity'] = 'warning'
            elif event_type == 'error':
                event['message'] = groups[1] if len(groups) > 1 else raw_line
                event['severity'] = 'error'
            elif event_type == 'innodb':
                event['message'] = groups[1] if len(groups) > 1 else raw_line
                event['severity'] = 'info'
            elif event_type == 'socket_listen':
                event['port'] = groups[1] if len(groups) > 1 else '3306'
                event['severity'] = 'success'
        
        return event
    
    def _handle_event(self, event):
        """Handle a detected event from Rotom or Dragonite logs"""
        event_type = event.get('type')
        device = event.get('device')
        worker = event.get('worker')
        container = event.get('container')
        severity = event.get('severity', 'info')
        
        # Track worker → device mapping (from Rotom)
        if worker and device and container == 'rotom':
            with self.lock:
                self.workers[worker] = device
        
        # Update device state
        if device:
            with self.lock:
                if device not in self.devices:
                    self.devices[device] = {
                        'name': device,
                        'status': 'unknown',
                        'source': container,
                        'worker': worker,
                        'last_event': None,
                        'events': [],
                        'errors': 0,
                        'connections': 0,
                        'disconnections': 0,
                        'tasks_assigned': 0,
                        'tasks_completed': 0
                    }
                
                state = self.devices[device]
                state['last_event'] = event
                state['events'].append(event)
                state['events'] = state['events'][-30:]  # Keep last 30
                
                # Update counters based on event type
                if event_type == 'device_connect':
                    state['status'] = 'connected'
                    state['connections'] += 1
                    state['last_connect'] = event.get('timestamp')
                    state['worker'] = worker
                    state['source'] = 'rotom'
                    # Clear any pending disconnect correlation
                    self.recent_disconnects.pop(device, None)
                    
                elif event_type in ('device_disconnect', 'worker_disconnect'):
                    state['status'] = 'disconnected'
                    state['disconnections'] += 1
                    state['last_disconnect'] = event.get('timestamp')
                    # Track for correlation with Dragonite
                    self.recent_disconnects[device] = time.time()
                    
                elif event_type == 'task_assigned':
                    state['tasks_assigned'] += 1
                    state['last_task'] = event.get('timestamp')
                    
                elif event_type == 'task_complete':
                    state['tasks_completed'] += 1
                    
                elif event_type in ('device_error', 'error') or severity in ('error', 'critical'):
                    state['errors'] += 1
                    state['last_error'] = event.get('timestamp')
                    # Check if this correlates with a recent disconnect
                    self._check_disconnect_correlation(device, event)
        
        # Record crash if significant
        if severity in ('error', 'critical') or 'disconnect' in event_type:
            self._record_crash_event(event)
            # Analyze cross-container correlation
            self._analyze_crash_correlation(event)
        
        # Add to activity feed
        self._add_to_feed(event)
        
        # Correlate with other recent events
        self._correlate_event(event)
        
        # Emit via WebSocket
        self._emit_event(event)
    
    def _update_instance_stats(self, instance, stat_name, increment):
        """Update scanning stats for an instance (silently)"""
        if not instance:
            return
        
        with self.lock:
            if not hasattr(self, 'instance_stats'):
                self.instance_stats = {}
            
            if instance not in self.instance_stats:
                self.instance_stats[instance] = {
                    'name': instance,
                    'catches': 0,
                    'fled': 0,
                    'escaped': 0,
                    'catch_attempts': 0,
                    'spins': 0,
                    'locations': 0,
                    'last_activity': None,
                    'session_start': datetime.now().isoformat()
                }
            
            stats = self.instance_stats[instance]
            if stat_name in stats:
                stats[stat_name] += increment
            stats['last_activity'] = datetime.now().isoformat()
    
    def _update_device_memory(self, device_name, mem_data):
        """Update device memory stats without emitting an event"""
        with self.lock:
            if device_name not in self.devices:
                self.devices[device_name] = {
                    'name': device_name,
                    'status': 'connected',
                    'source': 'rotom',
                    'events': [],
                    'errors': 0
                }
            
            dev = self.devices[device_name]
            dev['last_memory_report'] = datetime.now().isoformat()
            dev['memory'] = {
                'free_kb': mem_data.get('memFree', 0),
                'free_mb': round(mem_data.get('memFree', 0) / 1024, 1),
                'mitm_kb': mem_data.get('memMitm', 0),
                'mitm_mb': round(mem_data.get('memMitm', 0) / 1024, 1),
                'start_kb': mem_data.get('memStart', 0)
            }
            
            # Track memory history (last 10 readings)
            if 'memory_history' not in dev:
                dev['memory_history'] = []
            dev['memory_history'].append({
                'time': datetime.now().isoformat(),
                'free_mb': dev['memory']['free_mb'],
                'mitm_mb': dev['memory']['mitm_mb']
            })
            dev['memory_history'] = dev['memory_history'][-10:]
            
            # Check for low memory warning
            free_mb = dev['memory']['free_mb']
            if free_mb < 500:  # Less than 500MB free
                self._emit_event({
                    'type': 'low_memory_warning',
                    'device': device_name,
                    'free_mb': free_mb,
                    'severity': 'warning',
                    'message': f'Device {device_name} low on memory: {free_mb}MB free'
                })
    
    def _check_disconnect_correlation(self, device, error_event):
        """Check if an error correlates with a recent disconnect"""
        disconnect_time = self.recent_disconnects.get(device)
        if disconnect_time:
            elapsed = time.time() - disconnect_time
            if elapsed < self.correlation_window:
                # Error occurred shortly after disconnect - they're related
                error_event['correlated_disconnect'] = True
                error_event['disconnect_seconds_ago'] = int(elapsed)
                
                # Emit a correlation event
                self._emit_event({
                    'type': 'disconnect_error_chain',
                    'device': device,
                    'severity': 'warning',
                    'message': f'Device disconnect followed by error within {int(elapsed)}s - likely related',
                    'original_error': error_event.get('message', error_event.get('raw', ''))[:100]
                })
    
    def _analyze_crash_correlation(self, event):
        """
        Analyze if this crash correlates with crashes in other containers.
        A crash in Rotom within 10 seconds of a crash in Dragonite = same incident.
        """
        device = event.get('device')
        container = event.get('container')
        event_time = time.time()
        
        # Store this crash for correlation
        crash_key = f"{device}:{container}"
        if not hasattr(self, 'crash_history'):
            self.crash_history = {}
        
        self.crash_history[crash_key] = {
            'time': event_time,
            'event': event,
            'container': container,
            'device': device
        }
        
        # Look for correlated crash in other container
        other_container = 'dragonite' if container == 'rotom' else 'rotom'
        other_key = f"{device}:{other_container}"
        
        if other_key in self.crash_history:
            other_crash = self.crash_history[other_key]
            time_diff = abs(event_time - other_crash['time'])
            
            if time_diff <= 10:  # Within 10 seconds = same incident
                # Determine root cause - which happened first?
                if other_crash['time'] < event_time:
                    origin = other_container
                    origin_event = other_crash['event']
                    follow_event = event
                else:
                    origin = container
                    origin_event = event
                    follow_event = other_crash['event']
                
                # Analyze the root cause
                root_cause = self._determine_root_cause(origin, origin_event, follow_event)
                
                correlation = {
                    'type': 'correlated_crash',
                    'device': device,
                    'severity': 'error',
                    'origin_container': origin,
                    'time_diff_seconds': round(time_diff, 2),
                    'root_cause': root_cause,
                    'origin_event': origin_event.get('type'),
                    'origin_message': origin_event.get('raw', '')[:150],
                    'follow_event': follow_event.get('type'),
                    'follow_message': follow_event.get('raw', '')[:150]
                }
                
                self._emit_event(correlation)
                self._add_to_feed(correlation)
                
                # Store for later analysis
                if device:
                    with self.lock:
                        if device in self.devices:
                            if 'correlated_crashes' not in self.devices[device]:
                                self.devices[device]['correlated_crashes'] = []
                            self.devices[device]['correlated_crashes'].append(correlation)
                            # Keep last 10
                            self.devices[device]['correlated_crashes'] = \
                                self.devices[device]['correlated_crashes'][-10:]
                
                return correlation
        
        return None
    
    def _determine_root_cause(self, origin_container, origin_event, follow_event):
        """Analyze events to determine the root cause of a correlated crash"""
        origin_type = origin_event.get('type', '')
        origin_msg = origin_event.get('raw', '').lower()
        
        # Common root causes
        if origin_container == 'rotom':
            if 'disconnect' in origin_type:
                if 'network' in origin_msg or 'timeout' in origin_msg:
                    return {
                        'cause': 'network_issue',
                        'description': 'Device lost network connection',
                        'recommendation': 'Check device WiFi/cellular, Rotom server network'
                    }
                elif 'memory' in origin_msg:
                    return {
                        'cause': 'device_memory',
                        'description': 'Device ran out of memory',
                        'recommendation': 'Check device memory, close other apps'
                    }
                else:
                    return {
                        'cause': 'device_disconnect',
                        'description': 'Device disconnected from Rotom (cause unknown)',
                        'recommendation': 'Check device logs, battery, app stability'
                    }
            elif 'rejected' in origin_type:
                return {
                    'cause': 'no_workers',
                    'description': 'No available workers in Rotom',
                    'recommendation': 'Check max_workers setting in rotom_config.json'
                }
        
        elif origin_container == 'dragonite':
            if 'account' in origin_type or 'banned' in origin_msg or 'auth' in origin_msg:
                return {
                    'cause': 'account_issue',
                    'description': 'Account problem (banned, invalid, or auth failure)',
                    'recommendation': 'Check account status, Xilriws proxy health'
                }
            elif 'api' in origin_type.lower() or 'golbat' in origin_msg:
                return {
                    'cause': 'api_failure',
                    'description': 'Internal API communication failure',
                    'recommendation': 'Check Golbat status, database connection'
                }
            elif 'database' in origin_msg or 'sql' in origin_msg:
                return {
                    'cause': 'database_error',
                    'description': 'Database connection or query failure',
                    'recommendation': 'Check MariaDB status, connection pool'
                }
        
        # Generic fallback
        return {
            'cause': 'unknown',
            'description': f'Crash originated in {origin_container}',
            'recommendation': 'Review logs for more context'
        }
    
    def _add_to_feed(self, event):
        """Add event to activity feed"""
        with self.lock:
            self.activity_feed.insert(0, event)
            self.activity_feed = self.activity_feed[:200]  # Keep last 200
    
    def _correlate_event(self, event):
        """Correlate event with recent events from other containers"""
        device = event.get('device')
        if not device:
            return
        
        now = time.time()
        
        # Clean old events
        self.recent_events = [
            e for e in self.recent_events
            if now - e.get('_time', 0) < self.correlation_window
        ]
        
        # Add current event
        event['_time'] = now
        self.recent_events.append(event)
        
        # Look for correlations
        related = [
            e for e in self.recent_events
            if e.get('device') == device and e['id'] != event['id']
        ]
        
        if related:
            event['related_events'] = [e['id'] for e in related]
    
    def _record_crash_event(self, event):
        """Record crash/error to database"""
        if not self.device_manager:
            return
        
        device = event.get('device', 'unknown')
        crash_type = event.get('type', 'unknown')
        message = event.get('raw', event.get('message', ''))[:500]
        
        self.device_manager.record_crash(
            device_name=device,
            crash_type=crash_type,
            error_message=message,
            log_source=event.get('container', 'unknown'),
            log_context=event.get('raw', '')
        )
    
    def _monitor_container_health(self):
        """Monitor container health and detect restarts/failures"""
        last_states = {}
        
        while self.running:
            if not docker_client:
                time.sleep(30)
                continue
            
            for container_name in self.health_containers + ['xilriws']:
                try:
                    container = docker_client.containers.get(container_name)
                    
                    current_state = {
                        'status': container.status,
                        'restart_count': container.attrs.get('RestartCount', 0),
                        'started_at': container.attrs['State'].get('StartedAt'),
                        'health': container.attrs['State'].get('Health', {}).get('Status')
                    }
                    
                    # Check for state changes
                    prev_state = last_states.get(container_name, {})
                    
                    # Detect restart
                    if current_state['restart_count'] > prev_state.get('restart_count', 0):
                        self._emit_event({
                            'type': 'container_restart',
                            'container': container_name,
                            'restart_count': current_state['restart_count'],
                            'severity': 'warning'
                        })
                    
                    # Detect status change
                    if current_state['status'] != prev_state.get('status'):
                        severity = 'success' if current_state['status'] == 'running' else 'error'
                        self._emit_event({
                            'type': 'container_status_change',
                            'container': container_name,
                            'old_status': prev_state.get('status', 'unknown'),
                            'new_status': current_state['status'],
                            'severity': severity
                        })
                    
                    # Detect unhealthy
                    if current_state.get('health') == 'unhealthy':
                        self._emit_event({
                            'type': 'container_unhealthy',
                            'container': container_name,
                            'severity': 'error'
                        })
                    
                    # Update container stats
                    try:
                        stats = container.stats(stream=False)
                        cpu_percent = self._calculate_cpu_percent(stats)
                        mem_usage = stats.get('memory_stats', {}).get('usage', 0)
                        mem_limit = stats.get('memory_stats', {}).get('limit', 1)
                        mem_percent = (mem_usage / mem_limit) * 100 if mem_limit else 0
                        
                        current_state['cpu_percent'] = round(cpu_percent, 1)
                        current_state['memory_mb'] = round(mem_usage / (1024 * 1024), 1)
                        current_state['memory_percent'] = round(mem_percent, 1)
                        
                        # Alert on high resource usage
                        if mem_percent > 90:
                            self._emit_event({
                                'type': 'high_memory',
                                'container': container_name,
                                'memory_percent': current_state['memory_percent'],
                                'severity': 'warning'
                            })
                    except:
                        pass
                    
                    last_states[container_name] = current_state
                    
                    with self.lock:
                        self.container_states[container_name] = current_state
                    
                except docker.errors.NotFound:
                    if container_name in last_states:
                        self._emit_event({
                            'type': 'container_removed',
                            'container': container_name,
                            'severity': 'error'
                        })
                        del last_states[container_name]
                except Exception as e:
                    print(f"[DeviceMonitor] Error checking {container_name}: {e}")
            
            time.sleep(30)  # Increased from 10s to 30s for CPU optimization
    
    def _poll_database_devices(self):
        """Poll the Dragonite database for device status - cross-reference with logs"""
        while self.running:
            try:
                # Get device status from Dragonite database via StackDB
                if hasattr(self, 'device_manager') and self.device_manager:
                    stack_db = getattr(self.device_manager, 'stack_db', None)
                    if stack_db:
                        db_devices = stack_db.get_device_status()
                        
                        if db_devices:
                            for db_dev in db_devices:
                                device_name = db_dev.get('uuid', db_dev.get('device_id', 'unknown'))
                                
                                with self.lock:
                                    if device_name not in self.devices:
                                        self.devices[device_name] = {
                                            'name': device_name,
                                            'status': 'unknown',
                                            'source': 'database',
                                            'events': [],
                                            'errors': 0,
                                            'last_seen': None
                                        }
                                    
                                    # Update from database
                                    dev = self.devices[device_name]
                                    dev['db_instance'] = db_dev.get('instance_name')
                                    dev['db_host'] = db_dev.get('host')
                                    dev['db_last_seen'] = db_dev.get('last_seen')
                                    dev['db_account'] = db_dev.get('account_username')
                                    dev['db_lat'] = db_dev.get('lat')
                                    dev['db_lon'] = db_dev.get('lon')
                                    dev['db_online'] = db_dev.get('online', False)
                                    
                                    # Cross-reference: If DB says offline but we have no disconnect event
                                    if not dev['db_online'] and dev.get('status') == 'connected':
                                        # Database knows something we don't - device went offline
                                        self._emit_event({
                                            'type': 'device_offline_detected',
                                            'device': device_name,
                                            'source': 'database',
                                            'severity': 'warning',
                                            'message': 'Database shows device offline - possible silent disconnect'
                                        })
                                        dev['status'] = 'offline'
                                    
                                    # Update last seen from DB
                                    if db_dev.get('last_seen'):
                                        dev['last_seen'] = db_dev.get('last_seen')
                            
                            # Check for devices in logs but not in database
                            self._check_orphan_devices()
            
            except Exception as e:
                print(f"[DeviceMonitor] Database poll error: {e}")
            
            time.sleep(30)  # Poll every 30 seconds
    
    def _check_orphan_devices(self):
        """Check for devices seen in logs but not in database"""
        with self.lock:
            for device_name, dev in self.devices.items():
                if dev.get('source') == 'rotom' and not dev.get('db_instance'):
                    # Device connected to Rotom but not in Dragonite DB
                    if not dev.get('orphan_warned'):
                        dev['orphan_warned'] = True
                        self._emit_event({
                            'type': 'device_orphan',
                            'device': device_name,
                            'severity': 'warning',
                            'message': 'Device connected to Rotom but not registered in Dragonite'
                        })
    
    def get_port_7070_connections(self):
        """
        Monitor active connections to port 7070 (device WebSocket port).
        Uses Docker exec to run netstat inside the Rotom container.
        Returns list of connected IPs and connection states.
        """
        connections = []
        
        if not docker_client:
            return {'error': 'Docker not available', 'connections': []}
        
        try:
            container = docker_client.containers.get('rotom')
            if container.status != 'running':
                return {'error': 'Rotom not running', 'connections': []}
            
            # Run netstat inside the container to see connections on port 7070
            # Try different approaches since not all containers have netstat
            result = None
            
            # Try ss (modern replacement for netstat)
            try:
                result = container.exec_run(
                    "ss -tn state established '( sport = :7070 )'",
                    demux=True
                )
                if result.exit_code == 0 and result.output[0]:
                    output = result.output[0].decode('utf-8', errors='ignore')
                    for line in output.strip().split('\n')[1:]:  # Skip header
                        parts = line.split()
                        if len(parts) >= 5:
                            remote = parts[4]  # Remote address:port
                            if ':' in remote:
                                ip = remote.rsplit(':', 1)[0]
                                connections.append({
                                    'remote_ip': ip,
                                    'state': 'ESTABLISHED',
                                    'local_port': 7070
                                })
            except:
                pass
            
            # If ss didn't work, try /proc/net/tcp
            if not connections:
                try:
                    result = container.exec_run("cat /proc/net/tcp", demux=True)
                    if result.exit_code == 0 and result.output[0]:
                        output = result.output[0].decode('utf-8', errors='ignore')
                        # Parse /proc/net/tcp format
                        # Port 7070 in hex = 1B9E
                        for line in output.strip().split('\n')[1:]:
                            parts = line.split()
                            if len(parts) >= 3:
                                local = parts[1]
                                remote = parts[2]
                                state = parts[3]
                                
                                # Check if local port is 7070 (0x1B9E)
                                if ':1B9E' in local.upper():
                                    # Parse remote IP
                                    if ':' in remote:
                                        hex_ip, hex_port = remote.split(':')
                                        # Convert hex IP to dotted decimal (little endian)
                                        try:
                                            ip_int = int(hex_ip, 16)
                                            ip = f"{ip_int & 0xFF}.{(ip_int >> 8) & 0xFF}.{(ip_int >> 16) & 0xFF}.{(ip_int >> 24) & 0xFF}"
                                            port = int(hex_port, 16)
                                            
                                            state_map = {
                                                '01': 'ESTABLISHED',
                                                '02': 'SYN_SENT',
                                                '03': 'SYN_RECV',
                                                '04': 'FIN_WAIT1',
                                                '05': 'FIN_WAIT2',
                                                '06': 'TIME_WAIT',
                                                '07': 'CLOSE',
                                                '08': 'CLOSE_WAIT',
                                                '09': 'LAST_ACK',
                                                '0A': 'LISTEN'
                                            }
                                            
                                            connections.append({
                                                'remote_ip': ip,
                                                'remote_port': port,
                                                'state': state_map.get(state, state),
                                                'local_port': 7070
                                            })
                                        except:
                                            pass
                except:
                    pass
            
            # Get connection count and unique IPs
            unique_ips = set(c['remote_ip'] for c in connections)
            established = [c for c in connections if c.get('state') == 'ESTABLISHED']
            
            return {
                'port': 7070,
                'total_connections': len(connections),
                'established': len(established),
                'unique_devices': len(unique_ips),
                'connections': connections,
                'timestamp': datetime.now().isoformat()
            }
            
        except docker.errors.NotFound:
            return {'error': 'Rotom container not found', 'connections': []}
        except Exception as e:
            return {'error': str(e), 'connections': []}
    
    def get_rotom_device_traffic(self, lines=100):
        """
        Get recent device traffic from Rotom logs.
        Parses and returns structured device communication events.
        
        Real log format examples:
        - [2025-12-01T09:09:26.082Z] [INFO] [rotom] CONTROLLER: Found OrangePi5 connects to workerId OrangePi5-1
        - [2025-12-01T09:09:25.759Z] [INFO] [rotom] OrangePi5-1/1041: Disconnected; performing disconnection activities
        - [2025-12-01T09:35:57.485Z] [INFO] [rotom] OrangePi5-1/1044: Received id packet origin PokemodAegis-OrangePi5 - version 25112701
        - [2025-12-01T09:00:23.507Z] [INFO] [rotom] OrangePi5/572:Memory = {"memFree":13042488,"memMitm":639244,"memStart":510180}
        """
        traffic = []
        
        if not docker_client:
            return {'error': 'Docker not available', 'traffic': []}
        
        try:
            container = docker_client.containers.get('rotom')
            if container.status != 'running':
                return {'error': 'Rotom not running', 'traffic': []}
            
            logs = container.logs(tail=lines, timestamps=True).decode('utf-8', errors='ignore')
            
            # Parse device-related log entries (matching real Rotom format)
            device_patterns = {
                # Device connected to worker
                'connect': re.compile(r'\[([^\]]+)\].*CONTROLLER:\s*Found\s+(\S+)\s+connects\s+to\s+workerId\s+(\S+)'),
                # Worker allocation
                'allocate': re.compile(r'\[([^\]]+)\].*CONTROLLER:\s*New connection from\s+(\S+)\s*-\s*will allocate\s+(\S+)'),
                # Worker disconnect from controller
                'worker_disconnect': re.compile(r'\[([^\]]+)\].*CONTROLLER:\s*Disconnected worker\s+(\S+)/(\S+)/(\d+)'),
                # Device disconnect
                'disconnect': re.compile(r'\[([^\]]+)\].*(\S+)/(\d+):\s*Disconnected.*disconnection activities'),
                # New connection from device IP
                'new_connection': re.compile(r'\[([^\]]+)\].*Device:\s*New connection from\s+(\S+)'),
                # ID packet with version
                'id_packet': re.compile(r'\[([^\]]+)\].*(\S+)/(\d+):\s*Received id packet origin\s+(\S+)\s*-\s*version\s+(\d+)'),
                # Memory report
                'memory': re.compile(r'\[([^\]]+)\].*(\S+)/(\d+):Memory\s*=\s*(\{[^}]+\})'),
                # Unallocated connections
                'unallocated': re.compile(r'\[([^\]]+)\].*(\S+):\s*unallocated connections\s*=\s*(.*)'),
            }
            
            for line in logs.split('\n'):
                for event_type, pattern in device_patterns.items():
                    match = pattern.search(line)
                    if match:
                        groups = match.groups()
                        entry = {
                            'type': event_type,
                            'timestamp': groups[0] if groups else None,
                            'raw': line[:300]
                        }
                        
                        if event_type == 'connect':
                            entry['device'] = groups[1] if len(groups) > 1 else None
                            entry['worker'] = groups[2] if len(groups) > 2 else None
                        elif event_type == 'allocate':
                            entry['source_ip'] = groups[1] if len(groups) > 1 else None
                            entry['worker'] = groups[2] if len(groups) > 2 else None
                        elif event_type == 'worker_disconnect':
                            entry['instance'] = groups[1] if len(groups) > 1 else None
                            entry['session'] = groups[2] if len(groups) > 2 else None
                            entry['connection_id'] = groups[3] if len(groups) > 3 else None
                        elif event_type == 'disconnect':
                            entry['device'] = groups[1] if len(groups) > 1 else None
                            entry['connection_id'] = groups[2] if len(groups) > 2 else None
                        elif event_type == 'new_connection':
                            entry['device_ip'] = groups[1] if len(groups) > 1 else None
                        elif event_type == 'id_packet':
                            entry['device'] = groups[1] if len(groups) > 1 else None
                            entry['connection_id'] = groups[2] if len(groups) > 2 else None
                            entry['origin'] = groups[3] if len(groups) > 3 else None
                            entry['version'] = groups[4] if len(groups) > 4 else None
                        elif event_type == 'memory':
                            entry['device'] = groups[1] if len(groups) > 1 else None
                            entry['connection_id'] = groups[2] if len(groups) > 2 else None
                            try:
                                mem_data = json.loads(groups[3]) if len(groups) > 3 else {}
                                entry['memory'] = {
                                    'free_mb': round(mem_data.get('memFree', 0) / 1024, 1),
                                    'mitm_mb': round(mem_data.get('memMitm', 0) / 1024, 1),
                                    'start_kb': mem_data.get('memStart', 0)
                                }
                            except:
                                pass
                        elif event_type == 'unallocated':
                            entry['device'] = groups[1] if len(groups) > 1 else None
                            entry['unallocated'] = groups[2].strip() if len(groups) > 2 else ''
                        
                        traffic.append(entry)
                        break  # Only match first pattern per line
            
            # Summarize
            devices_seen = set(t['device'] for t in traffic if t.get('device'))
            connects = len([t for t in traffic if t['type'] == 'connect'])
            disconnects = len([t for t in traffic if t['type'] == 'disconnect'])
            errors = len([t for t in traffic if t['type'] == 'error'])
            
            return {
                'summary': {
                    'devices_seen': len(devices_seen),
                    'device_names': list(devices_seen)[:20],
                    'connects': connects,
                    'disconnects': disconnects,
                    'errors': errors,
                    'total_events': len(traffic)
                },
                'traffic': traffic[-50:],  # Last 50 events
                'timestamp': datetime.now().isoformat()
            }
            
        except Exception as e:
            return {'error': str(e), 'traffic': []}
    
    def _calculate_cpu_percent(self, stats):
        """Calculate CPU percentage from Docker stats"""
        try:
            cpu_delta = stats['cpu_stats']['cpu_usage']['total_usage'] - \
                       stats['precpu_stats']['cpu_usage']['total_usage']
            system_delta = stats['cpu_stats']['system_cpu_usage'] - \
                          stats['precpu_stats']['system_cpu_usage']
            
            if system_delta > 0 and cpu_delta > 0:
                cpu_count = len(stats['cpu_stats']['cpu_usage'].get('percpu_usage', [1]))
                return (cpu_delta / system_delta) * cpu_count * 100
        except:
            pass
        return 0.0
    
    def _update_container_state(self, name, container):
        """Update container state tracking"""
        with self.lock:
            self.container_states[name] = {
                'status': container.status,
                'id': container.short_id,
                'updated': datetime.now().isoformat()
            }
    
    def _emit_event(self, event):
        """Emit event via WebSocket"""
        event['created_at'] = datetime.now().isoformat()
        
        if socketio and SOCKETIO_AVAILABLE:
            try:
                socketio.emit('device_activity', event)
            except:
                pass
    
    def get_activity_feed(self, limit=50, device=None, severity=None):
        """Get recent activity feed with optional filters"""
        with self.lock:
            feed = self.activity_feed.copy()
        
        if device:
            feed = [e for e in feed if e.get('device') == device]
        if severity:
            feed = [e for e in feed if e.get('severity') == severity]
        
        return feed[:limit]
    
    def get_device_states(self):
        """Get current state of all devices"""
        with self.lock:
            return dict(self.device_states)
    
    def get_container_states(self):
        """Get current state of all monitored containers"""
        with self.lock:
            return dict(self.container_states)
    
    def get_live_summary(self):
        """Get a live summary of the device workflow monitoring"""
        with self.lock:
            # Device stats
            online_devices = sum(
                1 for d in self.devices.values()
                if d.get('status') == 'connected'
            )
            total_errors = sum(
                d.get('errors', 0) for d in self.devices.values()
            )
            total_tasks = sum(
                d.get('tasks_assigned', 0) for d in self.devices.values()
            )
            completed_tasks = sum(
                d.get('tasks_completed', 0) for d in self.devices.values()
            )
            
            # Container health
            running_containers = sum(
                1 for c in self.container_states.values()
                if c.get('status') == 'running'
            )
            
            # Rotom/Dragonite specific
            rotom_ok = self.container_states.get('rotom', {}).get('status') == 'running'
            dragonite_ok = self.container_states.get('dragonite', {}).get('status') == 'running'
            
            # Recent disconnects pending correlation
            pending_disconnects = len(self.recent_disconnects)
            
            return {
                'workflow': {
                    'rotom_status': 'running' if rotom_ok else 'down',
                    'dragonite_status': 'running' if dragonite_ok else 'down',
                    'pipeline_healthy': rotom_ok and dragonite_ok
                },
                'devices': {
                    'total': len(self.devices),
                    'online': online_devices,
                    'offline': len(self.devices) - online_devices,
                    'with_errors': sum(1 for d in self.devices.values() if d.get('errors', 0) > 0)
                },
                'tasks': {
                    'assigned': total_tasks,
                    'completed': completed_tasks,
                    'completion_rate': f"{(completed_tasks/total_tasks*100):.1f}%" if total_tasks > 0 else "N/A"
                },
                'workers': {
                    'mapped': len(self.workers),
                    'worker_list': list(self.workers.keys())[:10]  # First 10
                },
                'containers': {
                    'monitored': len(self.monitored_containers),
                    'running': running_containers,
                    'states': self.container_states.copy()
                },
                'correlation': {
                    'pending_disconnects': pending_disconnects,
                    'window_seconds': self.correlation_window
                },
                'activity': {
                    'total_events': len(self.activity_feed),
                    'total_errors': total_errors,
                    'recent': self.activity_feed[:10]
                },
                'timestamp': datetime.now().isoformat()
            }

# Device monitor instance (initialized after other components)
device_monitor = None

# =============================================================================
# SQLITE DATABASE ACCESS (Shellder's own database for persistence)
# =============================================================================

class ShellderDB:
    """Access to Shellder's SQLite database for historical stats"""
    
    def __init__(self, db_path):
        self.db_path = db_path
    
    def _connect(self):
        """Create a new connection for thread safety"""
        if not self.db_path.exists():
            return None
        return sqlite3.connect(str(self.db_path), timeout=10)
    
    def get_proxy_stats(self, limit=50):
        """Get proxy statistics"""
        conn = self._connect()
        if not conn:
            return []
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT proxy_address, requests_total, requests_success, 
                       requests_failed, avg_response_time_ms, last_seen
                FROM proxy_stats 
                ORDER BY last_seen DESC 
                LIMIT ?
            """, (limit,))
            rows = cursor.fetchall()
            return [
                {
                    'proxy': row[0],
                    'total': row[1],
                    'success': row[2],
                    'failed': row[3],
                    'avg_response_ms': row[4],
                    'last_seen': row[5]
                }
                for row in rows
            ]
        except Exception as e:
            print(f"Error getting proxy stats: {e}")
            return []
        finally:
            conn.close()
    
    def get_error_stats(self, service=None, limit=100):
        """Get error statistics"""
        conn = self._connect()
        if not conn:
            return []
        try:
            cursor = conn.cursor()
            if service:
                cursor.execute("""
                    SELECT service_name, error_type, error_message, 
                           occurrence_count, first_seen, last_seen
                    FROM error_stats 
                    WHERE service_name = ?
                    ORDER BY last_seen DESC 
                    LIMIT ?
                """, (service, limit))
            else:
                cursor.execute("""
                    SELECT service_name, error_type, error_message, 
                           occurrence_count, first_seen, last_seen
                    FROM error_stats 
                    ORDER BY last_seen DESC 
                    LIMIT ?
                """, (limit,))
            rows = cursor.fetchall()
            return [
                {
                    'service': row[0],
                    'type': row[1],
                    'message': row[2],
                    'count': row[3],
                    'first_seen': row[4],
                    'last_seen': row[5]
                }
                for row in rows
            ]
        except Exception as e:
            print(f"Error getting error stats: {e}")
            return []
        finally:
            conn.close()
    
    def get_container_stats(self):
        """Get container historical statistics"""
        conn = self._connect()
        if not conn:
            return []
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT container_name, start_count, restart_count, 
                       crash_count, total_uptime_seconds, last_status
                FROM container_stats 
                ORDER BY container_name
            """)
            rows = cursor.fetchall()
            return [
                {
                    'name': row[0],
                    'starts': row[1],
                    'restarts': row[2],
                    'crashes': row[3],
                    'uptime_seconds': row[4],
                    'last_status': row[5]
                }
                for row in rows
            ]
        except Exception as e:
            print(f"Error getting container stats: {e}")
            return []
        finally:
            conn.close()
    
    def get_log_summaries(self, days=7):
        """Get log summaries for past N days"""
        conn = self._connect()
        if not conn:
            return []
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT log_date, service_name, total_lines, 
                       error_count, warning_count
                FROM log_summaries 
                WHERE log_date >= date('now', ?)
                ORDER BY log_date DESC, service_name
            """, (f'-{days} days',))
            rows = cursor.fetchall()
            return [
                {
                    'date': row[0],
                    'service': row[1],
                    'lines': row[2],
                    'errors': row[3],
                    'warnings': row[4]
                }
                for row in rows
            ]
        except Exception as e:
            print(f"Error getting log summaries: {e}")
            return []
        finally:
            conn.close()
    
    def get_config_discrepancies(self):
        """Get unresolved config discrepancies"""
        conn = self._connect()
        if not conn:
            return []
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT config_key, expected_value, found_value, 
                       source_file, detected_at
                FROM config_discrepancies 
                WHERE resolved = 0
                ORDER BY detected_at DESC
            """)
            rows = cursor.fetchall()
            return [
                {
                    'key': row[0],
                    'expected': row[1][:20] + '...' if len(row[1] or '') > 20 else row[1],
                    'found': row[2][:20] + '...' if len(row[2] or '') > 20 else row[2],
                    'file': row[3],
                    'detected': row[4]
                }
                for row in rows
            ]
        except Exception as e:
            print(f"Error getting config discrepancies: {e}")
            return []
        finally:
            conn.close()
    
    def get_system_events(self, limit=50):
        """Get recent system events"""
        conn = self._connect()
        if not conn:
            return []
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT event_type, event_source, event_message, created_at
                FROM system_events 
                ORDER BY created_at DESC 
                LIMIT ?
            """, (limit,))
            rows = cursor.fetchall()
            return [
                {
                    'type': row[0],
                    'source': row[1],
                    'message': row[2],
                    'time': row[3]
                }
                for row in rows
            ]
        except Exception as e:
            print(f"Error getting system events: {e}")
            return []
        finally:
            conn.close()
    
    # =========================================================================
    # CROSS-REFERENCE & PERSISTENCE METHODS
    # =========================================================================
    
    def ensure_service_tables(self):
        """Create tables for service statistics if they don't exist"""
        conn = self._connect()
        if not conn:
            # Create the database if it doesn't exist
            try:
                conn = sqlite3.connect(str(self.db_path), timeout=10)
            except Exception as e:
                print(f"Cannot create database: {e}")
                return False
        
        try:
            cursor = conn.cursor()
            
            # Rotom device stats - Enhanced for comprehensive tracking
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS rotom_devices (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    device_name TEXT NOT NULL,
                    worker_id TEXT,
                    origin TEXT,
                    version TEXT,
                    last_memory_free INTEGER,
                    last_memory_mitm INTEGER,
                    total_connections INTEGER DEFAULT 0,
                    total_disconnections INTEGER DEFAULT 0,
                    total_crashes INTEGER DEFAULT 0,
                    total_errors INTEGER DEFAULT 0,
                    total_uptime_seconds INTEGER DEFAULT 0,
                    last_connect_time DATETIME,
                    last_disconnect_time DATETIME,
                    current_session_start DATETIME,
                    is_online INTEGER DEFAULT 0,
                    first_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
                    last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(device_name)
                )
            """)
            
            # Rotom connection events - Enhanced
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS rotom_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_type TEXT NOT NULL,
                    device_name TEXT,
                    worker_id TEXT,
                    ip_address TEXT,
                    details TEXT,
                    log_source TEXT,
                    log_line_number INTEGER,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
            # Device crash/error tracking with log references
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS device_crashes (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    device_name TEXT NOT NULL,
                    crash_type TEXT NOT NULL,
                    error_message TEXT,
                    log_source TEXT NOT NULL,
                    log_line_start INTEGER,
                    log_line_end INTEGER,
                    log_context TEXT,
                    related_crash_id INTEGER,
                    is_during_startup INTEGER DEFAULT 0,
                    resolved INTEGER DEFAULT 0,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    FOREIGN KEY (related_crash_id) REFERENCES device_crashes(id)
                )
            """)
            
            # Device uptime sessions
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS device_sessions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    device_name TEXT NOT NULL,
                    session_start DATETIME NOT NULL,
                    session_end DATETIME,
                    duration_seconds INTEGER,
                    end_reason TEXT,
                    crash_id INTEGER,
                    FOREIGN KEY (crash_id) REFERENCES device_crashes(id)
                )
            """)
            
            # Koji API stats
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS koji_stats (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    endpoint TEXT NOT NULL,
                    method TEXT,
                    status_code INTEGER,
                    response_time_ms REAL,
                    client_ip TEXT,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
            # Koji daily aggregates
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS koji_daily (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    stat_date DATE NOT NULL,
                    total_requests INTEGER DEFAULT 0,
                    geofence_requests INTEGER DEFAULT 0,
                    health_checks INTEGER DEFAULT 0,
                    errors INTEGER DEFAULT 0,
                    avg_response_time_ms REAL,
                    UNIQUE(stat_date)
                )
            """)
            
            # Database connection stats
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS db_connection_stats (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    db_name TEXT NOT NULL,
                    user_name TEXT,
                    host TEXT,
                    total_connections INTEGER DEFAULT 0,
                    aborted_connections INTEGER DEFAULT 0,
                    first_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
                    last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(db_name, user_name, host)
                )
            """)
            
            # Database events
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS db_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_type TEXT NOT NULL,
                    db_name TEXT,
                    user_name TEXT,
                    host TEXT,
                    message TEXT,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
            # Xilriws proxy stats (enhanced)
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS xilriws_proxy_stats (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    proxy_address TEXT NOT NULL,
                    total_requests INTEGER DEFAULT 0,
                    successful INTEGER DEFAULT 0,
                    failed INTEGER DEFAULT 0,
                    timeouts INTEGER DEFAULT 0,
                    unreachable INTEGER DEFAULT 0,
                    bot_blocked INTEGER DEFAULT 0,
                    success_rate REAL,
                    first_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
                    last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(proxy_address)
                )
            """)
            
            # Xilriws daily aggregates
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS xilriws_daily (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    stat_date DATE NOT NULL,
                    total_requests INTEGER DEFAULT 0,
                    successful INTEGER DEFAULT 0,
                    failed INTEGER DEFAULT 0,
                    auth_banned INTEGER DEFAULT 0,
                    code_15 INTEGER DEFAULT 0,
                    tunnel_failed INTEGER DEFAULT 0,
                    timeouts INTEGER DEFAULT 0,
                    success_rate REAL,
                    UNIQUE(stat_date)
                )
            """)
            
            # Service health snapshots
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS service_health (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    service_name TEXT NOT NULL,
                    status TEXT,
                    details TEXT,
                    recorded_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
            # System metrics history - for dashboard sparklines and detailed charts
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS metrics_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    metric_name TEXT NOT NULL,
                    metric_value REAL NOT NULL,
                    recorded_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
            """)
            
            # Create index for fast queries
            cursor.execute("""
                CREATE INDEX IF NOT EXISTS idx_metrics_name_time 
                ON metrics_history(metric_name, recorded_at DESC)
            """)
            
            conn.commit()
            return True
        except Exception as e:
            print(f"Error creating service tables: {e}")
            return False
        finally:
            conn.close()
    
    def record_metric(self, metric_name, metric_value):
        """Record a single metric value to history"""
        conn = self._connect()
        if not conn:
            return
        
        try:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO metrics_history (metric_name, metric_value)
                VALUES (?, ?)
            """, (metric_name, metric_value))
            conn.commit()
        except Exception as e:
            print(f"Error recording metric: {e}")
        finally:
            conn.close()
    
    def record_metrics_batch(self, metrics):
        """Record multiple metrics at once: {name: value, ...}"""
        conn = self._connect()
        if not conn:
            print(f"[METRICS DB] Cannot connect to database at {self.db_path}")
            return False
        
        try:
            cursor = conn.cursor()
            recorded = 0
            for name, value in metrics.items():
                if value is not None:
                    cursor.execute("""
                        INSERT INTO metrics_history (metric_name, metric_value)
                        VALUES (?, ?)
                    """, (name, float(value)))
                    recorded += 1
            conn.commit()
            return recorded > 0
        except Exception as e:
            print(f"[METRICS DB] Error recording metrics batch: {e}")
            return False
        finally:
            conn.close()
    
    def get_metric_history(self, metric_name, hours=24, limit=500):
        """Get historical values for a metric"""
        conn = self._connect()
        if not conn:
            return []
        
        try:
            cursor = conn.cursor()
            # Convert to minutes for better SQLite compatibility with fractional values
            # Use round() to avoid truncation (0.0833 * 60 = 4.998, should be 5 not 4)
            minutes = round(hours * 60)
            # Use subquery to get NEWEST records (not oldest) within time range
            # Inner query: get newest {limit} records ordered DESC
            # Outer query: re-order ASC for chart display (oldest to newest)
            cursor.execute("""
                SELECT metric_value, recorded_at FROM (
                    SELECT metric_value, recorded_at
                    FROM metrics_history
                    WHERE metric_name = ?
                      AND recorded_at >= datetime('now', ?)
                    ORDER BY recorded_at DESC
                    LIMIT ?
                ) ORDER BY recorded_at ASC
            """, (metric_name, f'-{minutes} minutes', limit))
            
            # Return times in ISO 8601 format with Z suffix (UTC)
            return [{'value': row[0], 'time': row[1].replace(' ', 'T') + 'Z'} for row in cursor.fetchall()]
        except Exception as e:
            print(f"Error getting metric history: {e}")
            return []
        finally:
            conn.close()
    
    def get_metric_sparkline(self, metric_name, points=20):
        """Get recent values for sparkline display (last ~2 hours)"""
        conn = self._connect()
        if not conn:
            return []
        
        try:
            cursor = conn.cursor()
            # Get recent metrics, spaced out for sparkline
            cursor.execute("""
                SELECT metric_value
                FROM metrics_history
                WHERE metric_name = ?
                ORDER BY recorded_at DESC
                LIMIT ?
            """, (metric_name, points * 3))  # Get more, then downsample
            
            values = [row[0] for row in cursor.fetchall()]
            values.reverse()  # Oldest first
            
            # Downsample if we have too many points
            if len(values) > points:
                step = len(values) // points
                values = values[::step][:points]
            
            return values
        except Exception as e:
            print(f"Error getting sparkline: {e}")
            return []
        finally:
            conn.close()
    
    def cleanup_old_metrics(self, days=7):
        """Remove metrics older than specified days"""
        conn = self._connect()
        if not conn:
            return
        
        try:
            cursor = conn.cursor()
            cursor.execute("""
                DELETE FROM metrics_history
                WHERE recorded_at < datetime('now', ?)
            """, (f'-{days} days',))
            deleted = cursor.rowcount
            conn.commit()
            if deleted > 0:
                print(f"Cleaned up {deleted} old metric records")
        except Exception as e:
            print(f"Error cleaning up metrics: {e}")
        finally:
            conn.close()
    
    def persist_rotom_stats(self, stats):
        """Save Rotom stats to database"""
        conn = self._connect()
        if not conn:
            return
        
        try:
            cursor = conn.cursor()
            
            # Update device records
            for device_name, device_info in stats.get('devices', {}).items():
                cursor.execute("""
                    INSERT INTO rotom_devices (device_name, worker_id, origin, version, 
                                               last_memory_free, last_memory_mitm, last_seen)
                    VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                    ON CONFLICT(device_name) DO UPDATE SET
                        worker_id = COALESCE(excluded.worker_id, worker_id),
                        origin = COALESCE(excluded.origin, origin),
                        version = COALESCE(excluded.version, version),
                        last_memory_free = COALESCE(excluded.last_memory_free, last_memory_free),
                        last_memory_mitm = COALESCE(excluded.last_memory_mitm, last_memory_mitm),
                        last_seen = CURRENT_TIMESTAMP
                """, (
                    device_name,
                    device_info.get('worker_id'),
                    device_info.get('origin'),
                    device_info.get('version'),
                    device_info.get('memory', {}).get('memFree'),
                    device_info.get('memory', {}).get('memMitm')
                ))
            
            conn.commit()
        except Exception as e:
            print(f"Error persisting Rotom stats: {e}")
        finally:
            conn.close()
    
    def persist_xilriws_stats(self, stats):
        """Save Xilriws stats to database"""
        conn = self._connect()
        if not conn:
            return
        
        try:
            cursor = conn.cursor()
            today = datetime.now().strftime('%Y-%m-%d')
            
            # Update daily aggregates
            cursor.execute("""
                INSERT INTO xilriws_daily (stat_date, total_requests, successful, failed,
                                           auth_banned, code_15, tunnel_failed, timeouts, success_rate)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(stat_date) DO UPDATE SET
                    total_requests = excluded.total_requests,
                    successful = excluded.successful,
                    failed = excluded.failed,
                    auth_banned = excluded.auth_banned,
                    code_15 = excluded.code_15,
                    tunnel_failed = excluded.tunnel_failed,
                    timeouts = excluded.timeouts,
                    success_rate = excluded.success_rate
            """, (
                today,
                stats.get('total_requests', 0),
                stats.get('successful', 0),
                stats.get('failed', 0),
                stats.get('auth_banned', 0),
                stats.get('browser_bot_protection', 0),
                stats.get('ptc_tunnel_failed', 0),
                stats.get('ptc_connection_timeout', 0),
                stats.get('success_rate', 0)
            ))
            
            # Update per-proxy stats
            for proxy_addr, proxy_data in stats.get('proxy_stats', {}).items():
                cursor.execute("""
                    INSERT INTO xilriws_proxy_stats (proxy_address, total_requests, successful, 
                                                     failed, timeouts, unreachable, bot_blocked, 
                                                     success_rate, last_seen)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                    ON CONFLICT(proxy_address) DO UPDATE SET
                        total_requests = total_requests + excluded.total_requests,
                        successful = successful + excluded.successful,
                        failed = failed + excluded.failed,
                        timeouts = timeouts + excluded.timeouts,
                        unreachable = unreachable + excluded.unreachable,
                        bot_blocked = bot_blocked + excluded.bot_blocked,
                        success_rate = excluded.success_rate,
                        last_seen = CURRENT_TIMESTAMP
                """, (
                    proxy_addr,
                    proxy_data.get('requests', 0),
                    proxy_data.get('success', 0),
                    proxy_data.get('fail', 0),
                    proxy_data.get('timeout', 0),
                    proxy_data.get('unreachable', 0),
                    proxy_data.get('bot_blocked', 0),
                    proxy_data.get('success_rate', 0)
                ))
            
            conn.commit()
        except Exception as e:
            print(f"Error persisting Xilriws stats: {e}")
        finally:
            conn.close()
    
    def persist_koji_stats(self, stats):
        """Save Koji stats to database"""
        conn = self._connect()
        if not conn:
            return
        
        try:
            cursor = conn.cursor()
            today = datetime.now().strftime('%Y-%m-%d')
            
            # Update daily aggregates
            cursor.execute("""
                INSERT INTO koji_daily (stat_date, total_requests, geofence_requests, 
                                        health_checks, errors, avg_response_time_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(stat_date) DO UPDATE SET
                    total_requests = excluded.total_requests,
                    geofence_requests = excluded.geofence_requests,
                    health_checks = excluded.health_checks,
                    errors = excluded.errors,
                    avg_response_time_ms = excluded.avg_response_time_ms
            """, (
                today,
                stats.get('requests', 0),
                stats.get('geofence_requests', 0),
                stats.get('health_checks', 0),
                stats.get('errors', 0),
                stats.get('avg_response_time_ms', 0)
            ))
            
            conn.commit()
        except Exception as e:
            print(f"Error persisting Koji stats: {e}")
        finally:
            conn.close()
    
    def persist_database_stats(self, stats):
        """Save MariaDB connection stats to database"""
        conn = self._connect()
        if not conn:
            return
        
        try:
            cursor = conn.cursor()
            
            # Update connection stats per db/user/host
            for db_name, db_info in stats.get('connections', {}).get('by_db', {}).items():
                for user_name, user_info in stats.get('connections', {}).get('by_user', {}).items():
                    for host, host_info in stats.get('connections', {}).get('by_host', {}).items():
                        cursor.execute("""
                            INSERT INTO db_connection_stats (db_name, user_name, host, 
                                                             aborted_connections, last_seen)
                            VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
                            ON CONFLICT(db_name, user_name, host) DO UPDATE SET
                                aborted_connections = aborted_connections + excluded.aborted_connections,
                                last_seen = CURRENT_TIMESTAMP
                        """, (
                            db_name,
                            user_name,
                            host,
                            db_info.get('aborted', 0)
                        ))
            
            conn.commit()
        except Exception as e:
            print(f"Error persisting Database stats: {e}")
        finally:
            conn.close()
    
    def record_service_health(self, service_name, status, details=None):
        """Record a service health snapshot"""
        conn = self._connect()
        if not conn:
            return
        
        try:
            cursor = conn.cursor()
            cursor.execute("""
                INSERT INTO service_health (service_name, status, details)
                VALUES (?, ?, ?)
            """, (service_name, status, json.dumps(details) if details else None))
            conn.commit()
        except Exception as e:
            print(f"Error recording service health: {e}")
        finally:
            conn.close()
    
    # =========================================================================
    # CROSS-REFERENCE QUERY METHODS
    # =========================================================================
    
    def get_rotom_devices_history(self, limit=50):
        """Get historical Rotom device data"""
        conn = self._connect()
        if not conn:
            return []
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT device_name, worker_id, origin, version, 
                       last_memory_free, last_memory_mitm,
                       total_connections, total_disconnections,
                       first_seen, last_seen
                FROM rotom_devices 
                ORDER BY last_seen DESC 
                LIMIT ?
            """, (limit,))
            rows = cursor.fetchall()
            return [
                {
                    'device': row[0],
                    'worker_id': row[1],
                    'origin': row[2],
                    'version': row[3],
                    'memory_free': row[4],
                    'memory_mitm': row[5],
                    'connections': row[6],
                    'disconnections': row[7],
                    'first_seen': row[8],
                    'last_seen': row[9]
                }
                for row in rows
            ]
        except Exception as e:
            print(f"Error getting Rotom device history: {e}")
            return []
        finally:
            conn.close()
    
    def get_xilriws_daily_stats(self, days=30):
        """Get Xilriws daily statistics for trending"""
        conn = self._connect()
        if not conn:
            return []
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT stat_date, total_requests, successful, failed,
                       auth_banned, code_15, tunnel_failed, timeouts, success_rate
                FROM xilriws_daily 
                WHERE stat_date >= date('now', ?)
                ORDER BY stat_date DESC
            """, (f'-{days} days',))
            rows = cursor.fetchall()
            return [
                {
                    'date': row[0],
                    'total': row[1],
                    'successful': row[2],
                    'failed': row[3],
                    'banned': row[4],
                    'code_15': row[5],
                    'tunnel_failed': row[6],
                    'timeouts': row[7],
                    'success_rate': row[8]
                }
                for row in rows
            ]
        except Exception as e:
            print(f"Error getting Xilriws daily stats: {e}")
            return []
        finally:
            conn.close()
    
    def get_xilriws_proxy_history(self, limit=100):
        """Get all-time proxy statistics"""
        conn = self._connect()
        if not conn:
            return []
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT proxy_address, total_requests, successful, failed,
                       timeouts, unreachable, bot_blocked, success_rate,
                       first_seen, last_seen
                FROM xilriws_proxy_stats 
                ORDER BY total_requests DESC 
                LIMIT ?
            """, (limit,))
            rows = cursor.fetchall()
            return [
                {
                    'proxy': row[0],
                    'total': row[1],
                    'successful': row[2],
                    'failed': row[3],
                    'timeouts': row[4],
                    'unreachable': row[5],
                    'bot_blocked': row[6],
                    'success_rate': row[7],
                    'first_seen': row[8],
                    'last_seen': row[9]
                }
                for row in rows
            ]
        except Exception as e:
            print(f"Error getting Xilriws proxy history: {e}")
            return []
        finally:
            conn.close()
    
    def get_koji_daily_stats(self, days=30):
        """Get Koji daily statistics"""
        conn = self._connect()
        if not conn:
            return []
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT stat_date, total_requests, geofence_requests, 
                       health_checks, errors, avg_response_time_ms
                FROM koji_daily 
                WHERE stat_date >= date('now', ?)
                ORDER BY stat_date DESC
            """, (f'-{days} days',))
            rows = cursor.fetchall()
            return [
                {
                    'date': row[0],
                    'total': row[1],
                    'geofence': row[2],
                    'health': row[3],
                    'errors': row[4],
                    'avg_response_ms': row[5]
                }
                for row in rows
            ]
        except Exception as e:
            print(f"Error getting Koji daily stats: {e}")
            return []
        finally:
            conn.close()
    
    def get_db_connection_history(self):
        """Get database connection statistics"""
        conn = self._connect()
        if not conn:
            return []
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT db_name, user_name, host, 
                       total_connections, aborted_connections,
                       first_seen, last_seen
                FROM db_connection_stats 
                ORDER BY aborted_connections DESC
            """)
            rows = cursor.fetchall()
            return [
                {
                    'db': row[0],
                    'user': row[1],
                    'host': row[2],
                    'total': row[3],
                    'aborted': row[4],
                    'first_seen': row[5],
                    'last_seen': row[6]
                }
                for row in rows
            ]
        except Exception as e:
            print(f"Error getting DB connection history: {e}")
            return []
        finally:
            conn.close()
    
    def get_service_health_history(self, service_name=None, hours=24):
        """Get service health history"""
        conn = self._connect()
        if not conn:
            return []
        try:
            cursor = conn.cursor()
            if service_name:
                cursor.execute("""
                    SELECT service_name, status, details, recorded_at
                    FROM service_health 
                    WHERE service_name = ? AND recorded_at >= datetime('now', ?)
                    ORDER BY recorded_at DESC
                """, (service_name, f'-{hours} hours'))
            else:
                cursor.execute("""
                    SELECT service_name, status, details, recorded_at
                    FROM service_health 
                    WHERE recorded_at >= datetime('now', ?)
                    ORDER BY recorded_at DESC
                """, (f'-{hours} hours',))
            rows = cursor.fetchall()
            return [
                {
                    'service': row[0],
                    'status': row[1],
                    'details': json.loads(row[2]) if row[2] else None,
                    'recorded_at': row[3]
                }
                for row in rows
            ]
        except Exception as e:
            print(f"Error getting service health history: {e}")
            return []
        finally:
            conn.close()
    
    def get_cross_reference_summary(self):
        """Get a cross-referenced summary of all services"""
        conn = self._connect()
        if not conn:
            return {}
        
        try:
            cursor = conn.cursor()
            summary = {
                'xilriws': {},
                'rotom': {},
                'koji': {},
                'database': {},
                'generated_at': datetime.now().isoformat()
            }
            
            # Xilriws summary
            cursor.execute("""
                SELECT 
                    COALESCE(SUM(total_requests), 0) as total,
                    COALESCE(SUM(successful), 0) as success,
                    COALESCE(SUM(failed), 0) as failed,
                    COALESCE(AVG(success_rate), 0) as avg_rate
                FROM xilriws_daily
                WHERE stat_date >= date('now', '-7 days')
            """)
            row = cursor.fetchone()
            if row:
                summary['xilriws'] = {
                    'week_total': row[0],
                    'week_success': row[1],
                    'week_failed': row[2],
                    'week_avg_rate': round(row[3], 1) if row[3] else 0
                }
            
            # Proxy count
            cursor.execute("SELECT COUNT(*) FROM xilriws_proxy_stats")
            row = cursor.fetchone()
            summary['xilriws']['total_proxies_tracked'] = row[0] if row else 0
            
            # Rotom summary
            cursor.execute("""
                SELECT COUNT(*), 
                       SUM(total_connections), 
                       SUM(total_disconnections)
                FROM rotom_devices
            """)
            row = cursor.fetchone()
            if row:
                summary['rotom'] = {
                    'total_devices': row[0] or 0,
                    'total_connections': row[1] or 0,
                    'total_disconnections': row[2] or 0
                }
            
            # Koji summary
            cursor.execute("""
                SELECT 
                    COALESCE(SUM(total_requests), 0),
                    COALESCE(SUM(errors), 0),
                    COALESCE(AVG(avg_response_time_ms), 0)
                FROM koji_daily
                WHERE stat_date >= date('now', '-7 days')
            """)
            row = cursor.fetchone()
            if row:
                summary['koji'] = {
                    'week_requests': row[0],
                    'week_errors': row[1],
                    'week_avg_response_ms': round(row[2], 2) if row[2] else 0
                }
            
            # Database summary
            cursor.execute("""
                SELECT 
                    COUNT(DISTINCT db_name),
                    SUM(aborted_connections)
                FROM db_connection_stats
            """)
            row = cursor.fetchone()
            if row:
                summary['database'] = {
                    'databases_tracked': row[0] or 0,
                    'total_aborted': row[1] or 0
                }
            
            return summary
        except Exception as e:
            print(f"Error getting cross-reference summary: {e}")
            return {'error': str(e)}
        finally:
            conn.close()

# Initialize database accessor
shellder_db = ShellderDB(SHELLDER_DB)

# Ensure service tables exist on startup
shellder_db.ensure_service_tables()

# Initialize device manager for cross-referencing
device_manager = DeviceManager(SHELLDER_DB, AEGIS_ROOT)

# Initialize device monitor for real-time activity listening
device_monitor = DeviceMonitor(device_manager, shellder_db)

# =============================================================================
# STATS COLLECTOR (Real-time)
# =============================================================================

class StatsCollector:
    """Collects and stores live statistics for all Aegis AIO components
    
    CPU Optimization: Uses adaptive polling intervals based on client connections.
    - When clients connected: faster polling (15-30s)
    - When idle: slower polling (60-120s) to save CPU
    """
    
    # Polling intervals (seconds) - OPTIMIZED for lower CPU usage
    POLL_FAST_CONTAINER = 15      # Was 5s - container stats when clients connected
    POLL_SLOW_CONTAINER = 60     # Container stats when idle
    POLL_FAST_SYSTEM = 30        # Was 10s - system stats when clients connected  
    POLL_SLOW_SYSTEM = 120       # System stats when idle
    POLL_FAST_LOGS = 15          # Was 5-10s - log parsing when clients connected
    POLL_SLOW_LOGS = 60          # Log parsing when idle
    POLL_PORTS = 60              # Was 30s - port scanning
    POLL_SERVICES = 120          # Was 60s - system services check
    
    def __init__(self):
        self.container_stats = {}
        self.xilriws_stats = {
            'total_requests': 0,
            'successful': 0,
            'failed': 0,
            'auth_banned': 0,
            'invalid_credentials': 0,
            'tunneling_errors': 0,
            'code_15': 0,
            'rate_limited': 0,
            'timeouts': 0,
            'connection_refused': 0,
            'proxy_errors': 0,
            'by_proxy': {},
            'recent_errors': [],
            'success_rate': 0
        }
        # Rotom stats - Device management
        self.rotom_stats = {
            'devices': {},           # Device name -> info
            'workers': {},           # Worker ID -> info
            'connections': 0,
            'disconnections': 0,
            'rejected_connections': 0,
            'memory_reports': [],
            'recent_events': [],
            'last_update': None
        }
        # Koji stats - Geofence/API service
        self.koji_stats = {
            'requests': 0,
            'geofence_requests': 0,
            'health_checks': 0,
            'errors': 0,
            'parse_errors': 0,
            'http_errors': 0,
            'recent_requests': [],
            'recent_errors': [],
            'last_update': None
        }
        # Reactmap stats - Frontend map
        self.reactmap_stats = {
            'build_status': 'unknown',
            'build_time': None,
            'locales_loaded': [],
            'warnings': [],
            'errors': [],
            'version': None,
            'last_update': None
        }
        # Database (MariaDB) stats
        self.database_stats = {
            'status': 'unknown',
            'version': None,
            'connections': {
                'total': 0,
                'aborted': 0,
                'by_db': {},       # db name -> count
                'by_host': {}     # host -> count
            },
            'warnings': [],
            'errors': [],
            'buffer_pool_size': None,
            'innodb_status': {},
            'recent_events': [],
            'last_update': None
        }
        self.system_stats = {}
        self.port_status = {}
        self.service_status = {'nginx': None, 'fail2ban': None, 'ufw': None}
        self.running = False
        self.lock = threading.Lock()
        
        # Client tracking for adaptive polling
        self.connected_clients = 0
        self.last_api_request = time.time()
        self._api_request_timeout = 120  # Consider idle after 2 min no requests
    
    def has_active_clients(self):
        """Check if there are active clients (WebSocket or recent API requests)"""
        if self.connected_clients > 0:
            return True
        # Also check for recent API activity
        return (time.time() - self.last_api_request) < self._api_request_timeout
    
    def record_api_request(self):
        """Record that an API request was made (keeps polling active)"""
        self.last_api_request = time.time()
    
    def client_connected(self):
        """Called when a WebSocket client connects"""
        self.connected_clients += 1
    
    def client_disconnected(self):
        """Called when a WebSocket client disconnects"""
        self.connected_clients = max(0, self.connected_clients - 1)
        
    def start(self):
        """Start background collection threads"""
        self.running = True
        
        # Container stats thread
        threading.Thread(target=self._collect_container_stats, daemon=True).start()
        
        # System stats thread
        threading.Thread(target=self._collect_system_stats, daemon=True).start()
        
        # Metrics cleanup thread (runs once per hour)
        threading.Thread(target=self._cleanup_old_metrics, daemon=True).start()
        
        # Xilriws log parser thread
        threading.Thread(target=self._parse_xilriws_logs, daemon=True).start()
        
        # Rotom log parser thread
        threading.Thread(target=self._parse_rotom_logs, daemon=True).start()
        
        # Koji log parser thread
        threading.Thread(target=self._parse_koji_logs, daemon=True).start()
        
        # Reactmap log parser thread
        threading.Thread(target=self._parse_reactmap_logs, daemon=True).start()
        
        # Database log parser thread
        threading.Thread(target=self._parse_database_logs, daemon=True).start()
        
        # Port scanner thread
        threading.Thread(target=self._scan_ports, daemon=True).start()
        
        # System services thread
        threading.Thread(target=self._check_system_services, daemon=True).start()
        
        # Disk watchdog thread - auto-cleans known bloat
        threading.Thread(target=self._disk_watchdog, daemon=True).start()
        
        print("Stats collector started with parsers for: Xilriws, Rotom, Koji, Reactmap, Database")
        print("Disk watchdog started - will auto-clean known bloat sources")
        print(f"CPU Optimization: Adaptive polling enabled")
        print(f"  - Fast mode (clients connected): {self.POLL_FAST_CONTAINER}s containers, {self.POLL_FAST_SYSTEM}s system, {self.POLL_FAST_LOGS}s logs")
        print(f"  - Slow mode (idle): {self.POLL_SLOW_CONTAINER}s containers, {self.POLL_SLOW_SYSTEM}s system, {self.POLL_SLOW_LOGS}s logs")
    
    def stop(self):
        self.running = False
    
    def _collect_container_stats(self):
        """Collect Docker container statistics"""
        while self.running:
            stats = {}
            
            if docker_client:
                try:
                    containers = docker_client.containers.list(all=True)
                    
                    for container in containers:
                        try:
                            # Get basic info first
                            container_info = {
                                'name': container.name,
                                'status': container.status,
                                'image': container.image.tags[0] if container.image.tags else 'unknown',
                                'cpu_percent': 0,
                                'memory_usage': 0,
                                'memory_limit': 0,
                                'memory_percent': 0
                            }
                            
                            # Get detailed stats only for running containers
                            if container.status == 'running':
                                try:
                                    container_stats = container.stats(stream=False)
                                    
                                    # Calculate CPU usage
                                    cpu_delta = container_stats['cpu_stats']['cpu_usage']['total_usage'] - \
                                               container_stats['precpu_stats']['cpu_usage']['total_usage']
                                    system_delta = container_stats['cpu_stats'].get('system_cpu_usage', 0) - \
                                                  container_stats['precpu_stats'].get('system_cpu_usage', 0)
                                    
                                    if system_delta > 0:
                                        container_info['cpu_percent'] = round((cpu_delta / system_delta) * 100.0, 2)
                                    
                                    # Calculate memory usage
                                    mem_usage = container_stats['memory_stats'].get('usage', 0)
                                    mem_limit = container_stats['memory_stats'].get('limit', 1)
                                    container_info['memory_usage'] = mem_usage
                                    container_info['memory_limit'] = mem_limit
                                    container_info['memory_percent'] = round((mem_usage / mem_limit) * 100.0, 2)
                                except Exception:
                                    pass
                            
                            stats[container.name] = container_info
                            
                        except Exception as e:
                            stats[container.name] = {
                                'name': container.name,
                                'status': container.status,
                                'error': str(e)
                            }
                    
                except Exception as e:
                    print(f"Error collecting container stats: {e}")
            else:
                # Fallback to subprocess
                try:
                    result = subprocess.run(
                        ["docker", "ps", "-a", "--format", "{{.Names}}|{{.Status}}|{{.State}}|{{.Image}}"],
                        capture_output=True, text=True, timeout=10
                    )
                    for line in result.stdout.strip().split('\n'):
                        if line and '|' in line:
                            parts = line.split('|')
                            if len(parts) >= 4:
                                stats[parts[0]] = {
                                    'name': parts[0],
                                    'status': parts[2],
                                    'image': parts[3],
                                    'cpu_percent': 0,
                                    'memory_percent': 0
                                }
                except Exception as e:
                    print(f"Error using docker subprocess: {e}")
            
            with self.lock:
                self.container_stats = stats
            
            # Emit to connected clients
            if socketio and SOCKETIO_AVAILABLE:
                socketio.emit('container_stats', stats)
            
            # Adaptive polling: faster when clients connected, slower when idle
            poll_interval = self.POLL_FAST_CONTAINER if self.has_active_clients() else self.POLL_SLOW_CONTAINER
            time.sleep(poll_interval)
    
    def _collect_system_stats(self):
        """Collect system resource statistics"""
        while self.running:
            stats = {}
            
            if PSUTIL_AVAILABLE:
                try:
                    stats = {
                        'cpu_percent': psutil.cpu_percent(interval=1),
                        'memory': {
                            'total': psutil.virtual_memory().total,
                            'available': psutil.virtual_memory().available,
                            'percent': psutil.virtual_memory().percent,
                            'used': psutil.virtual_memory().used
                        },
                        'disk': {
                            'total': psutil.disk_usage('/').total,
                            'used': psutil.disk_usage('/').used,
                            'free': psutil.disk_usage('/').free,
                            'percent': psutil.disk_usage('/').percent
                        },
                        'uptime': time.time() - psutil.boot_time(),
                        'timestamp': datetime.now().isoformat()
                    }
                except Exception as e:
                    print(f"Error collecting system stats: {e}")
            else:
                # Fallback to subprocess
                try:
                    # Memory
                    result = subprocess.run(["free", "-b"], capture_output=True, text=True, timeout=5)
                    lines = result.stdout.strip().split('\n')
                    if len(lines) > 1:
                        parts = lines[1].split()
                        if len(parts) >= 4:
                            total = int(parts[1])
                            used = int(parts[2])
                            stats['memory'] = {
                                'total': total,
                                'used': used,
                                'available': total - used,
                                'percent': round((used / total) * 100, 1)
                            }
                    
                    # Disk
                    result = subprocess.run(["df", "-B1", "/"], capture_output=True, text=True, timeout=5)
                    lines = result.stdout.strip().split('\n')
                    if len(lines) > 1:
                        parts = lines[1].split()
                        if len(parts) >= 5:
                            stats['disk'] = {
                                'total': int(parts[1]),
                                'used': int(parts[2]),
                                'free': int(parts[3]),
                                'percent': float(parts[4].replace('%', ''))
                            }
                    
                    stats['timestamp'] = datetime.now().isoformat()
                except Exception as e:
                    print(f"Error using system subprocess: {e}")
            
            with self.lock:
                self.system_stats = stats
            
            if socketio and SOCKETIO_AVAILABLE:
                socketio.emit('system_stats', stats)
            
            # Record metrics to history database (every 60 seconds - reduced from 30s)
            if hasattr(self, '_last_metric_record'):
                if time.time() - self._last_metric_record >= 60:
                    self._record_system_metrics(stats)
                    self._last_metric_record = time.time()
            else:
                self._last_metric_record = time.time()
                self._record_system_metrics(stats)
            
            # Adaptive polling: faster when clients connected, slower when idle
            poll_interval = self.POLL_FAST_SYSTEM if self.has_active_clients() else self.POLL_SLOW_SYSTEM
            time.sleep(poll_interval)
    
    def _record_system_metrics(self, stats):
        """Record system metrics to history database"""
        try:
            metrics = {}
            
            if 'cpu_percent' in stats:
                metrics['cpu_percent'] = stats['cpu_percent']
            
            if 'memory' in stats:
                metrics['memory_percent'] = stats['memory'].get('percent', 0)
                metrics['memory_used'] = stats['memory'].get('used', 0) / (1024**3)  # GB
            
            if 'disk' in stats:
                metrics['disk_percent'] = stats['disk'].get('percent', 0)
            
            if metrics:
                if shellder_db:
                    success = shellder_db.record_metrics_batch(metrics)
                    if not success:
                        error('METRICS', 'Failed to record metrics batch - returned False')
                else:
                    error('METRICS', 'Cannot record metrics - shellder_db is None')
        except Exception as e:
            error('METRICS', f'Exception recording system metrics: {e}', exc_info=True)
            print(f"Error recording system metrics: {e}")
    
    def _cleanup_old_metrics(self):
        """Periodically clean up old metrics to prevent database bloat"""
        while self.running:
            try:
                # Wait 1 hour between cleanups
                time.sleep(3600)
                # Keep 7 days of metrics
                shellder_db.cleanup_old_metrics(days=7)
            except Exception as e:
                print(f"Error in metrics cleanup: {e}")
    
    def _parse_xilriws_logs(self):
        """
        Parse Xilriws container logs for proxy statistics
        
        Log format: HH:MM:SS.SS | LEVEL | Component | Message
        Levels: I (Info), S (Success), W (Warning), E (Error), C (Critical)
        Components: Browser, Proxy, PTC, Cookie, Xilriws
        """
        import re
        
        # Regex patterns for Xilriws log format
        log_pattern = re.compile(r'^(\d{2}:\d{2}:\d{2}\.\d{2})\s*\|\s*([ISEWC])\s*\|\s*(\w+)\s*\|\s*(.*)$')
        proxy_pattern = re.compile(r'[Pp]roxy[:\s]+(\d+\.\d+\.\d+\.\d+:\d+|[\w.-]+:\d+)')
        cookie_storage_pattern = re.compile(r'Cookie storage at (\d+)/(\d+)')
        
        while self.running:
            if docker_client:
                try:
                    container = docker_client.containers.get('xilriws')
                    if container.status != 'running':
                        time.sleep(30)
                        continue
                    
                    # Get recent logs (more lines for better stats)
                    logs = container.logs(tail=1000, timestamps=False).decode('utf-8', errors='ignore')
                    
                    # Initialize stats
                    stats = {
                        'total_requests': 0,
                        'successful': 0,
                        'failed': 0,
                        'success_rate': 0,
                        # Auth results
                        'auth_success': 0,          # S | Xilriws | 200 OK: successful auth
                        'auth_banned': 0,           # W | Xilriws | 418: account is ptc-banned
                        'auth_max_retries': 0,      # E | Xilriws | Error: Exceeded max retries
                        'auth_internal_error': 0,   # W | Xilriws | 500 Internal Server Error
                        # Browser errors
                        'browser_timeout': 0,       # E | Browser | Page timed out
                        'browser_unreachable': 0,   # E | Browser | Page couldn't be reached
                        'browser_bot_protection': 0,# E | Browser | Didn't pass JS check. Code 15
                        'browser_js_timeout': 0,    # E | Browser | Timeout on JS challenge
                        # PTC errors
                        'ptc_tunnel_failed': 0,     # E | PTC | curl: (56) CONNECT tunnel failed
                        'ptc_connection_timeout': 0,# E | PTC | curl: (28) Connection timed out
                        'ptc_captcha': 0,           # W | PTC | Error code 12 (Captcha)
                        # Critical
                        'critical_failures': 0,     # C | Browser | consecutive failures
                        # Cookie status
                        'cookie_current': 0,
                        'cookie_max': 2,
                        # Proxy stats (per-proxy tracking)
                        'proxy_stats': {},
                        'current_proxy': None,
                        # Recent events
                        'recent_errors': [],
                        'recent_successes': [],
                        'last_critical': None
                    }
                    
                    current_proxy = None
                    
                    for line in logs.split('\n'):
                        if not line.strip():
                            continue
                        
                        match = log_pattern.match(line.strip())
                        if not match:
                            continue
                        
                        timestamp, level, component, message = match.groups()
                        component = component.strip()
                        message = message.strip()
                        msg_lower = message.lower()
                        
                        # Track proxy switches
                        if component == 'Proxy' and 'Switching to Proxy' in message:
                            proxy_match = proxy_pattern.search(message)
                            if proxy_match:
                                current_proxy = proxy_match.group(1)
                                stats['current_proxy'] = current_proxy
                                if current_proxy not in stats['proxy_stats']:
                                    stats['proxy_stats'][current_proxy] = {
                                        'requests': 0, 'success': 0, 'fail': 0,
                                        'timeout': 0, 'unreachable': 0, 'bot_blocked': 0
                                    }
                        
                        # Track cookie storage
                        if component == 'Cookie':
                            cookie_match = cookie_storage_pattern.search(message)
                            if cookie_match:
                                stats['cookie_current'] = int(cookie_match.group(1))
                                stats['cookie_max'] = int(cookie_match.group(2))
                        
                        # SUCCESS events (S level)
                        if level == 'S':
                            if '200 OK' in message and 'successful auth' in msg_lower:
                                stats['auth_success'] += 1
                                stats['successful'] += 1
                                stats['recent_successes'].append({
                                    'time': timestamp,
                                    'proxy': current_proxy
                                })
                                # Update proxy stats
                                if current_proxy and current_proxy in stats['proxy_stats']:
                                    stats['proxy_stats'][current_proxy]['success'] += 1
                                    stats['proxy_stats'][current_proxy]['requests'] += 1
                        
                        # WARNING events (W level)
                        elif level == 'W':
                            if component == 'Xilriws':
                                if '418' in message and 'ptc-banned' in msg_lower:
                                    stats['auth_banned'] += 1
                                    stats['failed'] += 1
                                elif '500' in message and 'internal server error' in msg_lower:
                                    stats['auth_internal_error'] += 1
                                    stats['failed'] += 1
                            elif component == 'PTC':
                                if 'Error code 12' in message or 'Captcha' in message:
                                    stats['ptc_captcha'] += 1
                                    stats['recent_errors'].append({
                                        'time': timestamp,
                                        'type': 'captcha',
                                        'proxy': current_proxy,
                                        'message': message[:100]
                                    })
                        
                        # ERROR events (E level)
                        elif level == 'E':
                            error_recorded = False
                            
                            if component == 'Browser':
                                # Extract proxy from error message if present
                                error_proxy = current_proxy
                                proxy_in_msg = proxy_pattern.search(message)
                                if proxy_in_msg:
                                    error_proxy = proxy_in_msg.group(1)
                                
                                if 'Page timed out' in message:
                                    stats['browser_timeout'] += 1
                                    error_recorded = True
                                    if error_proxy and error_proxy in stats['proxy_stats']:
                                        stats['proxy_stats'][error_proxy]['timeout'] += 1
                                        stats['proxy_stats'][error_proxy]['fail'] += 1
                                        stats['proxy_stats'][error_proxy]['requests'] += 1
                                elif "Page couldn't be reached" in message or "couldn't be reached" in msg_lower:
                                    stats['browser_unreachable'] += 1
                                    error_recorded = True
                                    if error_proxy and error_proxy in stats['proxy_stats']:
                                        stats['proxy_stats'][error_proxy]['unreachable'] += 1
                                        stats['proxy_stats'][error_proxy]['fail'] += 1
                                        stats['proxy_stats'][error_proxy]['requests'] += 1
                                elif "Didn't pass JS check" in message or 'Code 15' in message:
                                    stats['browser_bot_protection'] += 1
                                    error_recorded = True
                                    if error_proxy and error_proxy in stats['proxy_stats']:
                                        stats['proxy_stats'][error_proxy]['bot_blocked'] += 1
                                        stats['proxy_stats'][error_proxy]['fail'] += 1
                                        stats['proxy_stats'][error_proxy]['requests'] += 1
                                elif 'Timeout on JS challenge' in message:
                                    stats['browser_js_timeout'] += 1
                                    error_recorded = True
                            
                            elif component == 'PTC':
                                if 'curl: (56)' in message or 'CONNECT tunnel failed' in message or 'response 407' in message:
                                    stats['ptc_tunnel_failed'] += 1
                                    error_recorded = True
                                elif 'curl: (28)' in message or 'Connection timed out' in message or 'timed out after' in msg_lower:
                                    stats['ptc_connection_timeout'] += 1
                                    error_recorded = True
                            
                            elif component == 'Xilriws':
                                if 'Exceeded max retries' in message:
                                    stats['auth_max_retries'] += 1
                                    error_recorded = True
                            
                            if error_recorded:
                                stats['failed'] += 1
                                stats['recent_errors'].append({
                                    'time': timestamp,
                                    'type': component.lower(),
                                    'proxy': current_proxy,
                                    'message': message[:150]
                                })
                        
                        # CRITICAL events (C level)
                        elif level == 'C':
                            stats['critical_failures'] += 1
                            stats['last_critical'] = {
                                'time': timestamp,
                                'message': message
                            }
                            stats['recent_errors'].append({
                                'time': timestamp,
                                'type': 'CRITICAL',
                                'proxy': current_proxy,
                                'message': message[:150]
                            })
                    
                    # Keep only last 50 errors and 20 successes
                    stats['recent_errors'] = stats['recent_errors'][-50:]
                    stats['recent_successes'] = stats['recent_successes'][-20:]
                    
                    # Calculate totals
                    stats['total_requests'] = stats['successful'] + stats['failed']
                    
                    # Calculate success rate
                    if stats['total_requests'] > 0:
                        stats['success_rate'] = round((stats['successful'] / stats['total_requests']) * 100, 1)
                    else:
                        stats['success_rate'] = 0
                    
                    # Calculate per-proxy success rates
                    for proxy_addr, proxy_data in stats['proxy_stats'].items():
                        if proxy_data['requests'] > 0:
                            proxy_data['success_rate'] = round(
                                (proxy_data['success'] / proxy_data['requests']) * 100, 1
                            )
                        else:
                            proxy_data['success_rate'] = 0
                    
                    # Create error breakdown for display
                    stats['error_breakdown'] = {
                        'Browser Timeouts': stats['browser_timeout'],
                        'Proxy Unreachable': stats['browser_unreachable'],
                        'Bot Protection (Code 15)': stats['browser_bot_protection'],
                        'JS Challenge Timeout': stats['browser_js_timeout'],
                        'Tunnel Failed (407)': stats['ptc_tunnel_failed'],
                        'Connection Timeout': stats['ptc_connection_timeout'],
                        'Captcha Triggered': stats['ptc_captcha'],
                        'Account Banned (418)': stats['auth_banned'],
                        'Max Retries Exceeded': stats['auth_max_retries'],
                        'Internal Server Error': stats['auth_internal_error'],
                        'Critical Failures': stats['critical_failures']
                    }
                    
                    with self.lock:
                        self.xilriws_stats = stats
                    
                    if socketio and SOCKETIO_AVAILABLE:
                        socketio.emit('xilriws_stats', stats)
                    
                    # Persist to database for cross-referencing
                    shellder_db.persist_xilriws_stats(stats)
                    
                except docker.errors.NotFound:
                    pass
                except Exception as e:
                    print(f"Error parsing Xilriws logs: {e}")
            
            # Adaptive polling for log parsing
            poll_interval = self.POLL_FAST_LOGS if self.has_active_clients() else self.POLL_SLOW_LOGS
            time.sleep(poll_interval)
    
    def _parse_rotom_logs(self):
        """
        Parse Rotom container logs for device/worker statistics
        
        Log format: [TIMESTAMP] [LEVEL] [rotom] MESSAGE
        Example: [2025-11-30T05:57:59.198Z] [INFO] [rotom] CONTROLLER: Found OrangePi5 connects to workerId OrangePi5-1
        
        Key events:
        - CONTROLLER: Found X connects to workerId Y - Device connection
        - CONTROLLER: New connection from IP - will allocate WORKER - Worker allocation
        - CONTROLLER: New connection from IP - no spare Workers, rejecting - Rejection
        - CONTROLLER: Disconnected worker X - Worker disconnect
        - X/Y: Disconnected; performing disconnection activities - Device disconnect
        - X: unallocated connections = Y - Unallocated workers
        - X/Y: Received id packet origin Z - version V - Device identification
        - X/Y: Memory = {...} - Memory report
        """
        import re
        
        # Regex patterns
        log_pattern = re.compile(r'^\[([^\]]+)\]\s*\[(\w+)\]\s*\[rotom\]\s*(.*)$')
        device_connect = re.compile(r'CONTROLLER:\s*Found\s+(\S+)\s+connects\s+to\s+workerId\s+(\S+)')
        worker_allocate = re.compile(r'CONTROLLER:\s*New connection from\s+(\S+)\s*-\s*will allocate\s+(\S+)')
        worker_reject = re.compile(r'CONTROLLER:\s*New connection from\s+(\S+)\s*-\s*no spare Workers')
        worker_disconnect = re.compile(r'CONTROLLER:\s*Disconnected worker\s+(\S+)')
        device_disconnect = re.compile(r'^(\S+)/(\d+):\s*Disconnected')
        device_id = re.compile(r'^(\S+)/(\d+):\s*Received id packet origin\s+(\S+)\s*-\s*version\s+(\d+)')
        memory_report = re.compile(r'^(\S+)/(\d+):Memory\s*=\s*(\{.*\})')
        unallocated = re.compile(r'^(\S+):\s*unallocated connections\s*=\s*(.*)')
        
        while self.running:
            if docker_client:
                try:
                    container = docker_client.containers.get('rotom')
                    if container.status != 'running':
                        time.sleep(30)
                        continue
                    
                    logs = container.logs(tail=500, timestamps=False).decode('utf-8', errors='ignore')
                    
                    stats = {
                        'devices': {},
                        'workers': {},
                        'connections': 0,
                        'disconnections': 0,
                        'rejected_connections': 0,
                        'memory_reports': [],
                        'recent_events': [],
                        'last_update': datetime.now().isoformat()
                    }
                    
                    for line in logs.split('\n'):
                        if not line.strip():
                            continue
                        
                        match = log_pattern.match(line.strip())
                        if not match:
                            continue
                        
                        timestamp, level, message = match.groups()
                        
                        # Device connection
                        m = device_connect.search(message)
                        if m:
                            device_name, worker_id = m.groups()
                            stats['devices'][device_name] = {
                                'worker_id': worker_id,
                                'status': 'connected',
                                'last_seen': timestamp
                            }
                            stats['connections'] += 1
                            stats['recent_events'].append({
                                'time': timestamp,
                                'type': 'connect',
                                'device': device_name,
                                'worker': worker_id
                            })
                            continue
                        
                        # Worker allocation
                        m = worker_allocate.search(message)
                        if m:
                            ip, worker_id = m.groups()
                            stats['workers'][worker_id] = {
                                'ip': ip,
                                'status': 'allocated',
                                'last_seen': timestamp
                            }
                            continue
                        
                        # Worker rejection
                        m = worker_reject.search(message)
                        if m:
                            ip = m.group(1)
                            stats['rejected_connections'] += 1
                            stats['recent_events'].append({
                                'time': timestamp,
                                'type': 'rejected',
                                'ip': ip,
                                'reason': 'no spare workers'
                            })
                            continue
                        
                        # Worker disconnect
                        m = worker_disconnect.search(message)
                        if m:
                            worker_info = m.group(1)
                            stats['disconnections'] += 1
                            stats['recent_events'].append({
                                'time': timestamp,
                                'type': 'worker_disconnect',
                                'worker': worker_info
                            })
                            continue
                        
                        # Device disconnect
                        m = device_disconnect.match(message)
                        if m:
                            device_name, session = m.groups()
                            if device_name in stats['devices']:
                                stats['devices'][device_name]['status'] = 'disconnected'
                            stats['recent_events'].append({
                                'time': timestamp,
                                'type': 'device_disconnect',
                                'device': device_name
                            })
                            continue
                        
                        # Device identification
                        m = device_id.match(message)
                        if m:
                            device_name, session, origin, version = m.groups()
                            if device_name not in stats['devices']:
                                stats['devices'][device_name] = {}
                            stats['devices'][device_name].update({
                                'origin': origin,
                                'version': version,
                                'last_seen': timestamp
                            })
                            continue
                        
                        # Memory report
                        m = memory_report.match(message)
                        if m:
                            device_name, session, mem_json = m.groups()
                            try:
                                mem_data = json.loads(mem_json)
                                if device_name not in stats['devices']:
                                    stats['devices'][device_name] = {}
                                stats['devices'][device_name]['memory'] = mem_data
                                stats['devices'][device_name]['last_memory'] = timestamp
                                stats['memory_reports'].append({
                                    'time': timestamp,
                                    'device': device_name,
                                    'memory': mem_data
                                })
                            except json.JSONDecodeError:
                                pass
                            continue
                    
                    # Keep only recent events
                    stats['recent_events'] = stats['recent_events'][-50:]
                    stats['memory_reports'] = stats['memory_reports'][-20:]
                    
                    with self.lock:
                        self.rotom_stats = stats
                    
                    if socketio and SOCKETIO_AVAILABLE:
                        socketio.emit('rotom_stats', stats)
                    
                    # Persist to database for cross-referencing
                    shellder_db.persist_rotom_stats(stats)
                    
                except docker.errors.NotFound:
                    pass
                except Exception as e:
                    print(f"Error parsing Rotom logs: {e}")
            
            # Adaptive polling for log parsing
            poll_interval = self.POLL_FAST_LOGS if self.has_active_clients() else self.POLL_SLOW_LOGS
            time.sleep(poll_interval)
    
    def _parse_koji_logs(self):
        """
        Parse Koji container logs for API statistics
        
        Log format: [TIMESTAMP] [LEVEL] [component] MESSAGE
        Example: [2025-11-28T03:54:22Z INFO  api::public::v1::geofence] [GEOFENCES_FC_ALL] Returning 0 instances
        
        Key events:
        - actix_web::middleware::logger - HTTP request logs
        - api::public::v1::geofence - Geofence API calls
        - actix_http::h1::dispatcher - HTTP errors
        - model::utils - Scanner type detection
        - sea_orm_migration - Database migrations
        """
        import re
        
        # Regex patterns
        log_pattern = re.compile(r'^\[([^\]]+)\]\s*\[(\w+)\s*\]\s*\[?([^\]]*)\]?\s*(.*)$')
        http_log = re.compile(r'(\d+)\s*\|\s*(\w+)\s+([^\s]+)\s+HTTP/[\d.]+\s*-\s*(\d+)\s*bytes\s+in\s+([\d.]+)\s*(\w+)\s*\(([^)]+)\)')
        geofence_return = re.compile(r'\[GEOFENCES_FC_ALL\]\s*Returning\s+(\d+)\s+instances')
        scanner_type = re.compile(r'Determined Scanner Type:\s*(\w+)')
        migration = re.compile(r'(Applying|No pending)\s+migrations?')
        error_pattern = re.compile(r'stream error:\s*(.+)')
        
        while self.running:
            if docker_client:
                try:
                    container = docker_client.containers.get('koji')
                    if container.status != 'running':
                        time.sleep(30)
                        continue
                    
                    logs = container.logs(tail=500, timestamps=False).decode('utf-8', errors='ignore')
                    
                    stats = {
                        'requests': 0,
                        'geofence_requests': 0,
                        'health_checks': 0,
                        'errors': 0,
                        'parse_errors': 0,
                        'http_errors': 0,
                        'scanner_type': None,
                        'migrations': 'unknown',
                        'workers': 0,
                        'recent_requests': [],
                        'recent_errors': [],
                        'endpoints_hit': {},
                        'response_times': [],
                        'last_update': datetime.now().isoformat()
                    }
                    
                    for line in logs.split('\n'):
                        if not line.strip():
                            continue
                        
                        # HTTP request log (actix format)
                        m = http_log.search(line)
                        if m:
                            status, method, path, bytes_sent, time_val, time_unit, client_ip = m.groups()
                            stats['requests'] += 1
                            
                            # Track endpoint
                            if path not in stats['endpoints_hit']:
                                stats['endpoints_hit'][path] = 0
                            stats['endpoints_hit'][path] += 1
                            
                            # Track response time
                            try:
                                resp_time = float(time_val)
                                if time_unit == 's':
                                    resp_time *= 1000  # Convert to ms
                                stats['response_times'].append(resp_time)
                            except ValueError:
                                pass
                            
                            # Categorize request
                            if '/health' in path:
                                stats['health_checks'] += 1
                            elif '/geofence' in path:
                                stats['geofence_requests'] += 1
                            
                            stats['recent_requests'].append({
                                'status': int(status),
                                'method': method,
                                'path': path,
                                'bytes': int(bytes_sent),
                                'time_ms': resp_time if 'resp_time' in dir() else 0,
                                'client': client_ip
                            })
                            continue
                        
                        # Geofence return count
                        m = geofence_return.search(line)
                        if m:
                            count = int(m.group(1))
                            continue
                        
                        # Scanner type
                        m = scanner_type.search(line)
                        if m:
                            stats['scanner_type'] = m.group(1)
                            continue
                        
                        # Migration status
                        m = migration.search(line)
                        if m:
                            stats['migrations'] = 'complete' if 'No pending' in m.group(0) else 'applied'
                            continue
                        
                        # Workers count
                        if 'starting' in line.lower() and 'workers' in line.lower():
                            worker_match = re.search(r'(\d+)\s*workers', line)
                            if worker_match:
                                stats['workers'] = int(worker_match.group(1))
                        
                        # HTTP errors
                        m = error_pattern.search(line)
                        if m:
                            stats['http_errors'] += 1
                            error_msg = m.group(1)
                            if 'parse error' in error_msg.lower():
                                stats['parse_errors'] += 1
                            stats['recent_errors'].append({
                                'message': error_msg[:100],
                                'line': line[:150]
                            })
                            continue
                        
                        # ERROR level logs
                        if '[ERROR' in line or '[ ERROR' in line:
                            stats['errors'] += 1
                    
                    # Calculate average response time
                    if stats['response_times']:
                        stats['avg_response_time_ms'] = round(
                            sum(stats['response_times']) / len(stats['response_times']), 2
                        )
                    else:
                        stats['avg_response_time_ms'] = 0
                    
                    # Keep only recent items
                    stats['recent_requests'] = stats['recent_requests'][-30:]
                    stats['recent_errors'] = stats['recent_errors'][-20:]
                    stats['response_times'] = stats['response_times'][-100:]
                    
                    with self.lock:
                        self.koji_stats = stats
                    
                    if socketio and SOCKETIO_AVAILABLE:
                        socketio.emit('koji_stats', stats)
                    
                    # Persist to database for cross-referencing
                    shellder_db.persist_koji_stats(stats)
                    
                except docker.errors.NotFound:
                    pass
                except Exception as e:
                    print(f"Error parsing Koji logs: {e}")
            
            # Adaptive polling for log parsing
            poll_interval = self.POLL_FAST_LOGS if self.has_active_clients() else self.POLL_SLOW_LOGS
            time.sleep(poll_interval)
    
    def _parse_reactmap_logs(self):
        """
        Parse Reactmap container logs for build/status info
        
        Log format: SYMBOL TIMESTAMP [COMPONENT] MESSAGE
        Symbols: ℹ (info), ⚠ (warning), ✓ (success)
        
        Key events:
        - [CONFIG] - Configuration messages
        - [BUILD] - Build process
        - [LOCALES] - Locale loading
        - [MASTERFILE] - Masterfile generation
        """
        import re
        
        # Regex patterns
        log_pattern = re.compile(r'^([ℹ⚠✓])\s*(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s*\[(\w+)\]\s*(.*)$')
        version_pattern = re.compile(r'Building production version:\s*([\d.]+(?:-[\w.]+)?)')
        build_time = re.compile(r'built in\s+([\d.]+)s')
        locale_done = re.compile(r'^(\w+(?:-\w+)?\.json)\s+done')
        locale_missing = re.compile(r'No remote translation found for\s+(\S+)')
        perms_pattern = re.compile(r'adding the following perms')
        
        while self.running:
            if docker_client:
                try:
                    container = docker_client.containers.get('reactmap')
                    if container.status != 'running':
                        time.sleep(30)
                        continue
                    
                    logs = container.logs(tail=300, timestamps=False).decode('utf-8', errors='ignore')
                    
                    stats = {
                        'build_status': 'unknown',
                        'build_time': None,
                        'version': None,
                        'locales_loaded': [],
                        'locales_missing': [],
                        'warnings': [],
                        'errors': [],
                        'config_notes': [],
                        'modules_transformed': 0,
                        'auth_enabled': True,
                        'last_update': datetime.now().isoformat()
                    }
                    
                    for line in logs.split('\n'):
                        if not line.strip():
                            continue
                        
                        # Check for version
                        m = version_pattern.search(line)
                        if m:
                            stats['version'] = m.group(1)
                            stats['build_status'] = 'building'
                            continue
                        
                        # Check for build completion
                        m = build_time.search(line)
                        if m:
                            stats['build_time'] = float(m.group(1))
                            stats['build_status'] = 'complete'
                            continue
                        
                        # Locale loaded
                        m = locale_done.search(line)
                        if m:
                            locale = m.group(1).replace('.json', '')
                            if locale not in stats['locales_loaded']:
                                stats['locales_loaded'].append(locale)
                            continue
                        
                        # Missing locale
                        m = locale_missing.search(line)
                        if m:
                            locale = m.group(1)
                            if locale not in stats['locales_missing']:
                                stats['locales_missing'].append(locale)
                            continue
                        
                        # Modules transformed
                        if 'modules transformed' in line:
                            m = re.search(r'(\d+)\s*modules transformed', line)
                            if m:
                                stats['modules_transformed'] = int(m.group(1))
                            continue
                        
                        # Auth disabled check
                        if 'No authentication strategies enabled' in line:
                            stats['auth_enabled'] = False
                            continue
                        
                        # Build completed message
                        if 'React Map Compiled' in line:
                            stats['build_status'] = 'complete'
                            continue
                        
                        # Warnings (⚠ symbol or [WARN])
                        if '⚠' in line or '[WARN' in line.upper():
                            warning_text = line.split(']')[-1].strip() if ']' in line else line
                            if warning_text and len(warning_text) > 5:
                                stats['warnings'].append(warning_text[:150])
                            continue
                        
                        # Config notes
                        if '[CONFIG]' in line:
                            config_text = line.split('[CONFIG]')[-1].strip()
                            if config_text:
                                stats['config_notes'].append(config_text[:100])
                            continue
                    
                    # Limit arrays
                    stats['warnings'] = stats['warnings'][-20:]
                    stats['config_notes'] = stats['config_notes'][-10:]
                    
                    with self.lock:
                        self.reactmap_stats = stats
                    
                    if socketio and SOCKETIO_AVAILABLE:
                        socketio.emit('reactmap_stats', stats)
                    
                except docker.errors.NotFound:
                    pass
                except Exception as e:
                    print(f"Error parsing Reactmap logs: {e}")
            
            # Reactmap logs don't change frequently - use slower polling
            poll_interval = self.POLL_SLOW_LOGS  # Always use slow polling for Reactmap
            time.sleep(poll_interval)
    
    def _parse_database_logs(self):
        """
        Parse MariaDB/Database container logs for connection statistics
        
        Log format: TIMESTAMP THREAD_ID [LEVEL] MESSAGE
        Example: 2025-11-27 23:10:55 4 [Warning] Aborted connection 4 to db: 'golbat' user: 'pokemap' host: '172.18.0.13'
        
        Key events:
        - [Note] Starting MariaDB - Startup
        - [Note] ready for connections - Ready
        - [Warning] Aborted connection - Connection issues
        - [Note] InnoDB: - InnoDB status
        - [Warning] io_uring - System warnings
        """
        import re
        
        # Regex patterns
        timestamp_pattern = re.compile(r'^(\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}:\d{2}(?:[+-]\d{2}:\d{2})?)')
        thread_log = re.compile(r'(\d+)\s*\[(\w+)\]\s*(.*)$')
        entrypoint = re.compile(r'\[Entrypoint\]:\s*(.*)$')
        aborted_conn = re.compile(r'Aborted connection\s+(\d+)\s+to db:\s*[\'"]?(\w+)[\'"]?\s+user:\s*[\'"]?(\w+)[\'"]?\s+host:\s*[\'"]?([^\'"\s]+)[\'"]?')
        version_pattern = re.compile(r"Version:\s*'([^']+)'")
        buffer_pool = re.compile(r'innodb_buffer_pool_size[_=](\d+)([mMgG]?)')
        ready_pattern = re.compile(r'ready for connections')
        starting_pattern = re.compile(r'Starting MariaDB\s+([\d.]+)')
        
        while self.running:
            if docker_client:
                try:
                    container = docker_client.containers.get('database')
                    if container.status != 'running':
                        time.sleep(30)
                        continue
                    
                    logs = container.logs(tail=500, timestamps=False).decode('utf-8', errors='ignore')
                    
                    stats = {
                        'status': 'unknown',
                        'version': None,
                        'connections': {
                            'total': 0,
                            'aborted': 0,
                            'by_db': {},
                            'by_host': {},
                            'by_user': {}
                        },
                        'warnings': [],
                        'errors': [],
                        'innodb': {
                            'buffer_pool_size': None,
                            'compressed': False,
                            'transaction_pools': 0,
                            'undo_tablespaces': 0,
                            'rollback_segments': 0
                        },
                        'recent_events': [],
                        'startup_notes': [],
                        'last_update': datetime.now().isoformat()
                    }
                    
                    for line in logs.split('\n'):
                        if not line.strip():
                            continue
                        
                        # Extract timestamp if present
                        timestamp = None
                        ts_match = timestamp_pattern.match(line)
                        if ts_match:
                            timestamp = ts_match.group(1)
                            line = line[ts_match.end():].strip()
                        
                        # Entrypoint messages
                        m = entrypoint.search(line)
                        if m:
                            msg = m.group(1)
                            if 'started' in msg.lower():
                                stats['startup_notes'].append(msg[:100])
                            continue
                        
                        # Thread-based log messages
                        m = thread_log.search(line)
                        if m:
                            thread_id, level, message = m.groups()
                            
                            # Ready for connections
                            if ready_pattern.search(message):
                                stats['status'] = 'ready'
                                continue
                            
                            # Version
                            m2 = version_pattern.search(message)
                            if m2:
                                stats['version'] = m2.group(1)
                                continue
                            
                            # Starting
                            m2 = starting_pattern.search(message)
                            if m2:
                                stats['version'] = m2.group(1)
                                stats['status'] = 'starting'
                                continue
                            
                            # Aborted connection
                            m2 = aborted_conn.search(message)
                            if m2:
                                conn_id, db_name, user, host = m2.groups()
                                stats['connections']['aborted'] += 1
                                
                                # Track by database
                                if db_name not in stats['connections']['by_db']:
                                    stats['connections']['by_db'][db_name] = {'total': 0, 'aborted': 0}
                                stats['connections']['by_db'][db_name]['aborted'] += 1
                                
                                # Track by host
                                if host not in stats['connections']['by_host']:
                                    stats['connections']['by_host'][host] = {'total': 0, 'aborted': 0}
                                stats['connections']['by_host'][host]['aborted'] += 1
                                
                                # Track by user
                                if user not in stats['connections']['by_user']:
                                    stats['connections']['by_user'][user] = {'total': 0, 'aborted': 0}
                                stats['connections']['by_user'][user]['aborted'] += 1
                                
                                stats['recent_events'].append({
                                    'time': timestamp,
                                    'type': 'aborted_connection',
                                    'db': db_name,
                                    'user': user,
                                    'host': host
                                })
                                continue
                            
                            # InnoDB buffer pool
                            m2 = buffer_pool.search(message)
                            if m2:
                                size = int(m2.group(1))
                                unit = m2.group(2).lower() if m2.group(2) else ''
                                if unit == 'g':
                                    size *= 1024
                                stats['innodb']['buffer_pool_size'] = f"{size}MB"
                                continue
                            
                            # InnoDB info
                            if 'InnoDB:' in message:
                                if 'Compressed tables' in message:
                                    stats['innodb']['compressed'] = True
                                elif 'transaction pools' in message:
                                    m2 = re.search(r'(\d+)', message)
                                    if m2:
                                        stats['innodb']['transaction_pools'] = int(m2.group(1))
                                elif 'undo tablespaces' in message:
                                    m2 = re.search(r'(\d+)\s+undo tablespaces', message)
                                    if m2:
                                        stats['innodb']['undo_tablespaces'] = int(m2.group(1))
                                elif 'rollback segments' in message:
                                    m2 = re.search(r'(\d+)\s+rollback segments', message)
                                    if m2:
                                        stats['innodb']['rollback_segments'] = int(m2.group(1))
                                continue
                            
                            # Warnings
                            if level == 'Warning':
                                stats['warnings'].append({
                                    'message': message[:150],
                                    'time': timestamp
                                })
                                continue
                            
                            # Errors
                            if level == 'Error':
                                stats['errors'].append({
                                    'message': message[:150],
                                    'time': timestamp
                                })
                                continue
                    
                    # Limit arrays
                    stats['warnings'] = stats['warnings'][-20:]
                    stats['errors'] = stats['errors'][-20:]
                    stats['recent_events'] = stats['recent_events'][-50:]
                    stats['startup_notes'] = stats['startup_notes'][-10:]
                    
                    with self.lock:
                        self.database_stats = stats
                    
                    if socketio and SOCKETIO_AVAILABLE:
                        socketio.emit('database_stats', stats)
                    
                    # Persist to database for cross-referencing
                    shellder_db.persist_database_stats(stats)
                    
                except docker.errors.NotFound:
                    pass
                except Exception as e:
                    print(f"Error parsing Database logs: {e}")
            
            # Adaptive polling for log parsing
            poll_interval = self.POLL_FAST_LOGS if self.has_active_clients() else self.POLL_SLOW_LOGS
            time.sleep(poll_interval)
    
    def _scan_ports(self):
        """Scan important ports"""
        ports_to_check = [
            (5000, 'Shellder GUI'),
            (5090, 'Xilriws'),
            (6001, 'ReactMap'),
            (6002, 'Dragonite Admin'),
            (6003, 'Rotom'),
            (6004, 'Koji'),
            (6005, 'phpMyAdmin'),
            (6006, 'Grafana'),
            (7070, 'Rotom Devices'),
            (3306, 'MariaDB'),
            (80, 'HTTP'),
            (443, 'HTTPS')
        ]
        
        while self.running:
            status = {}
            for port, name in ports_to_check:
                try:
                    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    sock.settimeout(1)
                    result = sock.connect_ex(('127.0.0.1', port))
                    sock.close()
                    status[port] = {
                        'port': port,
                        'name': name,
                        'open': result == 0
                    }
                except Exception:
                    status[port] = {'port': port, 'name': name, 'open': False}
            
            with self.lock:
                self.port_status = status
            
            if socketio and SOCKETIO_AVAILABLE:
                socketio.emit('port_status', status)
            
            time.sleep(self.POLL_PORTS)  # 60 seconds
    
    def _check_system_services(self):
        """Check system services status"""
        while self.running:
            services = {}
            
            for service in ['nginx', 'fail2ban', 'ufw']:
                try:
                    result = subprocess.run(
                        ['systemctl', 'is-active', service],
                        capture_output=True, text=True, timeout=5
                    )
                    services[service] = result.stdout.strip() == 'active'
                except Exception:
                    services[service] = None
            
            with self.lock:
                self.service_status = services
            
            if socketio and SOCKETIO_AVAILABLE:
                socketio.emit('service_status', services)
            
            time.sleep(self.POLL_SERVICES)  # 120 seconds
    
    def _disk_watchdog(self):
        """
        Background disk watchdog - automatically cleans known bloat sources
        Runs every 30 minutes and cleans bloat when:
        - Disk usage > 70% OR
        - Any single bloat source > 1GB
        
        This prevents runaway caches like GNOME Tracker from filling the disk.
        """
        # Wait 60 seconds after startup before first check
        time.sleep(60)
        
        info('DISK_WATCHDOG', 'Disk watchdog started - monitoring for bloat')
        
        while self.running:
            try:
                # Check disk usage
                disk_usage = _get_disk_usage()
                if not disk_usage:
                    time.sleep(1800)  # 30 minutes
                    continue
                
                disk_percent = disk_usage['percent']
                should_clean = False
                reason = ""
                
                # Auto-clean if disk > 70%
                if disk_percent >= 70:
                    should_clean = True
                    reason = f"disk at {disk_percent}%"
                
                # Detect bloat
                bloat_sources = _detect_bloat()
                large_bloat = [b for b in bloat_sources if b['total_size'] > 1024 * 1024 * 1024]  # > 1GB
                
                if large_bloat:
                    should_clean = True
                    reason = f"large bloat detected: {', '.join(b['name'] for b in large_bloat)}"
                
                if should_clean:
                    info('DISK_WATCHDOG', f'Auto-cleanup triggered: {reason}')
                    
                    # Clean only SAFE sources automatically
                    cleaned_total = 0
                    for source in bloat_sources:
                        # Find full config
                        source_config = None
                        for s in KNOWN_BLOAT_SOURCES:
                            if s['id'] == source['id'] and s['safe']:
                                source_config = s
                                break
                        
                        if not source_config:
                            continue
                        
                        # Only clean if source is > 100MB
                        if source['total_size'] < 100 * 1024 * 1024:
                            continue
                        
                        size_before = source['total_size']
                        
                        # Run cleanup commands
                        for cmd in source_config['cleanup_commands']:
                            try:
                                expanded_cmd = cmd
                                for path in source_config['paths']:
                                    if '~' in path:
                                        expanded_cmd = expanded_cmd.replace(path, _expand_path(path))
                                
                                subprocess.run(
                                    expanded_cmd,
                                    shell=True,
                                    capture_output=True,
                                    text=True,
                                    timeout=120
                                )
                            except Exception as e:
                                warn('DISK_WATCHDOG', f'Cleanup command failed: {cmd}', {'error': str(e)})
                        
                        # Calculate freed space
                        size_after = sum(_get_dir_size(p) for p in source_config['paths'])
                        freed = size_before - size_after
                        cleaned_total += freed
                        
                        if freed > 0:
                            info('DISK_WATCHDOG', f'Cleaned {source_config["name"]}: freed {format_bytes(freed)}')
                    
                    if cleaned_total > 0:
                        info('DISK_WATCHDOG', f'Auto-cleanup complete: freed {format_bytes(cleaned_total)} total')
                        
                        # Emit event to connected clients
                        if socketio and SOCKETIO_AVAILABLE:
                            socketio.emit('disk_cleanup', {
                                'freed': format_bytes(cleaned_total),
                                'freed_bytes': cleaned_total,
                                'reason': reason,
                                'timestamp': datetime.now().isoformat()
                            })
                else:
                    debug('DISK_WATCHDOG', f'Disk healthy at {disk_percent}%, no cleanup needed')
                
            except Exception as e:
                error('DISK_WATCHDOG', f'Watchdog error: {e}', exc_info=True)
            
            # Sleep for 30 minutes between checks
            time.sleep(1800)
    
    def get_all_stats(self):
        """Get all collected statistics"""
        with self.lock:
            return {
                'containers': dict(self.container_stats),
                'system': dict(self.system_stats),
                'xilriws': dict(self.xilriws_stats),
                'rotom': dict(self.rotom_stats),
                'koji': dict(self.koji_stats),
                'reactmap': dict(self.reactmap_stats),
                'database': dict(self.database_stats),
                'ports': dict(self.port_status),
                'services': dict(self.service_status)
            }

# Initialize stats collector
stats_collector = StatsCollector()

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

def format_bytes(bytes_val):
    """Format bytes to human readable"""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes_val < 1024:
            return f"{bytes_val:.1f} {unit}"
        bytes_val /= 1024
    return f"{bytes_val:.1f} PB"

def get_container_logs(container_name, lines=100):
    """Get logs from a container"""
    if docker_client:
        try:
            container = docker_client.containers.get(container_name)
            logs = container.logs(tail=lines, timestamps=True).decode('utf-8', errors='ignore')
            return logs
        except Exception as e:
            return f"Error: {str(e)}"
    else:
        try:
            result = subprocess.run(
                ["docker", "logs", "--tail", str(lines), container_name],
                capture_output=True, text=True, timeout=30
            )
            return result.stdout + result.stderr
        except Exception as e:
            return f"Error: {str(e)}"

# =============================================================================
# API ROUTES
# =============================================================================

@app.route('/')
def index():
    """Main dashboard"""
    return render_template('index.html')

@app.route('/static/<path:filename>')
def static_files(filename):
    """Serve static files with aggressive cache busting for development"""
    response = send_from_directory(str(STATIC_DIR), filename)
    # Force browsers to ALWAYS get fresh JS/CSS during development
    if filename.endswith(('.js', '.css')):
        response.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
        response.headers['Pragma'] = 'no-cache'
        response.headers['Expires'] = '0'
        # Remove ETag to prevent 304 responses
        response.headers.pop('ETag', None)
        # Force response to not be conditional
        response.status_code = 200
    return response

@app.route('/api/metrics/history/<metric_name>')
def api_metrics_history(metric_name):
    """Get historical data for a specific metric"""
    try:
        hours = request.args.get('hours', 24, type=float)  # Support fractional hours (e.g. 0.0833 for 5 min)
        limit = request.args.get('limit', 500, type=int)
        
        # Validate metric name
        valid_metrics = ['cpu_percent', 'memory_percent', 'memory_used', 'disk_percent']
        if metric_name not in valid_metrics:
            return jsonify({'error': f'Invalid metric. Valid: {valid_metrics}'}), 400
        
        # Check if shellder_db is available
        if not shellder_db:
            return jsonify({
                'metric': metric_name,
                'hours': hours,
                'data': [],
                'error': 'Database not available'
            })
        
        history = shellder_db.get_metric_history(metric_name, hours, limit)
        return jsonify({
            'metric': metric_name,
            'hours': hours,
            'data': history if history else []
        })
    except Exception as e:
        error('METRICS', f'Error getting metric history for {metric_name}: {e}')
        return jsonify({
            'metric': metric_name,
            'hours': hours if 'hours' in dir() else 24,
            'data': [],
            'error': str(e)
        })

@app.route('/api/metrics/sparklines')
def api_metrics_sparklines():
    """Get sparkline data for all system metrics"""
    try:
        points = request.args.get('points', 20, type=int)
        
        return jsonify({
            'cpu': shellder_db.get_metric_sparkline('cpu_percent', points) if shellder_db else [],
            'memory': shellder_db.get_metric_sparkline('memory_percent', points) if shellder_db else [],
            'disk': shellder_db.get_metric_sparkline('disk_percent', points) if shellder_db else []
        })
    except Exception as e:
        error('METRICS', f'Error getting sparklines: {e}')
        return jsonify({'cpu': [], 'memory': [], 'disk': [], 'error': str(e)})

@app.route('/api/metrics/current')
def api_metrics_current():
    """Get current system metrics with sparkline data"""
    stats = stats_collector.get_all_stats()
    system = stats.get('system', {})
    
    # Get sparklines
    sparklines = {
        'cpu': shellder_db.get_metric_sparkline('cpu_percent', 20),
        'memory': shellder_db.get_metric_sparkline('memory_percent', 20),
        'disk': shellder_db.get_metric_sparkline('disk_percent', 20)
    }
    
    return jsonify({
        'current': {
            'cpu_percent': system.get('cpu_percent', 0),
            'memory_percent': system.get('memory', {}).get('percent', 0),
            'memory_used': format_bytes(system.get('memory', {}).get('used', 0)),
            'memory_total': format_bytes(system.get('memory', {}).get('total', 0)),
            'disk_percent': system.get('disk', {}).get('percent', 0),
            'disk_used': format_bytes(system.get('disk', {}).get('used', 0)),
            'disk_total': format_bytes(system.get('disk', {}).get('total', 0)),
            'uptime': str(timedelta(seconds=int(system.get('uptime', 0))))
        },
        'sparklines': sparklines,
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/metrics/debug')
def api_metrics_debug():
    """Debug endpoint to diagnose metrics database issues"""
    debug_info = {
        'server_time': {
            'utc': datetime.utcnow().isoformat() + 'Z',
            'local': datetime.now().isoformat(),
            'timezone': str(time.timezone / 3600) + ' hours from UTC'
        },
        'database': {
            'available': shellder_db is not None,
            'path': str(shellder_db.db_path) if shellder_db else None
        },
        'metrics': {}
    }
    
    if shellder_db:
        conn = shellder_db._connect()
        if conn:
            try:
                cursor = conn.cursor()
                
                # Get SQLite's view of now
                cursor.execute("SELECT datetime('now'), datetime('now', 'localtime')")
                row = cursor.fetchone()
                debug_info['sqlite_time'] = {
                    'now_utc': row[0],
                    'now_local': row[1]
                }
                
                # Get count and range for each metric
                for metric in ['cpu_percent', 'memory_percent', 'disk_percent']:
                    cursor.execute("""
                        SELECT 
                            COUNT(*) as count,
                            MIN(recorded_at) as oldest,
                            MAX(recorded_at) as newest,
                            MIN(metric_value) as min_val,
                            MAX(metric_value) as max_val,
                            AVG(metric_value) as avg_val
                        FROM metrics_history
                        WHERE metric_name = ?
                    """, (metric,))
                    row = cursor.fetchone()
                    debug_info['metrics'][metric] = {
                        'count': row[0],
                        'oldest': row[1],
                        'newest': row[2],
                        'min': round(row[3], 2) if row[3] else None,
                        'max': round(row[4], 2) if row[4] else None,
                        'avg': round(row[5], 2) if row[5] else None
                    }
                    
                    # Get last 5 entries
                    cursor.execute("""
                        SELECT metric_value, recorded_at
                        FROM metrics_history
                        WHERE metric_name = ?
                        ORDER BY recorded_at DESC
                        LIMIT 5
                    """, (metric,))
                    debug_info['metrics'][metric]['last_5'] = [
                        {'value': r[0], 'time': r[1]} for r in cursor.fetchall()
                    ]
                    
                    # Test the 24h query
                    cursor.execute("""
                        SELECT COUNT(*), MIN(recorded_at), MAX(recorded_at)
                        FROM metrics_history
                        WHERE metric_name = ?
                          AND recorded_at >= datetime('now', '-1440 minutes')
                    """, (metric,))
                    row = cursor.fetchone()
                    debug_info['metrics'][metric]['last_24h_query'] = {
                        'count': row[0],
                        'oldest': row[1],
                        'newest': row[2]
                    }
                
            except Exception as e:
                debug_info['error'] = str(e)
            finally:
                conn.close()
    
    return jsonify(debug_info)

# =============================================================================
# DEBUG ENDPOINTS (AI-FRIENDLY COMPREHENSIVE LOGGING)
# =============================================================================

# Store client-side debug logs
client_debug_logs = []
MAX_CLIENT_LOGS = 100

@app.route('/api/debug/client-logs', methods=['POST'])
def api_debug_client_logs():
    """Receive debug logs from client-side JavaScript and write to unified debuglog.txt"""
    global client_debug_logs
    try:
        # Handle both application/json and text/plain content types (old JS compatibility)
        if request.is_json:
            data = request.get_json()
        else:
            # Try to parse as JSON even if content-type is wrong
            import json
            data = json.loads(request.get_data(as_text=True))
        
        # Log to unified debug log (with client IP for version tracking)
        log_client_logs(data, client_ip=request.remote_addr)
        
        client_debug_logs.append({
            'received_at': datetime.now().isoformat(),
            'client_ip': request.remote_addr,
            'user_agent': request.headers.get('User-Agent', 'unknown'),
            'data': data
        })
        # Keep only last N logs
        if len(client_debug_logs) > MAX_CLIENT_LOGS:
            client_debug_logs = client_debug_logs[-MAX_CLIENT_LOGS:]
        
        info('API', f'Received {len(data.get("allLogs", []))} client logs', {
            'client_ip': request.remote_addr
        })
        
        return jsonify({'success': True, 'logged': len(client_debug_logs)})
    except Exception as e:
        error('API', f'Failed to receive client logs: {e}', exc_info=True)
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/debug/client-logs', methods=['GET'])
def api_debug_get_client_logs():
    """Retrieve stored client debug logs"""
    return jsonify({
        'count': len(client_debug_logs),
        'logs': client_debug_logs
    })

@app.route('/api/debug/live')
def api_debug_live():
    """Get recent debug log entries for live viewing on dashboard"""
    count = request.args.get('count', 50, type=int)
    count = min(count, 200)  # Cap at 200 entries
    
    logs = get_recent_logs(count)
    
    # Parse log entries to extract level and category for filtering/coloring
    parsed = []
    for entry in logs:
        level = 'DEBUG'
        if '[ERROR]' in entry or '[FATAL]' in entry:
            level = 'ERROR'
        elif '[WARN ]' in entry:
            level = 'WARN'
        elif '[INFO ]' in entry:
            level = 'INFO'
        elif '[TRACE]' in entry:
            level = 'TRACE'
        
        parsed.append({
            'raw': entry,
            'level': level
        })
    
    # Get git status
    git_info = {}
    try:
        result = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], 
                               capture_output=True, text=True, timeout=5, cwd=str(AEGIS_ROOT))
        git_info['commit'] = result.stdout.strip() if result.returncode == 0 else 'unknown'
        
        result = subprocess.run(['git', 'log', '-1', '--format=%ci'], 
                               capture_output=True, text=True, timeout=5, cwd=str(AEGIS_ROOT))
        git_info['commit_date'] = result.stdout.strip() if result.returncode == 0 else 'unknown'
    except:
        git_info = {'commit': 'unknown', 'commit_date': 'unknown'}
    
    return jsonify({
        'version': SHELLDER_VERSION,
        'build': SHELLDER_BUILD,
        'git': git_info,
        'count': len(parsed),
        'logs': parsed,
        'log_path': get_log_path(),
        'uptime_seconds': time.time() - _start_time if '_start_time' in dir() else 0,
        'pid': os.getpid()
    })

@app.route('/api/debug/git-pull', methods=['POST'])
def api_debug_git_pull():
    """Pull latest code from GitHub - for AI live debugging"""
    info('DEBUG', '🔄 Git pull requested from dashboard')
    
    try:
        # Stash any local changes
        subprocess.run(['git', 'stash'], capture_output=True, cwd=str(AEGIS_ROOT), timeout=10)
        
        # Pull latest
        result = subprocess.run(['git', 'pull'], capture_output=True, text=True, 
                               cwd=str(AEGIS_ROOT), timeout=30)
        
        output = result.stdout + result.stderr
        success = result.returncode == 0
        
        # Get new commit info
        commit_result = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], 
                                       capture_output=True, text=True, cwd=str(AEGIS_ROOT))
        new_commit = commit_result.stdout.strip()
        
        # Check what files changed
        diff_result = subprocess.run(['git', 'diff', '--name-only', 'HEAD~1'], 
                                    capture_output=True, text=True, cwd=str(AEGIS_ROOT))
        changed_files = diff_result.stdout.strip().split('\n') if diff_result.stdout.strip() else []
        
        info('DEBUG', f'Git pull {"succeeded" if success else "failed"}', {
            'output': output[:500],
            'new_commit': new_commit,
            'changed_files': changed_files[:10]
        })
        
        return jsonify({
            'success': success,
            'output': output,
            'new_commit': new_commit,
            'changed_files': changed_files,
            'needs_restart': any('shellder_service.py' in f or 'script.js' in f for f in changed_files)
        })
    except Exception as e:
        error('DEBUG', f'Git pull failed: {e}')
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/debug/restart', methods=['POST'])
def api_debug_restart():
    """Restart the Shellder service - for AI live debugging"""
    info('DEBUG', '🔄 Service restart requested from dashboard')
    
    def delayed_restart():
        time.sleep(1)  # Give time for response to be sent
        info('DEBUG', 'Executing restart...')
        os.execv(sys.executable, [sys.executable] + sys.argv)
    
    # Start restart in background thread
    threading.Thread(target=delayed_restart, daemon=True).start()
    
    return jsonify({
        'success': True,
        'message': 'Service will restart in 1 second. Refresh page after a few seconds.'
    })

@app.route('/api/debug/pull-and-restart', methods=['POST'])
def api_debug_pull_and_restart():
    """Pull from GitHub and restart - one-click update for AI debugging"""
    info('DEBUG', '🚀 Pull and restart requested from dashboard')
    
    try:
        # First pull
        subprocess.run(['git', 'stash'], capture_output=True, cwd=str(AEGIS_ROOT), timeout=10)
        result = subprocess.run(['git', 'pull'], capture_output=True, text=True, 
                               cwd=str(AEGIS_ROOT), timeout=30)
        
        if result.returncode != 0:
            return jsonify({'success': False, 'error': 'Git pull failed', 'output': result.stderr})
        
        # Get commit info
        commit_result = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], 
                                       capture_output=True, text=True, cwd=str(AEGIS_ROOT))
        new_commit = commit_result.stdout.strip()
        
        info('DEBUG', f'Pull successful, restarting with commit {new_commit}')
        
        def delayed_restart():
            time.sleep(1)
            os.execv(sys.executable, [sys.executable] + sys.argv)
        
        threading.Thread(target=delayed_restart, daemon=True).start()
        
        return jsonify({
            'success': True,
            'new_commit': new_commit,
            'message': 'Pulled and restarting. Refresh page in 3-5 seconds.'
        })
    except Exception as e:
        error('DEBUG', f'Pull and restart failed: {e}')
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/debug/server-state')
def api_debug_server_state():
    """Get comprehensive server state for debugging"""
    return jsonify({
        'timestamp': datetime.now().isoformat(),
        'config': {
            'SHELLDER_PORT': SHELLDER_PORT,
            'AEGIS_ROOT': str(AEGIS_ROOT),
            'SHELLDER_DIR': str(SHELLDER_DIR),
            'DATA_DIR': str(DATA_DIR),
            'LOG_DIR': str(LOG_DIR),
            'LOCAL_MODE': LOCAL_MODE,
            'DOCKER_AVAILABLE': DOCKER_AVAILABLE,
            'PSUTIL_AVAILABLE': PSUTIL_AVAILABLE,
            'SOCKETIO_AVAILABLE': SOCKETIO_AVAILABLE,
            'ASYNC_MODE': ASYNC_MODE
        },
        'docker': {
            'client_connected': docker_client is not None,
            'version': docker_client.version() if docker_client else None
        },
        'paths': {
            'aegis_root_exists': AEGIS_ROOT.exists(),
            'shellder_dir_exists': SHELLDER_DIR.exists(),
            'data_dir_exists': DATA_DIR.exists(),
            'log_dir_exists': LOG_DIR.exists(),
            'templates_dir_exists': TEMPLATES_DIR.exists(),
            'static_dir_exists': STATIC_DIR.exists(),
            'shellder_db_exists': SHELLDER_DB.exists()
        },
        'stats_collector': {
            'running': stats_collector.running if stats_collector else False,
            'container_count': len(stats_collector.container_stats) if stats_collector else 0,
            'system_stats_keys': list(stats_collector.system_stats.keys()) if stats_collector else []
        },
        'device_monitor': {
            'running': device_monitor.running if device_monitor else False,
            'device_count': len(device_monitor.devices) if device_monitor else 0
        } if device_monitor else None,
        'flask': {
            'debug': app.debug,
            'testing': app.testing,
            'env': app.env if hasattr(app, 'env') else 'unknown'
        },
        'request_info': {
            'remote_addr': request.remote_addr,
            'user_agent': request.headers.get('User-Agent'),
            'host': request.host
        }
    })

@app.route('/api/debug/logs')
def api_debug_logs():
    """Get server-side logs"""
    lines = request.args.get('lines', 200, type=int)
    
    logs = {}
    
    # Main debug log (unified)
    debug_log = SHELLDER_DIR / 'debuglog.txt'
    if debug_log.exists():
        with open(debug_log, 'r', encoding='utf-8', errors='ignore') as f:
            logs['debuglog'] = f.read().split('\n')[-lines:]
    
    # Shellder log
    if SHELLDER_LOG.exists():
        with open(SHELLDER_LOG, 'r') as f:
            logs['shellder'] = f.read().split('\n')[-lines:]
    
    return jsonify(logs)

@app.route('/api/debug/debuglog')
def api_debug_debuglog():
    """Get the unified debuglog.txt content - main debug log for AI analysis"""
    lines = request.args.get('lines', 500, type=int)
    format_type = request.args.get('format', 'text')  # 'text' or 'json'
    
    # Use LOG_DIR which is the correct path for logs
    debug_log = LOG_DIR / 'debuglog.txt'
    
    if not debug_log.exists():
        # Create an empty log file if it doesn't exist
        try:
            LOG_DIR.mkdir(parents=True, exist_ok=True)
            debug_log.touch()
            # Fix ownership
            try:
                import pwd
                real_user = os.environ.get('SUDO_USER')
                if real_user:
                    user_info = pwd.getpwnam(real_user)
                    os.chown(debug_log, user_info.pw_uid, user_info.pw_gid)
            except:
                pass
        except Exception as e:
            return jsonify({'error': f'Could not create debuglog.txt: {e}', 'path': str(debug_log)}), 500
    
    try:
        with open(debug_log, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        
        log_lines = content.split('\n')
        
        if format_type == 'json':
            return jsonify({
                'path': str(debug_log),
                'total_lines': len(log_lines),
                'returned_lines': min(lines, len(log_lines)),
                'size_bytes': len(content),
                'lines': log_lines[-lines:]
            })
        else:
            # Return as plain text
            return Response(
                '\n'.join(log_lines[-lines:]),
                mimetype='text/plain'
            )
    except Exception as e:
        error('API', f'Failed to read debuglog: {e}', exc_info=True)
        return jsonify({'error': str(e)}), 500

@app.route('/api/debug/debuglog/download')
def api_debug_debuglog_download():
    """Download the full debuglog.txt file"""
    debug_log = LOG_DIR / 'debuglog.txt'
    
    if not debug_log.exists():
        return jsonify({'error': 'debuglog.txt not found', 'path': str(debug_log)}), 404
    
    info('API', 'Debug log download requested', {'client': request.remote_addr})
    return send_from_directory(
        LOG_DIR,
        'debuglog.txt',
        as_attachment=True,
        download_name=f'shellder-debug-{datetime.now().strftime("%Y%m%d-%H%M%S")}.txt'
    )

@app.route('/api/debug/recent')
def api_debug_recent():
    """Get recent logs from memory buffer (fast, no file read)"""
    count = request.args.get('count', 100, type=int)
    return jsonify({
        'count': count,
        'logs': get_recent_logs(count)
    })

@app.route('/api/debug/stream')
def api_debug_stream():
    """
    Live streaming debug log via Server-Sent Events (SSE).
    
    Usage: curl -N http://localhost:5050/api/debug/stream
    
    This streams all new log entries in real-time for AI debugging.
    """
    def generate():
        import time
        
        # Send initial connection message
        yield f"data: {{\"type\": \"connected\", \"time\": \"{datetime.now().isoformat()}\", \"port\": {SHELLDER_PORT}}}\n\n"
        
        # Track last position in log file
        debug_log = LOG_DIR / 'debuglog.txt'
        last_size = debug_log.stat().st_size if debug_log.exists() else 0
        last_lines_sent = 0
        
        # Send last 50 lines as context
        if debug_log.exists():
            try:
                with open(debug_log, 'r', encoding='utf-8', errors='ignore') as f:
                    lines = f.readlines()
                    for line in lines[-50:]:
                        yield f"data: {json.dumps({'type': 'log', 'line': line.rstrip()})}\n\n"
                    last_lines_sent = len(lines)
            except:
                pass
        
        yield f"data: {{\"type\": \"ready\", \"message\": \"Streaming live logs...\"}}\n\n"
        
        # Stream new entries
        while True:
            try:
                if debug_log.exists():
                    current_size = debug_log.stat().st_size
                    
                    if current_size > last_size:
                        with open(debug_log, 'r', encoding='utf-8', errors='ignore') as f:
                            lines = f.readlines()
                            # Send only new lines
                            new_lines = lines[last_lines_sent:]
                            for line in new_lines:
                                yield f"data: {json.dumps({'type': 'log', 'line': line.rstrip()})}\n\n"
                            last_lines_sent = len(lines)
                        last_size = current_size
                    elif current_size < last_size:
                        # File was truncated/rotated
                        last_size = 0
                        last_lines_sent = 0
                
                # Also stream from memory buffer (catches logs before file write)
                recent = get_recent_logs(5)
                # Heartbeat every 5 seconds
                yield f"data: {{\"type\": \"heartbeat\", \"time\": \"{datetime.now().isoformat()}\"}}\n\n"
                
                time.sleep(1)  # Check every second
                
            except GeneratorExit:
                break
            except Exception as e:
                yield f"data: {{\"type\": \"error\", \"message\": \"{str(e)}\"}}\n\n"
                time.sleep(5)
    
    return Response(
        generate(),
        mimetype='text/event-stream',
        headers={
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
            'X-Accel-Buffering': 'no'
        }
    )

@app.route('/api/debug/tail')
def api_debug_tail():
    """
    Simple plain-text tail of debug log (like tail -f).
    
    Usage: curl -N http://localhost:5050/api/debug/tail
    
    Streams raw log lines without JSON wrapping.
    """
    def generate():
        import time
        
        debug_log = LOG_DIR / 'debuglog.txt'
        last_lines_sent = 0
        
        yield f"=== Shellder Debug Stream @ {datetime.now().isoformat()} ===\n"
        yield f"=== Port: {SHELLDER_PORT} | Log: {debug_log} ===\n\n"
        
        # Send last 100 lines as context
        if debug_log.exists():
            try:
                with open(debug_log, 'r', encoding='utf-8', errors='ignore') as f:
                    lines = f.readlines()
                    for line in lines[-100:]:
                        yield line
                    last_lines_sent = len(lines)
            except:
                pass
        
        yield "\n=== LIVE STREAM STARTED ===\n\n"
        
        while True:
            try:
                if debug_log.exists():
                    with open(debug_log, 'r', encoding='utf-8', errors='ignore') as f:
                        lines = f.readlines()
                        if len(lines) > last_lines_sent:
                            for line in lines[last_lines_sent:]:
                                yield line
                            last_lines_sent = len(lines)
                        elif len(lines) < last_lines_sent:
                            # File rotated
                            last_lines_sent = 0
                
                time.sleep(0.5)
                
            except GeneratorExit:
                break
            except:
                time.sleep(2)
    
    return Response(
        generate(),
        mimetype='text/plain',
        headers={
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
            'X-Accel-Buffering': 'no'
        }
    )

@app.route('/api/debug/clear', methods=['POST'])
def api_debug_clear():
    """Clear debug logs"""
    global client_debug_logs
    client_debug_logs = []
    
    # Clear client debug log file
    client_log = LOG_DIR / 'client_debug.json'
    if client_log.exists():
        client_log.unlink()
    
    # Clear the main debuglog.txt
    debug_log = LOG_DIR / 'debuglog.txt'
    if debug_log.exists():
        try:
            with open(debug_log, 'w') as f:
                f.write(f"=== Log cleared at {datetime.now().isoformat()} ===\n")
            # Fix ownership
            try:
                import pwd
                real_user = os.environ.get('SUDO_USER')
                if real_user:
                    user_info = pwd.getpwnam(real_user)
                    os.chown(debug_log, user_info.pw_uid, user_info.pw_gid)
            except:
                pass
        except Exception as e:
            return jsonify({'success': False, 'error': f'Failed to clear log: {e}'}), 500
    
    # Also call the debug_logger clear function if available
    try:
        clear_log()
    except:
        pass
    
    return jsonify({'success': True, 'message': 'Debug logs cleared'})

# =============================================================================
# AI DEBUG ACCESS - Comprehensive API for AI Assistants
# =============================================================================

# Feature flags - can be toggled from UI
AI_DEBUG_CONFIG = {
    'api_enabled': True,
    'websocket_enabled': True,
    'file_access': True,
    'command_exec': True,
    'docker_access': True,
    'database_access': True,
    'system_info': True
}

@app.route('/api/ai-debug/config')
def api_ai_debug_config():
    """Get AI debug access configuration"""
    return jsonify({
        'config': AI_DEBUG_CONFIG,
        'endpoints': {
            'file_read': '/api/ai-debug/file?path=<path>',
            'file_write': '/api/ai-debug/file (POST)',
            'exec': '/api/ai-debug/exec (POST)',
            'docker': '/api/ai-debug/docker?cmd=<cmd>',
            'sql': '/api/ai-debug/sql (POST)',
            'logs': '/api/ai-debug/logs?type=<type>',
            'diagnose': '/api/ai-debug/diagnose',
            'system': '/api/ai-debug/system',
            'websocket': f'ws://localhost:{SHELLDER_PORT}/ai-debug'
        },
        'port': SHELLDER_PORT,
        'aegis_root': str(AEGIS_ROOT)
    })

@app.route('/api/ai-debug/config', methods=['POST'])
def api_ai_debug_config_update():
    """Update AI debug access configuration"""
    global AI_DEBUG_CONFIG
    data = request.get_json() or {}
    
    for key in data:
        if key in AI_DEBUG_CONFIG:
            AI_DEBUG_CONFIG[key] = bool(data[key])
    
    return jsonify({'success': True, 'config': AI_DEBUG_CONFIG})

@app.route('/api/ai-debug/file')
def api_ai_debug_file_read():
    """
    Read any file in the Aegis directory.
    
    Usage: GET /api/ai-debug/file?path=Shellder/shellder_service.py&lines=100
    
    Parameters:
        path: Relative path from Aegis root
        lines: Optional, limit to last N lines
        offset: Optional, start from line N
    """
    if not AI_DEBUG_CONFIG.get('file_access'):
        return jsonify({'error': 'File access disabled'}), 403
    
    path = request.args.get('path', '')
    lines_limit = request.args.get('lines', type=int)
    offset = request.args.get('offset', 0, type=int)
    
    if not path:
        return jsonify({'error': 'Path required'}), 400
    
    full_path = AEGIS_ROOT / path
    
    # Security: must be within Aegis root
    try:
        full_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'error': 'Access denied - path outside Aegis directory'}), 403
    
    if not full_path.exists():
        return jsonify({'error': f'File not found: {path}'}), 404
    
    if full_path.is_dir():
        # List directory
        files = []
        for f in full_path.iterdir():
            files.append({
                'name': f.name,
                'type': 'dir' if f.is_dir() else 'file',
                'size': f.stat().st_size if f.is_file() else None
            })
        return jsonify({'type': 'directory', 'path': path, 'files': files})
    
    try:
        with open(full_path, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read()
        
        lines = content.split('\n')
        total_lines = len(lines)
        
        if offset > 0:
            lines = lines[offset:]
        if lines_limit:
            lines = lines[:lines_limit]
        
        return jsonify({
            'type': 'file',
            'path': path,
            'total_lines': total_lines,
            'returned_lines': len(lines),
            'offset': offset,
            'content': '\n'.join(lines),
            'size_bytes': full_path.stat().st_size
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/ai-debug/file', methods=['POST'])
def api_ai_debug_file_write():
    """
    Write to a file in the Aegis directory.
    
    Usage: POST /api/ai-debug/file
    Body: {"path": "path/to/file", "content": "file content", "append": false}
    """
    if not AI_DEBUG_CONFIG.get('file_access'):
        return jsonify({'error': 'File access disabled'}), 403
    
    data = request.get_json() or {}
    path = data.get('path', '')
    content = data.get('content', '')
    append = data.get('append', False)
    
    if not path:
        return jsonify({'error': 'Path required'}), 400
    
    full_path = AEGIS_ROOT / path
    
    # Security check
    try:
        full_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'error': 'Access denied'}), 403
    
    try:
        mode = 'a' if append else 'w'
        with open(full_path, mode, encoding='utf-8') as f:
            f.write(content)
        
        # Fix ownership
        try:
            import pwd
            real_user = os.environ.get('SUDO_USER')
            if real_user:
                user_info = pwd.getpwnam(real_user)
                os.chown(full_path, user_info.pw_uid, user_info.pw_gid)
        except:
            pass
        
        return jsonify({'success': True, 'path': path, 'bytes_written': len(content)})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/ai-debug/exec', methods=['POST'])
def api_ai_debug_exec():
    """
    Execute a shell command.
    
    Usage: POST /api/ai-debug/exec
    Body: {"cmd": "docker ps", "timeout": 30, "cwd": "optional/path"}
    
    Returns stdout, stderr, and return code.
    """
    if not AI_DEBUG_CONFIG.get('command_exec'):
        return jsonify({'error': 'Command execution disabled'}), 403
    
    data = request.get_json() or {}
    cmd = data.get('cmd', '')
    timeout = data.get('timeout', 30)
    cwd = data.get('cwd', str(AEGIS_ROOT))
    
    if not cmd:
        return jsonify({'error': 'Command required'}), 400
    
    # Security: block dangerous commands
    dangerous = ['rm -rf /', 'mkfs', 'dd if=', ':(){', 'chmod -R 777 /']
    for d in dangerous:
        if d in cmd:
            return jsonify({'error': f'Blocked dangerous command pattern: {d}'}), 403
    
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=cwd
        )
        
        return jsonify({
            'success': result.returncode == 0,
            'command': cmd,
            'returncode': result.returncode,
            'stdout': result.stdout,
            'stderr': result.stderr,
            'cwd': cwd
        })
    except subprocess.TimeoutExpired:
        return jsonify({'error': f'Command timed out after {timeout}s'}), 408
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/ai-debug/docker')
def api_ai_debug_docker():
    """
    Docker operations.
    
    Usage: GET /api/ai-debug/docker?cmd=ps
    
    Commands: ps, images, logs, inspect, stats
    """
    if not AI_DEBUG_CONFIG.get('docker_access'):
        return jsonify({'error': 'Docker access disabled'}), 403
    
    cmd = request.args.get('cmd', 'ps')
    container = request.args.get('container', '')
    lines = request.args.get('lines', 100, type=int)
    
    try:
        if cmd == 'ps':
            result = subprocess.run(
                ['docker', 'compose', 'ps', '--format', 'json'],
                capture_output=True, text=True, cwd=str(AEGIS_ROOT), timeout=30
            )
            try:
                containers = [json.loads(line) for line in result.stdout.strip().split('\n') if line]
            except:
                containers = result.stdout
            return jsonify({'containers': containers})
        
        elif cmd == 'logs' and container:
            result = subprocess.run(
                ['docker', 'logs', '--tail', str(lines), container],
                capture_output=True, text=True, timeout=30
            )
            return jsonify({
                'container': container,
                'logs': result.stdout + result.stderr,
                'lines': lines
            })
        
        elif cmd == 'inspect' and container:
            result = subprocess.run(
                ['docker', 'inspect', container],
                capture_output=True, text=True, timeout=30
            )
            try:
                data = json.loads(result.stdout)
            except:
                data = result.stdout
            return jsonify({'container': container, 'inspect': data})
        
        elif cmd == 'stats':
            result = subprocess.run(
                ['docker', 'stats', '--no-stream', '--format', 
                 '{"name":"{{.Name}}","cpu":"{{.CPUPerc}}","mem":"{{.MemUsage}}","net":"{{.NetIO}}"}'],
                capture_output=True, text=True, timeout=30
            )
            try:
                stats = [json.loads(line) for line in result.stdout.strip().split('\n') if line]
            except:
                stats = result.stdout
            return jsonify({'stats': stats})
        
        elif cmd == 'images':
            result = subprocess.run(
                ['docker', 'images', '--format', '{{.Repository}}:{{.Tag}} {{.Size}}'],
                capture_output=True, text=True, timeout=30
            )
            return jsonify({'images': result.stdout.strip().split('\n')})
        
        else:
            return jsonify({'error': f'Unknown command: {cmd}. Use: ps, logs, inspect, stats, images'}), 400
            
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/ai-debug/sql', methods=['POST'])
def api_ai_debug_sql():
    """
    Execute SQL query on databases.
    
    Usage: POST /api/ai-debug/sql
    Body: {"database": "golbat", "query": "SELECT * FROM pokemon LIMIT 10"}
    
    Databases: golbat, dragonite, reactmap, koji
    """
    if not AI_DEBUG_CONFIG.get('database_access'):
        return jsonify({'error': 'Database access disabled'}), 403
    
    data = request.get_json() or {}
    database = data.get('database', 'golbat')
    query = data.get('query', '')
    
    if not query:
        return jsonify({'error': 'Query required'}), 400
    
    # Block dangerous queries
    dangerous = ['DROP ', 'DELETE ', 'TRUNCATE ', 'ALTER ', 'UPDATE ', 'INSERT ']
    query_upper = query.upper()
    for d in dangerous:
        if d in query_upper and 'SELECT' not in query_upper:
            return jsonify({'error': f'Blocked dangerous query: {d}'}), 403
    
    try:
        # Read database credentials from .env
        env_path = AEGIS_ROOT / '.env'
        db_user = 'pokemon'
        db_pass = ''
        
        if env_path.exists():
            with open(env_path, 'r') as f:
                for line in f:
                    if line.startswith('MYSQL_USER='):
                        db_user = line.split('=', 1)[1].strip().strip('"\'')
                    elif line.startswith('MYSQL_PASSWORD='):
                        db_pass = line.split('=', 1)[1].strip().strip('"\'')
        
        # Execute via mysql CLI
        cmd = ['mysql', '-h', '127.0.0.1', '-u', db_user, f'-p{db_pass}', 
               database, '-e', query, '--batch', '--silent']
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        
        if result.returncode != 0:
            return jsonify({'error': result.stderr, 'database': database}), 500
        
        # Parse results
        lines = result.stdout.strip().split('\n')
        if len(lines) > 0:
            headers = lines[0].split('\t') if lines else []
            rows = [dict(zip(headers, line.split('\t'))) for line in lines[1:]] if len(lines) > 1 else []
            return jsonify({
                'database': database,
                'query': query,
                'columns': headers,
                'rows': rows,
                'row_count': len(rows)
            })
        return jsonify({'database': database, 'query': query, 'rows': [], 'row_count': 0})
        
    except subprocess.TimeoutExpired:
        return jsonify({'error': 'Query timed out'}), 408
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/ai-debug/logs')
def api_ai_debug_logs():
    """
    Get various system logs.
    
    Usage: GET /api/ai-debug/logs?type=shellder&lines=100
    
    Types: shellder, docker, nginx, system, auth, container
    For container logs, add &container=<name>
    """
    if not AI_DEBUG_CONFIG.get('system_info'):
        return jsonify({'error': 'System info access disabled'}), 403
    
    log_type = request.args.get('type', 'shellder')
    lines = request.args.get('lines', 100, type=int)
    container = request.args.get('container', '')
    
    try:
        if log_type == 'shellder':
            log_path = LOG_DIR / 'debuglog.txt'
            if log_path.exists():
                with open(log_path, 'r', errors='replace') as f:
                    content = f.readlines()[-lines:]
                return jsonify({'type': 'shellder', 'lines': content})
        
        elif log_type == 'docker':
            result = subprocess.run(
                ['journalctl', '-u', 'docker', '-n', str(lines), '--no-pager'],
                capture_output=True, text=True, timeout=30
            )
            return jsonify({'type': 'docker', 'lines': result.stdout.split('\n')})
        
        elif log_type == 'nginx':
            nginx_log = Path('/var/log/nginx/error.log')
            if nginx_log.exists():
                result = subprocess.run(['sudo', 'tail', '-n', str(lines), str(nginx_log)],
                                       capture_output=True, text=True, timeout=10)
                return jsonify({'type': 'nginx', 'lines': result.stdout.split('\n')})
        
        elif log_type == 'system':
            result = subprocess.run(
                ['journalctl', '-n', str(lines), '--no-pager', '-p', 'err'],
                capture_output=True, text=True, timeout=30
            )
            return jsonify({'type': 'system', 'lines': result.stdout.split('\n')})
        
        elif log_type == 'container' and container:
            result = subprocess.run(
                ['docker', 'logs', '--tail', str(lines), container],
                capture_output=True, text=True, timeout=30
            )
            return jsonify({
                'type': 'container',
                'container': container,
                'lines': (result.stdout + result.stderr).split('\n')
            })
        
        return jsonify({'error': f'Unknown log type: {log_type}'}), 400
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/ai-debug/diagnose')
def api_ai_debug_diagnose():
    """
    Run comprehensive system diagnostics.
    
    Usage: GET /api/ai-debug/diagnose
    
    Returns system state, container status, port availability, service health.
    """
    if not AI_DEBUG_CONFIG.get('system_info'):
        return jsonify({'error': 'System info access disabled'}), 403
    
    diagnostics = {
        'timestamp': datetime.now().isoformat(),
        'system': {},
        'containers': [],
        'ports': {},
        'services': {},
        'databases': {},
        'files': {}
    }
    
    try:
        # System info
        import psutil
        diagnostics['system'] = {
            'cpu_percent': psutil.cpu_percent(),
            'memory_percent': psutil.virtual_memory().percent,
            'disk_percent': psutil.disk_usage('/').percent,
            'uptime_seconds': time.time() - psutil.boot_time()
        }
    except:
        pass
    
    try:
        # Containers
        result = subprocess.run(
            ['docker', 'compose', 'ps', '--format', 'json'],
            capture_output=True, text=True, cwd=str(AEGIS_ROOT), timeout=30
        )
        for line in result.stdout.strip().split('\n'):
            if line:
                try:
                    diagnostics['containers'].append(json.loads(line))
                except:
                    pass
    except:
        pass
    
    try:
        # Key ports
        import socket
        for name, port in [('Shellder', SHELLDER_PORT), ('MariaDB', 3306), ('Rotom', 7070), ('Dragonite', 7272)]:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(1)
            result = sock.connect_ex(('127.0.0.1', port))
            diagnostics['ports'][name] = {'port': port, 'open': result == 0}
            sock.close()
    except:
        pass
    
    try:
        # Key files
        key_files = ['.env', 'docker-compose.yaml', 'unown/dragonite_config.toml', 'unown/golbat_config.toml']
        for f in key_files:
            path = AEGIS_ROOT / f
            diagnostics['files'][f] = {
                'exists': path.exists(),
                'size': path.stat().st_size if path.exists() else 0
            }
    except:
        pass
    
    return jsonify(diagnostics)

@app.route('/api/ai-debug/system')
def api_ai_debug_system():
    """
    Get detailed system information.
    
    Usage: GET /api/ai-debug/system
    """
    if not AI_DEBUG_CONFIG.get('system_info'):
        return jsonify({'error': 'System info access disabled'}), 403
    
    info = {
        'hostname': socket.gethostname(),
        'platform': platform.platform(),
        'python': platform.python_version(),
        'aegis_root': str(AEGIS_ROOT),
        'shellder_port': SHELLDER_PORT,
        'cwd': os.getcwd()
    }
    
    try:
        import psutil
        info['cpu'] = {
            'count': psutil.cpu_count(),
            'percent': psutil.cpu_percent(interval=0.1),
            'freq': psutil.cpu_freq()._asdict() if psutil.cpu_freq() else None
        }
        info['memory'] = psutil.virtual_memory()._asdict()
        info['disk'] = psutil.disk_usage('/')._asdict()
    except:
        pass
    
    try:
        # Git info
        result = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'],
                               capture_output=True, text=True, cwd=str(AEGIS_ROOT), timeout=5)
        info['git_commit'] = result.stdout.strip() if result.returncode == 0 else None
        
        result = subprocess.run(['git', 'branch', '--show-current'],
                               capture_output=True, text=True, cwd=str(AEGIS_ROOT), timeout=5)
        info['git_branch'] = result.stdout.strip() if result.returncode == 0 else None
    except:
        pass
    
    return jsonify(info)

@app.route('/api/ai-debug/help')
def api_ai_debug_help():
    """
    Get help documentation for AI assistants.
    
    This endpoint provides complete documentation on how to use the AI debug API.
    """
    return jsonify({
        'title': 'Shellder AI Debug API',
        'description': 'Comprehensive API for AI assistants to debug Aegis AIO',
        'base_url': f'http://localhost:{SHELLDER_PORT}',
        'authentication': 'None required (local access only)',
        'endpoints': [
            {
                'method': 'GET',
                'path': '/api/ai-debug/config',
                'description': 'Get current configuration and available endpoints'
            },
            {
                'method': 'GET',
                'path': '/api/ai-debug/file?path=<path>',
                'description': 'Read file contents. Add &lines=N to limit lines.',
                'example': 'curl "http://localhost:5050/api/ai-debug/file?path=.env"'
            },
            {
                'method': 'POST',
                'path': '/api/ai-debug/file',
                'description': 'Write to file. Body: {"path": "...", "content": "..."}',
                'example': 'curl -X POST -H "Content-Type: application/json" -d \'{"path":"test.txt","content":"hello"}\' http://localhost:5050/api/ai-debug/file'
            },
            {
                'method': 'POST',
                'path': '/api/ai-debug/exec',
                'description': 'Execute shell command. Body: {"cmd": "..."}',
                'example': 'curl -X POST -H "Content-Type: application/json" -d \'{"cmd":"docker ps"}\' http://localhost:5050/api/ai-debug/exec'
            },
            {
                'method': 'GET',
                'path': '/api/ai-debug/docker?cmd=<cmd>',
                'description': 'Docker operations. Commands: ps, logs, inspect, stats, images',
                'example': 'curl "http://localhost:5050/api/ai-debug/docker?cmd=ps"'
            },
            {
                'method': 'POST',
                'path': '/api/ai-debug/sql',
                'description': 'Execute SQL query. Body: {"database": "golbat", "query": "SELECT..."}',
                'example': 'curl -X POST -H "Content-Type: application/json" -d \'{"database":"golbat","query":"SHOW TABLES"}\' http://localhost:5050/api/ai-debug/sql'
            },
            {
                'method': 'GET',
                'path': '/api/ai-debug/logs?type=<type>',
                'description': 'Get logs. Types: shellder, docker, nginx, system, container',
                'example': 'curl "http://localhost:5050/api/ai-debug/logs?type=shellder&lines=50"'
            },
            {
                'method': 'GET',
                'path': '/api/ai-debug/diagnose',
                'description': 'Run comprehensive system diagnostics',
                'example': 'curl http://localhost:5050/api/ai-debug/diagnose'
            },
            {
                'method': 'GET',
                'path': '/api/ai-debug/system',
                'description': 'Get detailed system information',
                'example': 'curl http://localhost:5050/api/ai-debug/system'
            },
            {
                'method': 'GET',
                'path': '/api/debug/stream',
                'description': 'SSE stream of live debug logs',
                'example': 'curl -N http://localhost:5050/api/debug/stream'
            },
            {
                'method': 'GET',
                'path': '/api/debug/tail',
                'description': 'Plain text stream of live logs',
                'example': 'curl -N http://localhost:5050/api/debug/tail'
            }
        ],
        'websocket': {
            'url': f'ws://localhost:{SHELLDER_PORT}/socket.io/',
            'namespace': '/ai-debug',
            'events': ['execute', 'file_read', 'file_write', 'docker', 'sql', 'diagnose']
        },
        'tips': [
            'Use /api/ai-debug/diagnose first to understand system state',
            'Check /api/ai-debug/logs?type=shellder for recent errors',
            'Use /api/debug/tail for live log streaming',
            'All file paths are relative to Aegis root directory'
        ]
    })

@app.route('/api/health')
def health():
    """Health check endpoint"""
    return jsonify({
        'status': 'healthy',
        'timestamp': datetime.now().isoformat(),
        'docker': docker_client is not None,
        'websocket': SOCKETIO_AVAILABLE,
        'version': '1.0'
    })

def get_mock_status():
    """Return mock/demo data for local testing without Docker"""
    mock_containers = [
        {'name': 'rotom', 'status': 'running', 'cpu': '2.1%', 'memory': '156MB', 'uptime': '2d 14h'},
        {'name': 'dragonite', 'status': 'running', 'cpu': '15.3%', 'memory': '512MB', 'uptime': '2d 14h'},
        {'name': 'golbat', 'status': 'running', 'cpu': '8.7%', 'memory': '384MB', 'uptime': '2d 14h'},
        {'name': 'reactmap', 'status': 'running', 'cpu': '3.2%', 'memory': '256MB', 'uptime': '2d 14h'},
        {'name': 'koji', 'status': 'running', 'cpu': '1.8%', 'memory': '128MB', 'uptime': '2d 14h'},
        {'name': 'database', 'status': 'running', 'cpu': '5.4%', 'memory': '1.2GB', 'uptime': '2d 14h'},
        {'name': 'grafana', 'status': 'stopped', 'cpu': '0%', 'memory': '0MB', 'uptime': '-'},
        {'name': 'xilriws', 'status': 'running', 'cpu': '0.5%', 'memory': '64MB', 'uptime': '2d 14h'},
    ]
    
    return {
        'containers': {
            'total': len(mock_containers),
            'running': sum(1 for c in mock_containers if c['status'] == 'running'),
            'stopped': sum(1 for c in mock_containers if c['status'] != 'running'),
            'list': mock_containers
        },
        'system': {
            'cpu_percent': 23.5,
            'memory': {'total': '32GB', 'used': '12.4GB', 'free': '19.6GB', 'percent': '39%'},
            'disk': {'total': '500GB', 'used': '125GB', 'free': '375GB', 'percent': '25%'},
            'uptime': '14 days, 6:32:15'
        },
        'env_configured': True,
        'xilriws': {
            'status': 'running',
            'auth_requests': 1247,
            'success_rate': '98.5%',
            'active_sessions': 42
        },
        'ports': {
            '5090': {'status': 'open', 'service': 'Rotom'},
            '7070': {'status': 'open', 'service': 'Rotom WS'},
            '6001': {'status': 'open', 'service': 'ReactMap'},
            '6002': {'status': 'open', 'service': 'Koji'},
        },
        'services': {},
        'timestamp': datetime.now().isoformat(),
        'local_mode': True,
        'message': '⚠️ Running in LOCAL MODE - showing demo data (Docker not connected)'
    }

@app.route('/api/status')
def api_status():
    """Get overall system status"""
    debug('API', '/api/status called', {
        'local_mode': LOCAL_MODE,
        'docker_client': docker_client is not None,
        'remote_addr': request.remote_addr
    })
    
    # Check if we should return mock data (local testing mode or Docker not available)
    if LOCAL_MODE or docker_client is None:
        debug('API', 'Returning mock status (LOCAL_MODE or no Docker)')
        return jsonify(get_mock_status())
    
    stats = stats_collector.get_all_stats()
    
    containers = []
    running = 0
    stopped = 0
    
    for name, info in stats.get('containers', {}).items():
        containers.append(info)
        if info.get('status') == 'running':
            running += 1
        else:
            stopped += 1
    
    # System info
    system = stats.get('system', {})
    system_formatted = {}
    if system:
        mem = system.get('memory', {})
        disk = system.get('disk', {})
        system_formatted = {
            'cpu_percent': system.get('cpu_percent', 0),  # Include CPU!
            'memory': {
                'total': format_bytes(mem.get('total', 0)),
                'used': format_bytes(mem.get('used', 0)),
                'free': format_bytes(mem.get('available', 0)),
                'percent': f"{mem.get('percent', 0)}%"
            },
            'disk': {
                'total': format_bytes(disk.get('total', 0)),
                'used': format_bytes(disk.get('used', 0)),
                'free': format_bytes(disk.get('free', 0)),
                'percent': f"{disk.get('percent', 0)}%"
            },
            'uptime': str(timedelta(seconds=int(system.get('uptime', 0))))
        }
    
    return jsonify({
        'version': SHELLDER_VERSION,
        'build': SHELLDER_BUILD,
        'containers': {
            'total': len(containers),
            'running': running,
            'stopped': stopped,
            'list': containers
        },
        'system': system_formatted,
        'env_configured': (AEGIS_ROOT / '.env').exists(),
        'xilriws': stats.get('xilriws', {}),
        'ports': stats.get('ports', {}),
        'services': stats.get('services', {}),
        'timestamp': datetime.now().isoformat()
    })

# =============================================================================
# DISK HEALTH MONITORING
# =============================================================================
# Known bloat sources that can safely be cleaned
KNOWN_BLOAT_SOURCES = [
    {
        'id': 'gnome_tracker',
        'name': 'GNOME Tracker Cache',
        'description': 'File indexing cache that can grow uncontrollably',
        'paths': [
            '~/.cache/tracker3/',
            '~/.cache/tracker/',
        ],
        'cleanup_commands': [
            'tracker3 daemon -k 2>/dev/null || true',
            'systemctl --user stop tracker-miner-fs-3 2>/dev/null || true',
            'systemctl --user stop tracker-extract-3 2>/dev/null || true',
            'rm -rf ~/.cache/tracker3/',
            'rm -rf ~/.cache/tracker/',
        ],
        'disable_commands': [
            'systemctl --user mask tracker-miner-fs-3 2>/dev/null || true',
            'systemctl --user mask tracker-extract-3 2>/dev/null || true',
        ],
        'safe': True,
        'severity': 'high',
    },
    {
        'id': 'systemd_journal',
        'name': 'Systemd Journal Logs',
        'description': 'System logs that can grow very large',
        'paths': ['/var/log/journal/'],
        'cleanup_commands': ['sudo journalctl --vacuum-size=500M'],
        'safe': True,
        'severity': 'medium',
    },
    {
        'id': 'apt_cache',
        'name': 'APT Package Cache',
        'description': 'Downloaded package files',
        'paths': ['/var/cache/apt/archives/'],
        'cleanup_commands': ['sudo apt-get clean'],
        'safe': True,
        'severity': 'low',
    },
    {
        'id': 'docker_unused',
        'name': 'Docker Unused Data',
        'description': 'Unused containers, images, networks, and volumes',
        'paths': ['/var/lib/docker/'],
        'cleanup_commands': ['docker system prune -af --volumes'],
        'safe': False,  # Requires confirmation
        'severity': 'medium',
    },
    {
        'id': 'thumbnail_cache',
        'name': 'Thumbnail Cache',
        'description': 'Cached image thumbnails',
        'paths': ['~/.cache/thumbnails/'],
        'cleanup_commands': ['rm -rf ~/.cache/thumbnails/*'],
        'safe': True,
        'severity': 'low',
    },
    {
        'id': 'trash',
        'name': 'Trash',
        'description': 'Deleted files in trash',
        'paths': ['~/.local/share/Trash/'],
        'cleanup_commands': ['rm -rf ~/.local/share/Trash/*'],
        'safe': True,
        'severity': 'medium',
    },
    {
        'id': 'npm_cache',
        'name': 'NPM Cache',
        'description': 'Node.js package manager cache',
        'paths': ['~/.npm/_cacache/'],
        'cleanup_commands': ['npm cache clean --force'],
        'safe': True,
        'severity': 'low',
    },
    {
        'id': 'pip_cache',
        'name': 'PIP Cache',
        'description': 'Python package manager cache',
        'paths': ['~/.cache/pip/'],
        'cleanup_commands': ['pip cache purge'],
        'safe': True,
        'severity': 'low',
    },
]

# Disk usage thresholds
DISK_THRESHOLD_WARNING = 70  # Yellow warning
DISK_THRESHOLD_CRITICAL = 85  # Red critical
DISK_THRESHOLD_EMERGENCY = 95  # Emergency - system may become unstable

# Track disk usage history for growth detection
_disk_history = []
_disk_history_max = 60  # Keep 60 samples (1 hour at 1 min intervals)

def _get_disk_usage():
    """Get current disk usage"""
    if not PSUTIL_AVAILABLE:
        return None
    try:
        usage = psutil.disk_usage('/')
        return {
            'total': usage.total,
            'used': usage.used,
            'free': usage.free,
            'percent': usage.percent
        }
    except Exception as e:
        error('DISK', f'Failed to get disk usage: {e}')
        return None

def _expand_path(path):
    """Expand ~ in path to actual home directory"""
    if path.startswith('~'):
        # Try to find the main user's home (not root)
        home_dir = None
        try:
            # Get the home directory of the user running the service
            import pwd
            # Look for common non-root users
            for user in ['pokemap', 'aegis', 'ubuntu', 'admin']:
                try:
                    pw = pwd.getpwnam(user)
                    home_dir = pw.pw_dir
                    break
                except KeyError:
                    continue
            # Fall back to current user's home
            if not home_dir:
                home_dir = os.path.expanduser('~')
        except:
            home_dir = os.path.expanduser('~')
        return path.replace('~', home_dir, 1)
    return path

def _get_dir_size(path):
    """Get total size of a directory"""
    expanded_path = _expand_path(path)
    if not os.path.exists(expanded_path):
        return 0
    
    total = 0
    try:
        for dirpath, dirnames, filenames in os.walk(expanded_path):
            for filename in filenames:
                filepath = os.path.join(dirpath, filename)
                try:
                    total += os.path.getsize(filepath)
                except (OSError, FileNotFoundError):
                    pass
    except PermissionError:
        # Try using du command as fallback
        try:
            result = subprocess.run(
                ['du', '-sb', expanded_path],
                capture_output=True,
                text=True,
                timeout=30
            )
            if result.returncode == 0:
                total = int(result.stdout.split()[0])
        except:
            pass
    return total

def _find_large_files(min_size_mb=100, max_results=20):
    """Find large files on the system"""
    large_files = []
    min_size_bytes = min_size_mb * 1024 * 1024
    
    # Directories to search
    search_dirs = ['/home', '/var', '/tmp', '/root']
    # Directories to skip
    skip_dirs = {'/proc', '/sys', '/dev', '/run', '/snap'}
    
    for search_dir in search_dirs:
        if not os.path.exists(search_dir):
            continue
        
        try:
            for dirpath, dirnames, filenames in os.walk(search_dir):
                # Skip certain directories
                if any(dirpath.startswith(skip) for skip in skip_dirs):
                    continue
                
                # Don't descend into certain directories
                dirnames[:] = [d for d in dirnames if d not in ['.git', 'node_modules', '__pycache__']]
                
                for filename in filenames:
                    filepath = os.path.join(dirpath, filename)
                    try:
                        size = os.path.getsize(filepath)
                        if size >= min_size_bytes:
                            large_files.append({
                                'path': filepath,
                                'size': size,
                                'size_human': format_bytes(size),
                                'modified': datetime.fromtimestamp(os.path.getmtime(filepath)).isoformat()
                            })
                    except (OSError, FileNotFoundError):
                        pass
        except PermissionError:
            continue
    
    # Sort by size descending
    large_files.sort(key=lambda x: x['size'], reverse=True)
    return large_files[:max_results]

def _detect_bloat():
    """Detect known bloat sources and their sizes"""
    detected = []
    
    for source in KNOWN_BLOAT_SOURCES:
        total_size = 0
        found_paths = []
        
        for path in source['paths']:
            expanded = _expand_path(path)
            if os.path.exists(expanded):
                size = _get_dir_size(path)
                if size > 0:
                    total_size += size
                    found_paths.append({
                        'path': expanded,
                        'size': size,
                        'size_human': format_bytes(size)
                    })
        
        if total_size > 0:
            detected.append({
                'id': source['id'],
                'name': source['name'],
                'description': source['description'],
                'total_size': total_size,
                'total_size_human': format_bytes(total_size),
                'paths': found_paths,
                'safe': source['safe'],
                'severity': source['severity'],
                'cleanup_commands': source['cleanup_commands'],
            })
    
    # Sort by size descending
    detected.sort(key=lambda x: x['total_size'], reverse=True)
    return detected

@app.route('/api/disk/health')
def api_disk_health():
    """Get disk health status with alerts"""
    usage = _get_disk_usage()
    if not usage:
        return jsonify({'error': 'Could not get disk usage'}), 500
    
    # Determine status
    percent = usage['percent']
    if percent >= DISK_THRESHOLD_EMERGENCY:
        status = 'emergency'
        message = '🚨 EMERGENCY: Disk almost full! System may become unstable.'
    elif percent >= DISK_THRESHOLD_CRITICAL:
        status = 'critical'
        message = '🔴 CRITICAL: Disk usage very high. Clean up immediately!'
    elif percent >= DISK_THRESHOLD_WARNING:
        status = 'warning'
        message = '⚠️ WARNING: Disk usage elevated. Consider cleaning up.'
    else:
        status = 'healthy'
        message = '✅ Disk usage is healthy.'
    
    # Check for rapid growth
    growth_warning = None
    if len(_disk_history) >= 2:
        oldest = _disk_history[0]
        newest = _disk_history[-1]
        time_diff = (newest['time'] - oldest['time']).total_seconds() / 3600  # hours
        if time_diff > 0:
            size_diff = newest['used'] - oldest['used']
            growth_rate = size_diff / time_diff  # bytes per hour
            if growth_rate > 1024 * 1024 * 100:  # > 100MB/hour
                growth_warning = {
                    'rate': growth_rate,
                    'rate_human': f"{format_bytes(growth_rate)}/hour",
                    'message': f"⚠️ Disk growing at {format_bytes(growth_rate)}/hour!"
                }
    
    # Record current usage
    _disk_history.append({
        'time': datetime.now(),
        'used': usage['used'],
        'percent': usage['percent']
    })
    if len(_disk_history) > _disk_history_max:
        _disk_history.pop(0)
    
    return jsonify({
        'status': status,
        'message': message,
        'usage': {
            'total': format_bytes(usage['total']),
            'used': format_bytes(usage['used']),
            'free': format_bytes(usage['free']),
            'percent': usage['percent'],
            'total_bytes': usage['total'],
            'used_bytes': usage['used'],
            'free_bytes': usage['free'],
        },
        'thresholds': {
            'warning': DISK_THRESHOLD_WARNING,
            'critical': DISK_THRESHOLD_CRITICAL,
            'emergency': DISK_THRESHOLD_EMERGENCY,
        },
        'growth_warning': growth_warning,
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/disk/large-files')
def api_disk_large_files():
    """Find large files on the system"""
    min_size = request.args.get('min_size_mb', 100, type=int)
    max_results = request.args.get('max_results', 20, type=int)
    
    info('DISK', f'Scanning for large files (min: {min_size}MB)')
    
    try:
        files = _find_large_files(min_size_mb=min_size, max_results=max_results)
        total_size = sum(f['size'] for f in files)
        
        return jsonify({
            'files': files,
            'count': len(files),
            'total_size': total_size,
            'total_size_human': format_bytes(total_size),
            'min_size_mb': min_size,
            'timestamp': datetime.now().isoformat()
        })
    except Exception as e:
        error('DISK', f'Failed to scan for large files: {e}', exc_info=True)
        return jsonify({'error': str(e)}), 500

@app.route('/api/disk/bloat')
def api_disk_bloat():
    """Detect known bloat sources"""
    info('DISK', 'Detecting known bloat sources')
    
    try:
        bloat = _detect_bloat()
        total_bloat = sum(b['total_size'] for b in bloat)
        
        # Also get disk usage for context
        usage = _get_disk_usage()
        
        return jsonify({
            'bloat_sources': bloat,
            'total_bloat': total_bloat,
            'total_bloat_human': format_bytes(total_bloat),
            'disk_usage': {
                'percent': usage['percent'] if usage else 0,
                'free': format_bytes(usage['free']) if usage else 'Unknown',
            } if usage else None,
            'potential_recovery': f"Cleaning all safe sources could free up to {format_bytes(sum(b['total_size'] for b in bloat if b['safe']))}",
            'timestamp': datetime.now().isoformat()
        })
    except Exception as e:
        error('DISK', f'Failed to detect bloat: {e}', exc_info=True)
        return jsonify({'error': str(e)}), 500

@app.route('/api/disk/cleanup', methods=['POST'])
def api_disk_cleanup():
    """Clean up a specific bloat source"""
    data = request.get_json() or {}
    source_id = data.get('source_id')
    
    if not source_id:
        return jsonify({'error': 'source_id required'}), 400
    
    # Find the source
    source = None
    for s in KNOWN_BLOAT_SOURCES:
        if s['id'] == source_id:
            source = s
            break
    
    if not source:
        return jsonify({'error': f'Unknown source: {source_id}'}), 404
    
    if not source['safe'] and not data.get('force'):
        return jsonify({
            'error': 'This cleanup is not marked as safe. Set force=true to proceed.',
            'warning': f"Cleaning {source['name']} may have side effects."
        }), 400
    
    info('DISK', f"Starting cleanup of {source['name']}")
    
    # Get size before cleanup
    size_before = sum(_get_dir_size(p) for p in source['paths'])
    
    # Run cleanup commands
    results = []
    for cmd in source['cleanup_commands']:
        try:
            # Expand ~ in commands
            expanded_cmd = cmd
            for path in source['paths']:
                if '~' in path:
                    expanded_cmd = expanded_cmd.replace(path, _expand_path(path))
            
            result = subprocess.run(
                expanded_cmd,
                shell=True,
                capture_output=True,
                text=True,
                timeout=60
            )
            results.append({
                'command': cmd,
                'success': result.returncode == 0,
                'stdout': result.stdout[:500] if result.stdout else '',
                'stderr': result.stderr[:500] if result.stderr else '',
            })
        except subprocess.TimeoutExpired:
            results.append({
                'command': cmd,
                'success': False,
                'error': 'Command timed out'
            })
        except Exception as e:
            results.append({
                'command': cmd,
                'success': False,
                'error': str(e)
            })
    
    # Get size after cleanup
    size_after = sum(_get_dir_size(p) for p in source['paths'])
    freed = size_before - size_after
    
    info('DISK', f"Cleanup complete: freed {format_bytes(freed)}")
    
    return jsonify({
        'source_id': source_id,
        'source_name': source['name'],
        'size_before': format_bytes(size_before),
        'size_after': format_bytes(size_after),
        'freed': format_bytes(freed),
        'freed_bytes': freed,
        'commands_run': results,
        'success': all(r.get('success', False) for r in results),
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/disk/cleanup-all', methods=['POST'])
def api_disk_cleanup_all():
    """Clean up all safe bloat sources"""
    data = request.get_json() or {}
    include_unsafe = data.get('include_unsafe', False)
    
    info('DISK', f"Starting cleanup of all {'sources' if include_unsafe else 'safe sources'}")
    
    # Get current bloat
    bloat = _detect_bloat()
    
    results = []
    total_freed = 0
    
    for source in bloat:
        if not source['safe'] and not include_unsafe:
            results.append({
                'source_id': source['id'],
                'source_name': source['name'],
                'skipped': True,
                'reason': 'Not marked as safe'
            })
            continue
        
        # Get size before
        size_before = source['total_size']
        
        # Find full source config
        source_config = None
        for s in KNOWN_BLOAT_SOURCES:
            if s['id'] == source['id']:
                source_config = s
                break
        
        if not source_config:
            continue
        
        # Run cleanup
        cmd_results = []
        for cmd in source_config['cleanup_commands']:
            try:
                expanded_cmd = cmd
                for path in source_config['paths']:
                    if '~' in path:
                        expanded_cmd = expanded_cmd.replace(path, _expand_path(path))
                
                result = subprocess.run(
                    expanded_cmd,
                    shell=True,
                    capture_output=True,
                    text=True,
                    timeout=60
                )
                cmd_results.append({
                    'command': cmd,
                    'success': result.returncode == 0
                })
            except Exception as e:
                cmd_results.append({
                    'command': cmd,
                    'success': False,
                    'error': str(e)
                })
        
        # Get size after
        size_after = sum(_get_dir_size(p) for p in source_config['paths'])
        freed = size_before - size_after
        total_freed += freed
        
        results.append({
            'source_id': source['id'],
            'source_name': source['name'],
            'size_before': format_bytes(size_before),
            'freed': format_bytes(freed),
            'commands': cmd_results
        })
    
    # Get new disk status
    usage = _get_disk_usage()
    
    info('DISK', f"Cleanup all complete: freed {format_bytes(total_freed)}")
    
    return jsonify({
        'results': results,
        'total_freed': format_bytes(total_freed),
        'total_freed_bytes': total_freed,
        'disk_usage_after': {
            'percent': usage['percent'] if usage else 0,
            'free': format_bytes(usage['free']) if usage else 'Unknown',
        } if usage else None,
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/disk/delete-file', methods=['POST'])
def api_disk_delete_file():
    """Delete a specific large file"""
    data = request.get_json() or {}
    filepath = data.get('path')
    
    if not filepath:
        return jsonify({'error': 'path required'}), 400
    
    # Safety checks
    dangerous_paths = ['/', '/home', '/var', '/etc', '/usr', '/bin', '/sbin', '/root']
    if filepath in dangerous_paths:
        return jsonify({'error': 'Cannot delete system directories'}), 400
    
    if not os.path.exists(filepath):
        return jsonify({'error': 'File not found'}), 404
    
    try:
        size = os.path.getsize(filepath)
        os.remove(filepath)
        
        info('DISK', f"Deleted file: {filepath} ({format_bytes(size)})")
        
        return jsonify({
            'deleted': filepath,
            'size_freed': format_bytes(size),
            'size_freed_bytes': size,
            'success': True,
            'timestamp': datetime.now().isoformat()
        })
    except PermissionError:
        return jsonify({'error': 'Permission denied. May need to run as root.'}), 403
    except Exception as e:
        error('DISK', f'Failed to delete file: {e}')
        return jsonify({'error': str(e)}), 500

# =============================================================================
# MEMORY MANAGEMENT
# =============================================================================

# Memory thresholds
MEMORY_THRESHOLD_WARNING = 70
MEMORY_THRESHOLD_CRITICAL = 85
MEMORY_THRESHOLD_EMERGENCY = 95

def _get_memory_info():
    """Get detailed memory information"""
    if not PSUTIL_AVAILABLE:
        return None
    try:
        mem = psutil.virtual_memory()
        swap = psutil.swap_memory()
        return {
            'ram': {
                'total': mem.total,
                'available': mem.available,
                'used': mem.used,
                'free': mem.free,
                'percent': mem.percent,
                'cached': getattr(mem, 'cached', 0),
                'buffers': getattr(mem, 'buffers', 0),
            },
            'swap': {
                'total': swap.total,
                'used': swap.used,
                'free': swap.free,
                'percent': swap.percent,
            }
        }
    except Exception as e:
        error('MEMORY', f'Failed to get memory info: {e}')
        return None

def _get_top_processes(sort_by='memory', limit=20):
    """Get top processes by memory or CPU usage"""
    if not PSUTIL_AVAILABLE:
        return []
    
    processes = []
    try:
        for proc in psutil.process_iter(['pid', 'name', 'username', 'memory_percent', 'cpu_percent', 'memory_info', 'status', 'create_time']):
            try:
                info = proc.info
                # Skip kernel processes and zombies with no memory
                if info['memory_percent'] is None or info['memory_percent'] < 0.01:
                    continue
                
                processes.append({
                    'pid': info['pid'],
                    'name': info['name'] or 'Unknown',
                    'user': info['username'] or 'system',
                    'memory_percent': round(info['memory_percent'], 2),
                    'cpu_percent': round(info['cpu_percent'] or 0, 2),
                    'memory_mb': round((info['memory_info'].rss if info['memory_info'] else 0) / (1024 * 1024), 1),
                    'status': info['status'],
                    'uptime': int(time.time() - info['create_time']) if info['create_time'] else 0,
                })
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                continue
        
        # Sort by requested field
        if sort_by == 'cpu':
            processes.sort(key=lambda x: x['cpu_percent'], reverse=True)
        else:
            processes.sort(key=lambda x: x['memory_percent'], reverse=True)
        
        return processes[:limit]
    except Exception as e:
        error('MEMORY', f'Failed to get processes: {e}')
        return []

# Protected processes that should not be killed
PROTECTED_PROCESSES = {
    'systemd', 'init', 'kthreadd', 'ksoftirqd', 'kworker', 'migration',
    'rcu_sched', 'watchdog', 'cpuhp', 'netns', 'kauditd', 'khungtaskd',
    'oom_reaper', 'writeback', 'kcompactd', 'ksmd', 'khugepaged',
    'kintegrityd', 'kblockd', 'tpm_dev_wq', 'ata_sff', 'scsi_eh',
    'scsi_tmf', 'dm_bufio_cache', 'kswapd', 'ecryptfs', 'kthrotld',
    'acpi_thermal', 'nvme-wq', 'ipv6_addrconf', 'sshd', 'login',
    'dockerd', 'containerd', 'docker', 'shellder'
}

@app.route('/api/memory/health')
def api_memory_health():
    """Get memory health status"""
    mem_info = _get_memory_info()
    if not mem_info:
        return jsonify({'error': 'Could not get memory info'}), 500
    
    percent = mem_info['ram']['percent']
    
    # Determine status
    if percent >= MEMORY_THRESHOLD_EMERGENCY:
        status = 'emergency'
        message = '🚨 EMERGENCY: Memory almost exhausted! System may become unstable.'
    elif percent >= MEMORY_THRESHOLD_CRITICAL:
        status = 'critical'
        message = '🔴 CRITICAL: Memory usage very high. Consider killing processes.'
    elif percent >= MEMORY_THRESHOLD_WARNING:
        status = 'warning'
        message = '⚠️ WARNING: Memory usage elevated.'
    else:
        status = 'healthy'
        message = '✅ Memory usage is healthy.'
    
    # Calculate clearable cache
    clearable = mem_info['ram']['cached'] + mem_info['ram']['buffers']
    
    return jsonify({
        'status': status,
        'message': message,
        'ram': {
            'total': format_bytes(mem_info['ram']['total']),
            'used': format_bytes(mem_info['ram']['used']),
            'available': format_bytes(mem_info['ram']['available']),
            'free': format_bytes(mem_info['ram']['free']),
            'cached': format_bytes(mem_info['ram']['cached']),
            'buffers': format_bytes(mem_info['ram']['buffers']),
            'percent': mem_info['ram']['percent'],
            'total_bytes': mem_info['ram']['total'],
            'used_bytes': mem_info['ram']['used'],
            'available_bytes': mem_info['ram']['available'],
        },
        'swap': {
            'total': format_bytes(mem_info['swap']['total']),
            'used': format_bytes(mem_info['swap']['used']),
            'free': format_bytes(mem_info['swap']['free']),
            'percent': mem_info['swap']['percent'],
        },
        'clearable_cache': format_bytes(clearable),
        'clearable_cache_bytes': clearable,
        'thresholds': {
            'warning': MEMORY_THRESHOLD_WARNING,
            'critical': MEMORY_THRESHOLD_CRITICAL,
            'emergency': MEMORY_THRESHOLD_EMERGENCY,
        },
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/memory/processes')
def api_memory_processes():
    """Get top processes by memory usage"""
    sort_by = request.args.get('sort', 'memory')
    limit = request.args.get('limit', 20, type=int)
    
    processes = _get_top_processes(sort_by=sort_by, limit=limit)
    
    # Calculate total memory used by top processes
    total_memory = sum(p['memory_percent'] for p in processes)
    
    return jsonify({
        'processes': processes,
        'count': len(processes),
        'total_memory_percent': round(total_memory, 2),
        'sort_by': sort_by,
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/memory/clear-cache', methods=['POST'])
def api_memory_clear_cache():
    """Clear memory cache (sync and drop caches)"""
    info('MEMORY', 'Clearing memory cache')
    
    try:
        # First sync to flush file buffers
        subprocess.run(['sync'], timeout=30)
        
        # Get memory before
        mem_before = _get_memory_info()
        cached_before = mem_before['ram']['cached'] + mem_before['ram']['buffers'] if mem_before else 0
        
        # Drop caches (requires root)
        # 1 = page cache, 2 = dentries/inodes, 3 = all
        result = subprocess.run(
            'echo 3 | sudo tee /proc/sys/vm/drop_caches',
            shell=True,
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode != 0:
            # Try without sudo (in case running as root)
            result = subprocess.run(
                'echo 3 > /proc/sys/vm/drop_caches',
                shell=True,
                capture_output=True,
                text=True,
                timeout=30
            )
        
        # Get memory after
        mem_after = _get_memory_info()
        cached_after = mem_after['ram']['cached'] + mem_after['ram']['buffers'] if mem_after else 0
        freed = cached_before - cached_after
        
        info('MEMORY', f'Cache cleared: freed {format_bytes(freed)}')
        
        return jsonify({
            'success': True,
            'freed': format_bytes(freed),
            'freed_bytes': freed,
            'memory_before': mem_before['ram']['percent'] if mem_before else 0,
            'memory_after': mem_after['ram']['percent'] if mem_after else 0,
            'timestamp': datetime.now().isoformat()
        })
    except subprocess.TimeoutExpired:
        return jsonify({'error': 'Command timed out'}), 500
    except Exception as e:
        error('MEMORY', f'Failed to clear cache: {e}')
        return jsonify({'error': str(e)}), 500

@app.route('/api/memory/process/<int:pid>/kill', methods=['POST'])
def api_memory_kill_process(pid):
    """Kill a process by PID"""
    if not PSUTIL_AVAILABLE:
        return jsonify({'error': 'psutil not available'}), 500
    
    try:
        proc = psutil.Process(pid)
        proc_name = proc.name()
        
        # Check if protected
        if proc_name.lower() in PROTECTED_PROCESSES or any(p in proc_name.lower() for p in PROTECTED_PROCESSES):
            return jsonify({
                'error': f'Cannot kill protected process: {proc_name}',
                'protected': True
            }), 403
        
        # Get memory before killing
        mem_percent = proc.memory_percent()
        
        # Try graceful termination first
        proc.terminate()
        
        # Wait up to 3 seconds for graceful shutdown
        try:
            proc.wait(timeout=3)
        except psutil.TimeoutExpired:
            # Force kill
            proc.kill()
            proc.wait(timeout=2)
        
        info('MEMORY', f'Killed process: {proc_name} (PID {pid}), freed ~{mem_percent:.1f}% memory')
        
        return jsonify({
            'success': True,
            'pid': pid,
            'name': proc_name,
            'memory_freed_percent': round(mem_percent, 2),
            'timestamp': datetime.now().isoformat()
        })
        
    except psutil.NoSuchProcess:
        return jsonify({'error': f'Process {pid} not found'}), 404
    except psutil.AccessDenied:
        return jsonify({'error': f'Access denied to kill process {pid}. May need root.'}), 403
    except Exception as e:
        error('MEMORY', f'Failed to kill process {pid}: {e}')
        return jsonify({'error': str(e)}), 500

@app.route('/api/memory/process/<int:pid>/restart', methods=['POST'])
def api_memory_restart_process(pid):
    """Restart a process (kill and let supervisor restart it)"""
    if not PSUTIL_AVAILABLE:
        return jsonify({'error': 'psutil not available'}), 500
    
    try:
        proc = psutil.Process(pid)
        proc_name = proc.name()
        cmdline = proc.cmdline()
        
        # Check if protected
        if proc_name.lower() in PROTECTED_PROCESSES:
            return jsonify({
                'error': f'Cannot restart protected process: {proc_name}',
                'protected': True
            }), 403
        
        # For Docker containers, use docker restart instead
        if 'containerd' in proc_name.lower() or proc_name.startswith('docker'):
            return jsonify({
                'error': 'Use Docker commands to restart containers',
                'suggestion': 'Use the Containers page to restart Docker containers'
            }), 400
        
        # Get process info
        mem_percent = proc.memory_percent()
        
        # Kill the process (supervisor/systemd should restart it)
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except psutil.TimeoutExpired:
            proc.kill()
        
        info('MEMORY', f'Restarted process: {proc_name} (PID {pid})')
        
        return jsonify({
            'success': True,
            'pid': pid,
            'name': proc_name,
            'cmdline': ' '.join(cmdline[:5]),  # First 5 parts of command
            'message': f'Process {proc_name} terminated. If managed by systemd/supervisor, it will restart automatically.',
            'timestamp': datetime.now().isoformat()
        })
        
    except psutil.NoSuchProcess:
        return jsonify({'error': f'Process {pid} not found'}), 404
    except psutil.AccessDenied:
        return jsonify({'error': f'Access denied. May need root.'}), 403
    except Exception as e:
        error('MEMORY', f'Failed to restart process {pid}: {e}')
        return jsonify({'error': str(e)}), 500

@app.route('/api/memory/kill-high-memory', methods=['POST'])
def api_memory_kill_high_memory():
    """Emergency: Kill highest memory processes to free memory"""
    data = request.get_json() or {}
    target_percent = data.get('target_percent', 70)  # Target memory usage
    max_kills = data.get('max_kills', 3)  # Maximum processes to kill
    
    if not PSUTIL_AVAILABLE:
        return jsonify({'error': 'psutil not available'}), 500
    
    mem_info = _get_memory_info()
    if not mem_info:
        return jsonify({'error': 'Could not get memory info'}), 500
    
    current_percent = mem_info['ram']['percent']
    
    if current_percent <= target_percent:
        return jsonify({
            'success': True,
            'message': f'Memory already at {current_percent}%, no action needed',
            'killed': []
        })
    
    info('MEMORY', f'Emergency cleanup: memory at {current_percent}%, target {target_percent}%')
    
    # Get processes sorted by memory
    processes = _get_top_processes(sort_by='memory', limit=20)
    killed = []
    
    for proc in processes:
        if len(killed) >= max_kills:
            break
        
        # Skip protected processes
        if proc['name'].lower() in PROTECTED_PROCESSES:
            continue
        
        # Skip low memory processes
        if proc['memory_percent'] < 5:
            continue
        
        try:
            p = psutil.Process(proc['pid'])
            p.terminate()
            try:
                p.wait(timeout=3)
            except psutil.TimeoutExpired:
                p.kill()
            
            killed.append({
                'pid': proc['pid'],
                'name': proc['name'],
                'memory_percent': proc['memory_percent']
            })
            
            info('MEMORY', f'Emergency killed: {proc["name"]} (PID {proc["pid"]})')
            
            # Check if we've freed enough
            new_mem = _get_memory_info()
            if new_mem and new_mem['ram']['percent'] <= target_percent:
                break
                
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    
    # Get final memory state
    final_mem = _get_memory_info()
    
    return jsonify({
        'success': True,
        'killed': killed,
        'memory_before': current_percent,
        'memory_after': final_mem['ram']['percent'] if final_mem else current_percent,
        'total_freed_percent': sum(k['memory_percent'] for k in killed),
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/containers')
def api_containers():
    """Get detailed container status"""
    # Return mock data in local mode
    if LOCAL_MODE or docker_client is None:
        return jsonify(get_mock_status()['containers']['list'])
    
    stats = stats_collector.get_all_stats()
    return jsonify(list(stats.get('containers', {}).values()))

# Cache for image update checks (to avoid hammering Docker Hub)
_image_update_cache = {}
_image_update_cache_time = {}
IMAGE_UPDATE_CACHE_SECONDS = 300  # Cache update status for 5 minutes

@app.route('/api/containers/updates')
def api_containers_updates():
    """Check for available updates for container images"""
    if LOCAL_MODE or docker_client is None:
        return jsonify({'updates': {}, 'checked': 0, 'available': 0})
    
    updates = {}
    checked = 0
    available = 0
    
    try:
        containers = docker_client.containers.list(all=True)
        
        for container in containers:
            try:
                image_name = container.image.tags[0] if container.image.tags else None
                if not image_name:
                    continue
                
                # Check cache first
                cache_key = image_name
                now = time.time()
                if cache_key in _image_update_cache:
                    cache_time = _image_update_cache_time.get(cache_key, 0)
                    if now - cache_time < IMAGE_UPDATE_CACHE_SECONDS:
                        updates[container.name] = _image_update_cache[cache_key]
                        if _image_update_cache[cache_key].get('update_available'):
                            available += 1
                        checked += 1
                        continue
                
                # Get local image ID
                local_id = container.image.short_id
                
                # Try to check remote - use docker pull with dry-run simulation
                # We'll compare the image ID after a "docker pull" check
                update_info = {
                    'image': image_name,
                    'local_id': local_id,
                    'update_available': False,
                    'checked_at': datetime.now().isoformat()
                }
                
                # For common images, try to detect updates via docker
                # This uses `docker image inspect` and registry API
                try:
                    # Get local image creation date
                    local_image = docker_client.images.get(image_name)
                    local_created = local_image.attrs.get('Created', '')
                    update_info['local_created'] = local_created[:19] if local_created else 'unknown'
                    
                    # Check if image has "latest" tag - these often have updates
                    if ':latest' in image_name or ':' not in image_name:
                        # For latest tags, suggest checking for updates
                        update_info['may_have_update'] = True
                        update_info['note'] = 'Using :latest tag - run docker pull to check'
                    
                except Exception:
                    pass
                
                # Cache the result
                _image_update_cache[cache_key] = update_info
                _image_update_cache_time[cache_key] = now
                
                updates[container.name] = update_info
                checked += 1
                if update_info.get('update_available') or update_info.get('may_have_update'):
                    available += 1
                    
            except Exception as e:
                updates[container.name] = {'error': str(e)}
        
    except Exception as e:
        return jsonify({'error': str(e), 'updates': {}, 'checked': 0, 'available': 0})
    
    return jsonify({
        'updates': updates,
        'checked': checked,
        'available': available,
        'cache_ttl': IMAGE_UPDATE_CACHE_SECONDS
    })

@app.route('/api/containers/check-update/<name>', methods=['POST'])
def api_container_check_update(name):
    """Force check for updates on a specific container by pulling the image"""
    if LOCAL_MODE or docker_client is None:
        return jsonify({'error': 'Docker not available'}), 503
    
    try:
        container = docker_client.containers.get(name)
        image_name = container.image.tags[0] if container.image.tags else None
        
        if not image_name:
            return jsonify({'error': 'Container has no image tag'}), 400
        
        old_id = container.image.short_id
        
        # Pull the latest image
        result = subprocess.run(
            ['docker', 'pull', image_name],
            capture_output=True, text=True, timeout=120
        )
        
        if result.returncode != 0:
            return jsonify({
                'success': False,
                'error': result.stderr,
                'output': result.stdout
            })
        
        # Check if image changed
        new_image = docker_client.images.get(image_name)
        new_id = new_image.short_id
        
        update_available = old_id != new_id
        
        # Update cache
        cache_key = image_name
        _image_update_cache[cache_key] = {
            'image': image_name,
            'local_id': new_id,
            'update_available': update_available,
            'just_updated': update_available,
            'checked_at': datetime.now().isoformat()
        }
        _image_update_cache_time[cache_key] = time.time()
        
        return jsonify({
            'success': True,
            'container': name,
            'image': image_name,
            'old_id': old_id,
            'new_id': new_id,
            'update_available': update_available,
            'message': 'New image pulled!' if update_available else 'Already up to date'
        })
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/container/<name>/logs')
def api_container_logs(name):
    """Get logs for a specific container"""
    lines = request.args.get('lines', 100, type=int)
    logs = get_container_logs(name, lines)
    return jsonify({
        'container': name,
        'logs': logs,
        'success': True
    })

@app.route('/api/container/<name>/logs/stream')
def api_container_logs_stream(name):
    """Stream container logs in real-time"""
    def generate():
        if docker_client:
            try:
                container = docker_client.containers.get(name)
                for log in container.logs(stream=True, follow=True, tail=10):
                    yield f"data: {log.decode('utf-8', errors='ignore')}\n\n"
            except Exception as e:
                yield f"data: Error: {str(e)}\n\n"
        else:
            yield "data: Docker not available\n\n"
    
    return Response(generate(), mimetype='text/event-stream')

@app.route('/api/container/<name>/<action>', methods=['POST'])
def api_container_action(name, action):
    """Perform action on container"""
    if action not in ['start', 'stop', 'restart']:
        return jsonify({'success': False, 'error': 'Invalid action'})
    
    if docker_client:
        try:
            container = docker_client.containers.get(name)
            getattr(container, action)()
            return jsonify({'success': True, 'message': f'{name} {action}ed'})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})
    else:
        try:
            result = subprocess.run(
                ["docker", action, name],
                capture_output=True, text=True, timeout=60
            )
            return jsonify({
                'success': result.returncode == 0,
                'output': result.stdout + result.stderr
            })
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

@app.route('/api/docker/<action>', methods=['POST'])
def api_docker_action(action):
    """Docker compose actions - handles running containers gracefully"""
    
    if action not in ['up', 'down', 'restart', 'pull']:
        return jsonify({'success': False, 'error': 'Invalid action'})
    
    try:
        aegis_root = str(AEGIS_ROOT)
        
        # Special handling for 'up' action - skip already running containers
        if action == 'up':
            # Check which services are already running
            ps_result = subprocess.run(
                ['docker', 'compose', 'ps', '--format', 'json'],
                capture_output=True, text=True, timeout=30, cwd=aegis_root
            )
            
            running_services = set()
            if ps_result.returncode == 0 and ps_result.stdout.strip():
                for line in ps_result.stdout.strip().split('\n'):
                    try:
                        container = json.loads(line)
                        if container.get('State') == 'running':
                            running_services.add(container.get('Service', ''))
                    except:
                        pass
            
            # Get all services
            config_result = subprocess.run(
                ['docker', 'compose', 'config', '--services'],
                capture_output=True, text=True, timeout=30, cwd=aegis_root
            )
            all_services = set(config_result.stdout.strip().split('\n')) if config_result.returncode == 0 else set()
            
            # Find services to start
            services_to_start = all_services - running_services
            
            # Skip shellder if host shellder is running on port 5000
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(1)
                if sock.connect_ex(('127.0.0.1', 5000)) == 0:
                    services_to_start.discard('shellder')
                sock.close()
            except:
                pass
            
            if not services_to_start:
                return jsonify({
                    'success': True,
                    'output': 'All containers already running',
                    'already_running': list(running_services)
                })
            
            # Start only stopped services
            cmd = ['docker', 'compose', 'up', '-d', '--no-recreate'] + list(services_to_start)
        else:
            cmd_map = {
                'down': ['docker', 'compose', 'down'],
                'restart': ['docker', 'compose', 'restart'],
                'pull': ['docker', 'compose', 'pull']
            }
            cmd = cmd_map[action]
        
        result = subprocess.run(
            cmd,
            capture_output=True, text=True, timeout=300,
            cwd=aegis_root
        )
        
        output = result.stdout + result.stderr
        
        # For 'up', consider partial success as success
        if action == 'up':
            return jsonify({
                'success': True,
                'output': output,
                'services_started': list(services_to_start) if 'services_to_start' in dir() else []
            })
        
        return jsonify({
            'success': result.returncode == 0,
            'output': output
        })
    except Exception as e:
        error('DOCKER', f'Docker action {action} failed: {e}')
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/docker/update-all', methods=['POST'])
def api_docker_update_all():
    """Update all containers: pull latest images and recreate"""
    import time
    start_time = time.time()
    steps = []
    all_output = []
    
    try:
        # Step 1: Pull latest images
        pull_start = time.time()
        pull_result = subprocess.run(
            ['docker', 'compose', 'pull'],
            capture_output=True, text=True, timeout=600,
            cwd=str(AEGIS_ROOT)
        )
        pull_duration = f"{time.time() - pull_start:.1f}s"
        steps.append({
            'name': 'Pull latest images',
            'success': pull_result.returncode == 0,
            'duration': pull_duration
        })
        all_output.append(f"=== Pull Images ===\n{pull_result.stdout}\n{pull_result.stderr}")
        
        if pull_result.returncode != 0:
            return jsonify({
                'success': False,
                'error': 'Failed to pull images',
                'steps': steps,
                'output': '\n'.join(all_output),
                'duration': f"{time.time() - start_time:.1f}s"
            })
        
        # Step 2: Recreate containers with new images
        up_start = time.time()
        up_result = subprocess.run(
            ['docker', 'compose', 'up', '-d', '--force-recreate'],
            capture_output=True, text=True, timeout=300,
            cwd=str(AEGIS_ROOT)
        )
        up_duration = f"{time.time() - up_start:.1f}s"
        steps.append({
            'name': 'Recreate containers',
            'success': up_result.returncode == 0,
            'duration': up_duration
        })
        all_output.append(f"=== Recreate Containers ===\n{up_result.stdout}\n{up_result.stderr}")
        
        total_duration = f"{time.time() - start_time:.1f}s"
        
        return jsonify({
            'success': up_result.returncode == 0,
            'steps': steps,
            'output': '\n'.join(all_output),
            'duration': total_duration
        })
        
    except subprocess.TimeoutExpired:
        return jsonify({
            'success': False,
            'error': 'Operation timed out (exceeded 10 minutes)',
            'steps': steps,
            'output': '\n'.join(all_output)
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e),
            'steps': steps,
            'output': '\n'.join(all_output)
        })

@app.route('/api/docker/rebuild', methods=['POST'])
def api_docker_rebuild():
    """Force rebuild all containers: stop, remove, pull fresh, and start"""
    import time
    start_time = time.time()
    steps = []
    all_output = []
    
    try:
        # Step 1: Stop all containers
        stop_start = time.time()
        stop_result = subprocess.run(
            ['docker', 'compose', 'down'],
            capture_output=True, text=True, timeout=120,
            cwd=str(AEGIS_ROOT)
        )
        stop_duration = f"{time.time() - stop_start:.1f}s"
        steps.append({
            'name': 'Stop all containers',
            'success': stop_result.returncode == 0,
            'duration': stop_duration
        })
        all_output.append(f"=== Stop Containers ===\n{stop_result.stdout}\n{stop_result.stderr}")
        
        # Step 2: Remove containers and volumes (but keep data volumes)
        rm_start = time.time()
        rm_result = subprocess.run(
            ['docker', 'compose', 'rm', '-f'],
            capture_output=True, text=True, timeout=60,
            cwd=str(AEGIS_ROOT)
        )
        rm_duration = f"{time.time() - rm_start:.1f}s"
        steps.append({
            'name': 'Remove containers',
            'success': True,  # rm can fail if no containers, that's OK
            'duration': rm_duration
        })
        all_output.append(f"=== Remove Containers ===\n{rm_result.stdout}\n{rm_result.stderr}")
        
        # Step 3: Pull fresh images (no cache)
        pull_start = time.time()
        pull_result = subprocess.run(
            ['docker', 'compose', 'pull', '--ignore-pull-failures'],
            capture_output=True, text=True, timeout=900,
            cwd=str(AEGIS_ROOT)
        )
        pull_duration = f"{time.time() - pull_start:.1f}s"
        steps.append({
            'name': 'Pull fresh images',
            'success': pull_result.returncode == 0,
            'duration': pull_duration
        })
        all_output.append(f"=== Pull Fresh Images ===\n{pull_result.stdout}\n{pull_result.stderr}")
        
        # Step 4: Build and start all containers
        up_start = time.time()
        up_result = subprocess.run(
            ['docker', 'compose', 'up', '-d', '--force-recreate', '--build'],
            capture_output=True, text=True, timeout=600,
            cwd=str(AEGIS_ROOT)
        )
        up_duration = f"{time.time() - up_start:.1f}s"
        steps.append({
            'name': 'Build and start containers',
            'success': up_result.returncode == 0,
            'duration': up_duration
        })
        all_output.append(f"=== Build & Start ===\n{up_result.stdout}\n{up_result.stderr}")
        
        total_duration = f"{time.time() - start_time:.1f}s"
        
        return jsonify({
            'success': up_result.returncode == 0,
            'steps': steps,
            'output': '\n'.join(all_output),
            'duration': total_duration
        })
        
    except subprocess.TimeoutExpired:
        return jsonify({
            'success': False,
            'error': 'Operation timed out (exceeded 15 minutes)',
            'steps': steps,
            'output': '\n'.join(all_output)
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e),
            'steps': steps,
            'output': '\n'.join(all_output)
        })

@app.route('/api/docker/prune', methods=['POST'])
def api_docker_prune():
    """Clean up unused Docker resources"""
    try:
        # Run docker system prune
        result = subprocess.run(
            ['docker', 'system', 'prune', '-f'],
            capture_output=True, text=True, timeout=120
        )
        
        # Try to parse space reclaimed
        output = result.stdout + result.stderr
        space_freed = "unknown"
        
        # Docker outputs something like "Total reclaimed space: 1.234GB"
        import re
        match = re.search(r'reclaimed space:\s*([\d.]+\s*[KMGT]?B)', output, re.IGNORECASE)
        if match:
            space_freed = match.group(1)
        
        return jsonify({
            'success': result.returncode == 0,
            'output': output,
            'space_freed': space_freed
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/docker/health')
def api_docker_health():
    """Get comprehensive Docker health status"""
    health = {
        'daemon': {'running': False, 'version': None},
        'compose': {'available': False, 'version': None},
        'networks': {'count': 0, 'aegis_network': False},
        'volumes': {'count': 0},
        'info': {}
    }
    
    try:
        # Check Docker daemon
        version_result = subprocess.run(
            ['docker', 'version', '--format', '{{.Server.Version}}'],
            capture_output=True, text=True, timeout=10
        )
        if version_result.returncode == 0:
            health['daemon']['running'] = True
            health['daemon']['version'] = version_result.stdout.strip()
        
        # Check Docker Compose
        compose_result = subprocess.run(
            ['docker', 'compose', 'version', '--short'],
            capture_output=True, text=True, timeout=10
        )
        if compose_result.returncode == 0:
            health['compose']['available'] = True
            health['compose']['version'] = compose_result.stdout.strip()
        
        # Check networks
        networks_result = subprocess.run(
            ['docker', 'network', 'ls', '--format', '{{.Name}}'],
            capture_output=True, text=True, timeout=10
        )
        if networks_result.returncode == 0:
            networks = [n.strip() for n in networks_result.stdout.strip().split('\n') if n.strip()]
            health['networks']['count'] = len(networks)
            # Check for aegis network (might be named differently)
            health['networks']['aegis_network'] = any(
                'aegis' in n.lower() or 'default' in n.lower() 
                for n in networks
            )
        
        # Check volumes
        volumes_result = subprocess.run(
            ['docker', 'volume', 'ls', '-q'],
            capture_output=True, text=True, timeout=10
        )
        if volumes_result.returncode == 0:
            volumes = [v.strip() for v in volumes_result.stdout.strip().split('\n') if v.strip()]
            health['volumes']['count'] = len(volumes)
        
        # Get additional info
        info_result = subprocess.run(
            ['docker', 'info', '--format', '{{.DockerRootDir}}||{{.Images}}'],
            capture_output=True, text=True, timeout=10
        )
        if info_result.returncode == 0:
            parts = info_result.stdout.strip().split('||')
            if len(parts) >= 2:
                health['info']['docker_root'] = parts[0]
                health['info']['images_count'] = parts[1]
        
        health['info']['version'] = health['daemon'].get('version', '--')
        
        # Check compose file
        compose_file = AEGIS_ROOT / 'docker-compose.yaml'
        if compose_file.exists():
            health['info']['compose_file'] = 'docker-compose.yaml ✓'
        else:
            compose_file = AEGIS_ROOT / 'docker-compose.yml'
            if compose_file.exists():
                health['info']['compose_file'] = 'docker-compose.yml ✓'
            else:
                health['info']['compose_file'] = 'Not found ✗'
        
        # Get disk usage
        disk_result = subprocess.run(
            ['docker', 'system', 'df', '--format', '{{.Size}}'],
            capture_output=True, text=True, timeout=30
        )
        if disk_result.returncode == 0:
            sizes = [s.strip() for s in disk_result.stdout.strip().split('\n') if s.strip()]
            health['info']['disk_usage'] = ', '.join(sizes[:3]) if sizes else '--'
        
    except Exception as e:
        health['error'] = str(e)
    
    return jsonify(health)

@app.route('/api/docker/port-check')
def api_docker_port_check():
    """Check accessibility of container internal ports"""
    import socket
    
    ports = []
    
    # Known Aegis container ports
    container_ports = {
        'dragonite': {'port': 7272, 'host_port': 7272},
        'golbat': {'port': 9001, 'host_port': 9001},
        'rotom': {'port': 7070, 'host_port': 7070},
        'koji': {'port': 8080, 'host_port': 8080},
        'reactmap': {'port': 8080, 'host_port': 6001},
        'grafana': {'port': 3000, 'host_port': 3000},
        'victoriametrics': {'port': 8428, 'host_port': 8428},
        'vmagent': {'port': 8429, 'host_port': 8429},
        'mariadb': {'port': 3306, 'host_port': 3306},
        'xilriws': {'port': 9002, 'host_port': 9002},
    }
    
    # Get running containers
    running_containers = set()
    if docker_client:
        try:
            for c in docker_client.containers.list():
                running_containers.add(c.name)
        except:
            pass
    else:
        try:
            result = subprocess.run(
                ['docker', 'ps', '--format', '{{.Names}}'],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                running_containers = set(n.strip() for n in result.stdout.strip().split('\n') if n.strip())
        except:
            pass
    
    for container, port_info in container_ports.items():
        port_data = {
            'container': container,
            'internal_port': port_info['port'],
            'host_port': port_info.get('host_port'),
            'running': container in running_containers,
            'accessible': False,
            'response_time': None
        }
        
        if port_data['running']:
            # Try to connect to the port
            import time
            start_time = time.time()
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(2)
                result = sock.connect_ex(('127.0.0.1', port_info.get('host_port', port_info['port'])))
                sock.close()
                
                if result == 0:
                    port_data['accessible'] = True
                    port_data['response_time'] = int((time.time() - start_time) * 1000)
            except Exception as e:
                port_data['error'] = str(e)
        
        ports.append(port_data)
    
    return jsonify({
        'ports': ports,
        'running_count': len(running_containers),
        'accessible_count': sum(1 for p in ports if p['accessible'])
    })

# =============================================================================
# DOCKER SERVICE MANAGEMENT
# =============================================================================

@app.route('/api/docker/service/<action>', methods=['POST'])
def api_docker_service_action(action):
    """Control Docker service (systemd)"""
    if action not in ['start', 'stop', 'restart', 'enable', 'disable', 'status']:
        return jsonify({'success': False, 'error': 'Invalid action'})
    
    try:
        if action == 'status':
            result = subprocess.run(
                ['systemctl', 'is-active', 'docker'],
                capture_output=True, text=True, timeout=10
            )
            return jsonify({
                'success': True,
                'status': result.stdout.strip(),
                'running': result.returncode == 0
            })
        
        # For start/stop/restart/enable/disable
        result = subprocess.run(
            ['sudo', 'systemctl', action, 'docker'],
            capture_output=True, text=True, timeout=60
        )
        
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/docker/install-status')
def api_docker_install_status():
    """Get installation status of Docker components"""
    status = {
        'engine': {'installed': False, 'version': None},
        'compose': {'installed': False, 'version': None},
        'buildx': {'installed': False, 'version': None}
    }
    
    try:
        # Check Docker Engine
        result = subprocess.run(
            ['docker', '--version'],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            status['engine']['installed'] = True
            # Parse version like "Docker version 24.0.7, build afdd53b"
            import re
            match = re.search(r'version\s+([\d.]+)', result.stdout)
            if match:
                status['engine']['version'] = match.group(1)
        
        # Check Docker Compose
        result = subprocess.run(
            ['docker', 'compose', 'version', '--short'],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            status['compose']['installed'] = True
            status['compose']['version'] = result.stdout.strip()
        
        # Check Buildx
        result = subprocess.run(
            ['docker', 'buildx', 'version'],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            status['buildx']['installed'] = True
            # Parse version
            match = re.search(r'v?([\d.]+)', result.stdout)
            if match:
                status['buildx']['version'] = match.group(1)
                
    except Exception as e:
        status['error'] = str(e)
    
    return jsonify(status)

@app.route('/api/docker/install/<component>', methods=['POST'])
def api_docker_install_component(component):
    """Install Docker components"""
    if component not in ['engine', 'compose', 'buildx', 'all']:
        return jsonify({'success': False, 'error': 'Invalid component'})
    
    steps = []
    all_output = []
    
    try:
        if component in ['engine', 'all']:
            # Install Docker Engine
            steps.append({'name': 'Installing Docker Engine', 'success': False})
            
            # Check if already installed
            check_result = subprocess.run(['which', 'docker'], capture_output=True, text=True)
            if check_result.returncode == 0:
                steps[-1]['success'] = True
                steps[-1]['name'] = 'Docker Engine already installed'
                all_output.append('Docker Engine is already installed')
            else:
                # Install using convenience script
                install_cmds = [
                    ['sudo', 'apt-get', 'update', '-y'],
                    ['sudo', 'apt-get', 'install', '-y', 'ca-certificates', 'curl', 'gnupg'],
                    ['curl', '-fsSL', 'https://get.docker.com', '-o', '/tmp/get-docker.sh'],
                    ['sudo', 'sh', '/tmp/get-docker.sh']
                ]
                
                for cmd in install_cmds:
                    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
                    all_output.append(f"$ {' '.join(cmd)}\n{result.stdout}\n{result.stderr}")
                    if result.returncode != 0:
                        steps[-1]['error'] = f"Command failed: {' '.join(cmd)}"
                        break
                else:
                    steps[-1]['success'] = True
                    
                    # Add current user to docker group
                    import os
                    user = os.environ.get('SUDO_USER') or os.environ.get('USER', 'root')
                    subprocess.run(['sudo', 'usermod', '-aG', 'docker', user], capture_output=True)
        
        if component in ['compose', 'all']:
            # Docker Compose is included with Docker Engine v2
            steps.append({'name': 'Checking Docker Compose', 'success': False})
            result = subprocess.run(['docker', 'compose', 'version'], capture_output=True, text=True)
            if result.returncode == 0:
                steps[-1]['success'] = True
                steps[-1]['name'] = 'Docker Compose available'
            else:
                # Try to install compose plugin
                result = subprocess.run(
                    ['sudo', 'apt-get', 'install', '-y', 'docker-compose-plugin'],
                    capture_output=True, text=True, timeout=120
                )
                all_output.append(result.stdout + result.stderr)
                steps[-1]['success'] = result.returncode == 0
        
        if component in ['buildx', 'all']:
            steps.append({'name': 'Checking Docker Buildx', 'success': False})
            result = subprocess.run(['docker', 'buildx', 'version'], capture_output=True, text=True)
            if result.returncode == 0:
                steps[-1]['success'] = True
                steps[-1]['name'] = 'Docker Buildx available'
            else:
                # Try to install buildx
                result = subprocess.run(
                    ['sudo', 'apt-get', 'install', '-y', 'docker-buildx-plugin'],
                    capture_output=True, text=True, timeout=120
                )
                all_output.append(result.stdout + result.stderr)
                steps[-1]['success'] = result.returncode == 0
        
        if component == 'all':
            # Enable and start Docker service
            steps.append({'name': 'Starting Docker service', 'success': False})
            subprocess.run(['sudo', 'systemctl', 'enable', 'docker'], capture_output=True)
            result = subprocess.run(['sudo', 'systemctl', 'start', 'docker'], capture_output=True, text=True)
            steps[-1]['success'] = result.returncode == 0
        
        overall_success = all(s.get('success', False) for s in steps)
        
        return jsonify({
            'success': overall_success,
            'steps': steps,
            'output': '\n'.join(all_output),
            'message': 'Installation completed' if overall_success else 'Some steps failed'
        })
        
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e),
            'steps': steps,
            'output': '\n'.join(all_output)
        })

# =============================================================================
# DOCKER CONFIGURATION FILES
# =============================================================================

DOCKER_CONFIG_PATHS = {
    'daemon': '/etc/docker/daemon.json',
    'service': '/etc/systemd/system/docker.service.d/override.conf',
    'compose-override': str(AEGIS_ROOT / 'docker-compose.override.yml'),
    'env': str(AEGIS_ROOT / '.env'),
    'registries': '/etc/containers/registries.conf',
    'logrotate': '/etc/logrotate.d/docker'
}

@app.route('/api/docker/configs')
def api_docker_configs():
    """Get status of all Docker configuration files"""
    configs = {}
    
    for name, path in DOCKER_CONFIG_PATHS.items():
        config_path = Path(path)
        try:
            if config_path.exists():
                stat = config_path.stat()
                configs[name] = {
                    'exists': True,
                    'path': str(config_path),
                    'size': f"{stat.st_size} bytes",
                    'modified': datetime.fromtimestamp(stat.st_mtime).isoformat()
                }
            else:
                configs[name] = {
                    'exists': False,
                    'path': str(config_path)
                }
        except Exception as e:
            configs[name] = {
                'exists': False,
                'error': str(e),
                'path': str(config_path)
            }
    
    return jsonify(configs)

@app.route('/api/docker/config/<config_type>')
def api_docker_config_get(config_type):
    """Get content of a Docker configuration file"""
    if config_type not in DOCKER_CONFIG_PATHS:
        return jsonify({'error': 'Unknown config type'}), 400
    
    path = Path(DOCKER_CONFIG_PATHS[config_type])
    
    # Default templates for files that don't exist
    templates = {
        'daemon': '''{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "live-restore": true
}''',
        'service': '''[Service]
# Add Docker service overrides here
# Environment="HTTP_PROXY=http://proxy.example.com:80"
''',
        'compose-override': '''version: '3.8'
# Override settings - merged with docker-compose.yaml
services: {}
''',
        'env': '''# Docker Compose Environment Variables
# Used by docker-compose.yaml
''',
        'registries': '''unqualified-search-registries = ["docker.io"]
''',
        'logrotate': '''/var/lib/docker/containers/*/*.log {
    rotate 7
    daily
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
'''
    }
    
    try:
        if path.exists():
            # Try reading with sudo if permission denied
            try:
                content = path.read_text()
            except PermissionError:
                result = subprocess.run(
                    ['sudo', 'cat', str(path)],
                    capture_output=True, text=True, timeout=10
                )
                if result.returncode == 0:
                    content = result.stdout
                else:
                    return jsonify({
                        'exists': True,
                        'path': str(path),
                        'content': '',
                        'error': 'Permission denied - run Shellder with sudo'
                    })
            
            return jsonify({
                'exists': True,
                'path': str(path),
                'content': content
            })
        else:
            return jsonify({
                'exists': False,
                'path': str(path),
                'template': templates.get(config_type, '# Configuration file\n')
            })
    except Exception as e:
        return jsonify({'error': str(e), 'path': str(path)}), 500

@app.route('/api/docker/config/<config_type>', methods=['POST'])
def api_docker_config_save(config_type):
    """Save a Docker configuration file"""
    if config_type not in DOCKER_CONFIG_PATHS:
        return jsonify({'success': False, 'error': 'Unknown config type'}), 400
    
    data = request.get_json()
    content = data.get('content', '')
    
    path = Path(DOCKER_CONFIG_PATHS[config_type])
    
    try:
        # Validate JSON for daemon.json
        if config_type == 'daemon':
            import json
            try:
                json.loads(content)
            except json.JSONDecodeError as e:
                return jsonify({
                    'success': False,
                    'error': f'Invalid JSON: {str(e)}'
                })
        
        # Create parent directory if needed
        if not path.parent.exists():
            subprocess.run(['sudo', 'mkdir', '-p', str(path.parent)], check=True)
        
        # Write file (may need sudo for system files)
        if str(path).startswith('/etc/'):
            # Use sudo for system files
            result = subprocess.run(
                ['sudo', 'tee', str(path)],
                input=content,
                capture_output=True,
                text=True,
                timeout=10
            )
            if result.returncode != 0:
                return jsonify({
                    'success': False,
                    'error': f'Failed to write: {result.stderr}'
                })
        else:
            # Direct write for user files
            path.write_text(content)
        
        # Reload systemd if service file was modified
        if config_type == 'service':
            subprocess.run(['sudo', 'systemctl', 'daemon-reload'], capture_output=True)
        
        return jsonify({
            'success': True,
            'path': str(path)
        })
        
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/docker/config/<config_type>/validate', methods=['POST'])
def api_docker_config_validate(config_type):
    """Validate a Docker configuration file"""
    data = request.get_json()
    content = data.get('content', '')
    
    try:
        if config_type == 'daemon':
            import json
            json.loads(content)
            return jsonify({'valid': True})
        
        elif config_type == 'compose-override':
            import yaml
            yaml.safe_load(content)
            return jsonify({'valid': True})
        
        else:
            # Basic syntax check - just verify it's not empty
            return jsonify({'valid': bool(content.strip())})
            
    except Exception as e:
        return jsonify({'valid': False, 'error': str(e)})

# =============================================================================
# DOCKER LOGGING CONFIGURATION (daemon.json editor)
# =============================================================================

DOCKER_DAEMON_DEFAULTS = {
    'log-driver': 'json-file',
    'log-opts': {
        'max-size': '100m',
        'max-file': '3',
        'compress': 'true'
    }
}

@app.route('/api/docker/logging/config')
def api_docker_logging_config():
    """Get current Docker daemon.json logging configuration"""
    daemon_json_path = '/etc/docker/daemon.json'
    
    result = {
        'exists': os.path.exists(daemon_json_path),
        'path': daemon_json_path,
        'current': {},
        'defaults': DOCKER_DAEMON_DEFAULTS,
        'can_read': False,
        'docker_running': False
    }
    
    # Check if Docker is running
    try:
        docker_check = subprocess.run(['systemctl', 'is-active', 'docker'], 
                                      capture_output=True, text=True, timeout=5)
        result['docker_running'] = docker_check.returncode == 0
    except:
        pass
    
    # Try to read current config
    if os.path.exists(daemon_json_path):
        try:
            # First try direct read
            with open(daemon_json_path, 'r') as f:
                result['current'] = json.load(f)
                result['can_read'] = True
        except PermissionError:
            # Try with sudo
            try:
                cat_result = subprocess.run(['sudo', 'cat', daemon_json_path],
                                           capture_output=True, text=True, timeout=10)
                if cat_result.returncode == 0:
                    result['current'] = json.loads(cat_result.stdout)
                    result['can_read'] = True
            except:
                pass
        except json.JSONDecodeError:
            result['parse_error'] = 'Invalid JSON in daemon.json'
        except Exception as e:
            result['error'] = str(e)
    
    # Merge current with defaults to show complete config
    merged = DOCKER_DAEMON_DEFAULTS.copy()
    if result['current']:
        merged.update(result['current'])
        if 'log-opts' in result['current']:
            merged['log-opts'] = {**DOCKER_DAEMON_DEFAULTS.get('log-opts', {}), 
                                  **result['current'].get('log-opts', {})}
    result['merged'] = merged
    
    return jsonify(result)

@app.route('/api/docker/logging/config', methods=['POST'])
def api_docker_logging_config_save():
    """Save Docker daemon.json logging configuration"""
    data = request.get_json()
    daemon_json_path = '/etc/docker/daemon.json'
    
    # Build the config from form data
    new_config = {}
    
    # Read existing config to preserve other settings
    if os.path.exists(daemon_json_path):
        try:
            cat_result = subprocess.run(['sudo', 'cat', daemon_json_path],
                                       capture_output=True, text=True, timeout=10)
            if cat_result.returncode == 0 and cat_result.stdout.strip():
                new_config = json.loads(cat_result.stdout)
        except:
            pass
    
    # Update logging settings from form
    if 'log_driver' in data:
        new_config['log-driver'] = data['log_driver']
    
    log_opts = new_config.get('log-opts', {})
    if 'max_size' in data:
        log_opts['max-size'] = data['max_size']
    if 'max_file' in data:
        log_opts['max-file'] = str(data['max_file'])
    if 'compress' in data:
        log_opts['compress'] = 'true' if data['compress'] else 'false'
    
    if log_opts:
        new_config['log-opts'] = log_opts
    
    # Convert to JSON
    config_json = json.dumps(new_config, indent=2)
    
    try:
        # Write using sudo tee (system file, keep root ownership)
        result = subprocess.run(
            ['sudo', 'tee', daemon_json_path],
            input=config_json,
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode != 0:
            return jsonify({
                'success': False,
                'error': f'Failed to write: {result.stderr}'
            }), 500
        
        return jsonify({
            'success': True,
            'config': new_config,
            'restart_required': True,
            'restart_command': 'sudo systemctl restart docker'
        })
        
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/docker/logging/restart', methods=['POST'])
def api_docker_logging_restart():
    """Restart Docker service to apply logging changes"""
    try:
        result = subprocess.run(
            ['sudo', 'systemctl', 'restart', 'docker'],
            capture_output=True,
            text=True,
            timeout=60
        )
        
        if result.returncode != 0:
            return jsonify({
                'success': False,
                'error': result.stderr or 'Failed to restart Docker'
            }), 500
        
        return jsonify({
            'success': True,
            'message': 'Docker service restarted successfully'
        })
        
    except subprocess.TimeoutExpired:
        return jsonify({
            'success': False,
            'error': 'Docker restart timed out'
        }), 500
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

# =============================================================================
# XILRIWS ENDPOINTS
# =============================================================================

@app.route('/api/xilriws/stats')
def api_xilriws_stats():
    """Get Xilriws proxy statistics"""
    stats = stats_collector.get_all_stats()
    return jsonify(stats.get('xilriws', {}))

@app.route('/api/xilriws/live')
def api_xilriws_live():
    """Stream Xilriws logs in real-time"""
    return api_container_logs_stream('xilriws')

@app.route('/api/xilriws/proxies')
def api_xilriws_proxies():
    """Get proxy list info"""
    # Check multiple possible locations for proxy file
    proxy_locations = [
        AEGIS_ROOT / 'xilriws' / 'proxies.txt',
        AEGIS_ROOT / 'unown' / 'proxies.txt',
    ]
    
    proxy_file = None
    for loc in proxy_locations:
        if loc.exists():
            proxy_file = loc
            break
    
    if not proxy_file:
        return jsonify({'exists': False, 'count': 0, 'proxies': [], 'content': '', 'file': str(proxy_locations[0])})
    
    try:
        with open(proxy_file, 'r') as f:
            content = f.read()
            lines = [l.strip() for l in content.split('\n') if l.strip() and not l.startswith('#')]
        
        return jsonify({
            'exists': True,
            'count': len(lines),
            'proxies': lines,
            'content': content,
            'file': str(proxy_file)
        })
    except Exception as e:
        return jsonify({'exists': False, 'error': str(e)})

@app.route('/api/xilriws/proxies', methods=['POST'])
def api_xilriws_proxies_save():
    """Save proxy list"""
    data = request.get_json()
    content = data.get('content', '')
    
    # Check for proxy file location
    proxy_file = AEGIS_ROOT / 'xilriws' / 'proxies.txt'
    if not proxy_file.parent.exists():
        proxy_file = AEGIS_ROOT / 'unown' / 'proxies.txt'
    
    try:
        with open(proxy_file, 'w') as f:
            f.write(content)
        
        lines = [l.strip() for l in content.split('\n') if l.strip() and not l.startswith('#')]
        return jsonify({
            'success': True,
            'count': len(lines),
            'file': str(proxy_file)
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/xilriws/container/<action>', methods=['POST'])
def api_xilriws_container_action(action):
    """Control Xilriws container"""
    if action not in ['start', 'stop', 'restart']:
        return jsonify({'success': False, 'error': 'Invalid action'})
    
    try:
        if docker_client:
            container = docker_client.containers.get('xilriws')
            if action == 'start':
                container.start()
            elif action == 'stop':
                container.stop()
            elif action == 'restart':
                container.restart()
            return jsonify({'success': True, 'action': action})
        else:
            # Fallback to subprocess
            result = subprocess.run(
                ['docker', action, 'xilriws'],
                capture_output=True, text=True, timeout=60
            )
            return jsonify({
                'success': result.returncode == 0,
                'output': result.stdout + result.stderr
            })
    except docker.errors.NotFound:
        return jsonify({'success': False, 'error': 'Xilriws container not found'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/xilriws/status')
def api_xilriws_container_status():
    """Get Xilriws container status"""
    try:
        if docker_client:
            container = docker_client.containers.get('xilriws')
            return jsonify({
                'running': container.status == 'running',
                'status': container.status,
                'name': container.name
            })
        else:
            result = subprocess.run(
                ['docker', 'inspect', '-f', '{{.State.Status}}', 'xilriws'],
                capture_output=True, text=True, timeout=10
            )
            status = result.stdout.strip()
            return jsonify({
                'running': status == 'running',
                'status': status or 'not found'
            })
    except docker.errors.NotFound:
        return jsonify({'running': False, 'status': 'not found'})
    except Exception as e:
        return jsonify({'running': False, 'status': 'error', 'error': str(e)})

# =============================================================================
# NGINX MANAGEMENT ENDPOINTS
# =============================================================================

@app.route('/api/nginx/status')
def api_nginx_status():
    """Get Nginx service status"""
    try:
        result = subprocess.run(
            ['systemctl', 'is-active', 'nginx'],
            capture_output=True, text=True, timeout=10
        )
        status = result.stdout.strip()
        
        # Get additional info
        version_result = subprocess.run(
            ['nginx', '-v'],
            capture_output=True, text=True, timeout=5
        )
        version = version_result.stderr.strip() if version_result.returncode == 0 else 'Unknown'
        
        return jsonify({
            'running': status == 'active',
            'status': status,
            'version': version
        })
    except Exception as e:
        return jsonify({'running': False, 'status': 'error', 'error': str(e)})

@app.route('/api/nginx/<action>', methods=['POST'])
def api_nginx_action(action):
    """Control Nginx service"""
    action_map = {
        'start': ['sudo', 'systemctl', 'start', 'nginx'],
        'stop': ['sudo', 'systemctl', 'stop', 'nginx'],
        'restart': ['sudo', 'systemctl', 'restart', 'nginx'],
        'reload': ['sudo', 'systemctl', 'reload', 'nginx'],
        'test': ['sudo', 'nginx', '-t']
    }
    
    if action not in action_map:
        return jsonify({'success': False, 'error': 'Invalid action'})
    
    try:
        result = subprocess.run(
            action_map[action],
            capture_output=True, text=True, timeout=30
        )
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/nginx/sites')
def api_nginx_sites():
    """Get list of nginx sites"""
    sites_enabled = Path('/etc/nginx/sites-enabled')
    sites_available = Path('/etc/nginx/sites-available')
    
    enabled = []
    available = []
    
    try:
        if sites_enabled.exists():
            for site in sites_enabled.iterdir():
                if site.name != 'default' or True:  # Include all
                    enabled.append({
                        'name': site.name,
                        'is_symlink': site.is_symlink(),
                        'target': str(site.resolve()) if site.is_symlink() else None
                    })
        
        if sites_available.exists():
            enabled_names = {s['name'] for s in enabled}
            for site in sites_available.iterdir():
                available.append({
                    'name': site.name,
                    'enabled': site.name in enabled_names
                })
        
        # Count SSL certs
        ssl_certs = 0
        letsencrypt = Path('/etc/letsencrypt/live')
        if letsencrypt.exists():
            ssl_certs = len([d for d in letsencrypt.iterdir() if d.is_dir()])
        
        return jsonify({
            'enabled': enabled,
            'available': available,
            'enabled_count': len(enabled),
            'available_count': len(available),
            'ssl_certs': ssl_certs
        })
    except Exception as e:
        return jsonify({'error': str(e), 'enabled': [], 'available': []})

@app.route('/api/nginx/site/<name>')
def api_nginx_site_config(name):
    """Get site configuration"""
    # Try sites-enabled first, then sites-available
    for path in [Path('/etc/nginx/sites-enabled') / name, Path('/etc/nginx/sites-available') / name]:
        if path.exists():
            try:
                # Resolve symlinks
                actual_path = path.resolve()
                with open(actual_path, 'r') as f:
                    return jsonify({
                        'name': name,
                        'content': f.read(),
                        'path': str(actual_path),
                        'enabled': 'sites-enabled' in str(path)
                    })
            except Exception as e:
                return jsonify({'error': str(e)})
    
    return jsonify({'error': 'Site not found'})

@app.route('/api/nginx/site/<name>', methods=['POST'])
def api_nginx_site_save(name):
    """Save site configuration"""
    data = request.get_json()
    content = data.get('content', '')
    
    site_path = Path('/etc/nginx/sites-available') / name
    
    try:
        # Use sudo to write file
        result = subprocess.run(
            ['sudo', 'tee', str(site_path)],
            input=content,
            capture_output=True, text=True, timeout=10
        )
        
        if result.returncode != 0:
            return jsonify({'success': False, 'error': result.stderr})
        
        return jsonify({'success': True, 'path': str(site_path)})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/nginx/site/<name>/enable', methods=['POST'])
def api_nginx_site_enable(name):
    """Enable a site (create symlink)"""
    available = Path('/etc/nginx/sites-available') / name
    enabled = Path('/etc/nginx/sites-enabled') / name
    
    if not available.exists():
        return jsonify({'success': False, 'error': 'Site not found in sites-available'})
    
    try:
        result = subprocess.run(
            ['sudo', 'ln', '-sf', str(available), str(enabled)],
            capture_output=True, text=True, timeout=10
        )
        return jsonify({'success': result.returncode == 0, 'output': result.stderr})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/nginx/site/<name>/disable', methods=['POST'])
def api_nginx_site_disable(name):
    """Disable a site (remove symlink)"""
    enabled = Path('/etc/nginx/sites-enabled') / name
    
    if not enabled.exists():
        return jsonify({'success': False, 'error': 'Site not enabled'})
    
    try:
        result = subprocess.run(
            ['sudo', 'rm', str(enabled)],
            capture_output=True, text=True, timeout=10
        )
        return jsonify({'success': result.returncode == 0, 'output': result.stderr})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/nginx/logs')
def api_nginx_logs():
    """Get nginx error logs"""
    lines = request.args.get('lines', 100, type=int)
    log_path = Path('/var/log/nginx/error.log')
    
    if not log_path.exists():
        return jsonify({'logs': 'Nginx error log not found', 'lines': 0})
    
    try:
        result = subprocess.run(
            ['sudo', 'tail', '-n', str(lines), str(log_path)],
            capture_output=True, text=True, timeout=10
        )
        return jsonify({'logs': result.stdout, 'lines': lines})
    except Exception as e:
        return jsonify({'logs': f'Error reading logs: {e}', 'lines': 0})

@app.route('/api/nginx/setup', methods=['POST'])
def api_nginx_setup():
    """Run nginx setup for a domain"""
    data = request.get_json()
    domain = data.get('domain')
    email = data.get('email')
    service = data.get('service', 'reactmap:6001')
    custom_port = data.get('custom_port')
    
    if not domain:
        return jsonify({'success': False, 'error': 'Domain is required'})
    
    # Parse service
    if service == 'custom' and custom_port:
        port = custom_port
    else:
        port = service.split(':')[-1] if ':' in service else '6001'
    
    # Generate nginx config
    config = f"""server {{
    listen 80;
    server_name {domain};
    
    location / {{
        proxy_pass http://localhost:{port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }}
}}
"""
    
    try:
        # Save config
        site_path = f'/etc/nginx/sites-available/{domain}'
        result = subprocess.run(
            ['sudo', 'tee', site_path],
            input=config,
            capture_output=True, text=True, timeout=10
        )
        
        if result.returncode != 0:
            return jsonify({'success': False, 'error': f'Failed to save config: {result.stderr}'})
        
        # Enable site
        subprocess.run(
            ['sudo', 'ln', '-sf', site_path, f'/etc/nginx/sites-enabled/{domain}'],
            capture_output=True, timeout=10
        )
        
        # Test config
        test_result = subprocess.run(
            ['sudo', 'nginx', '-t'],
            capture_output=True, text=True, timeout=10
        )
        
        if test_result.returncode != 0:
            return jsonify({
                'success': False, 
                'error': f'Nginx config test failed: {test_result.stderr}',
                'stage': 'test'
            })
        
        # Reload nginx
        subprocess.run(['sudo', 'systemctl', 'reload', 'nginx'], timeout=10)
        
        # Try to get SSL cert if email provided
        ssl_output = ''
        if email:
            ssl_result = subprocess.run(
                ['sudo', 'certbot', '--nginx', '-d', domain, '--non-interactive', 
                 '--agree-tos', '-m', email, '--redirect'],
                capture_output=True, text=True, timeout=120
            )
            ssl_output = ssl_result.stdout + ssl_result.stderr
            if ssl_result.returncode != 0:
                return jsonify({
                    'success': True,
                    'warning': 'Site configured but SSL failed',
                    'ssl_output': ssl_output
                })
        
        return jsonify({
            'success': True,
            'domain': domain,
            'port': port,
            'ssl': bool(email),
            'ssl_output': ssl_output
        })
        
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

# =============================================================================
# SETUP & CONFIG MANAGER API
# =============================================================================
# Setup status, config file management, environment variables, GitHub integration

# Define required config files and their purposes
REQUIRED_CONFIGS = {
    '.env': {
        'name': 'Environment Variables',
        'description': 'Main configuration file with passwords and secrets',
        'template': 'env-default',
        'critical': True,
        'category': 'core'
    },
    'docker-compose.yaml': {
        'name': 'Docker Compose',
        'description': 'Defines all container services',
        'template': None,
        'critical': True,
        'category': 'core'
    },
    'unown/dragonite_config.toml': {
        'name': 'Dragonite Config',
        'description': 'Scanner coordinator configuration',
        'template': 'unown/dragonite_config-default.toml',
        'critical': False,
        'category': 'scanner'
    },
    'unown/golbat_config.toml': {
        'name': 'Golbat Config',
        'description': 'Data processor configuration',
        'template': 'unown/golbat_config-default.toml',
        'critical': False,
        'category': 'scanner'
    },
    'unown/rotom_config.json': {
        'name': 'Rotom Config',
        'description': 'Device manager configuration',
        'template': 'unown/rotom_config-default.json',
        'critical': False,
        'category': 'scanner'
    },
    'reactmap/local.json': {
        'name': 'ReactMap Config',
        'description': 'Map frontend configuration',
        'template': 'reactmap/local-default.json',
        'critical': False,
        'category': 'frontend'
    },
    'fletchling.toml': {
        'name': 'Fletchling Config',
        'description': 'Pokemon nesting service configuration',
        'template': None,
        'critical': False,
        'category': 'optional'
    },
    'Poracle/config/local.json': {
        'name': 'Poracle Config',
        'description': 'Alert/notification service configuration',
        'template': None,
        'critical': False,
        'category': 'optional'
    },
    'mysql_data/mariadb.cnf': {
        'name': 'MariaDB Config',
        'description': 'Database server configuration',
        'template': None,
        'critical': False,
        'category': 'database'
    },
    'init/01.sql': {
        'name': 'Database Init',
        'description': 'Initial database schema',
        'template': None,
        'critical': True,
        'category': 'database'
    }
}

# =============================================================================
# COMPREHENSIVE PASSWORD/SECRET DEFINITIONS
# =============================================================================
# Maps all secrets from setup.sh to their target files and replacement patterns
# This enables the GUI to properly apply passwords to ALL config files

AEGIS_SECRETS = {
    # Database Credentials
    'MYSQL_USER': {
        'label': 'Database Username',
        'desc': 'Username for all services to connect to MariaDB',
        'default_placeholder': 'dbuser',
        'category': 'database',
        'color': '#3b82f6',
        'targets': [
            {'file': '.env', 'pattern': 'MYSQL_USER=(.*)'},
            {'file': 'unown/dragonite_config.toml', 'pattern': 'user = "(.*)"', 'section': 'db.dragonite'},
            {'file': 'unown/golbat_config.toml', 'pattern': 'user = "(.*)"', 'section': 'database'},
            {'file': 'reactmap/local.json', 'json_path': 'database.schemas[*].username'},
            {'file': 'Poracle/config/local.json', 'json_path': 'database.client.user'},
            {'file': 'init/01.sql', 'pattern': "'dbuser'@", 'replace_with': "'{value}'@"},
        ]
    },
    'MYSQL_PASSWORD': {
        'label': 'Database Password',
        'desc': 'Password for database user account',
        'default_placeholder': 'SuperSecuredbuserPassword',
        'category': 'database',
        'color': '#3b82f6',
        'generate_length': 32,
        'targets': [
            {'file': '.env', 'pattern': 'MYSQL_PASSWORD=(.*)'},
            {'file': 'unown/dragonite_config.toml', 'pattern': 'password = "(.*)"', 'section': 'db.dragonite'},
            {'file': 'unown/golbat_config.toml', 'pattern': 'password = "(.*)"', 'section': 'database'},
            {'file': 'reactmap/local.json', 'json_path': 'database.schemas[*].password'},
            {'file': 'Poracle/config/local.json', 'json_path': 'database.client.password'},
            {'file': 'init/01.sql', 'pattern': "IDENTIFIED BY '(.*)'"},
        ]
    },
    'MYSQL_ROOT_PASSWORD': {
        'label': 'MySQL Root Password',
        'desc': 'Root/admin password for MariaDB server',
        'default_placeholder': 'V3ryS3cUr3MYSQL_ROOT_P4ssw0rd',
        'category': 'database',
        'color': '#dc2626',
        'generate_length': 32,
        'targets': [
            {'file': '.env', 'pattern': 'MYSQL_ROOT_PASSWORD=(.*)'},
        ]
    },
    
    # Koji
    'KOJI_SECRET': {
        'label': 'Koji Bearer Token',
        'desc': 'API token for accessing Koji geofence data',
        'default_placeholder': 'SuperSecureKojiSecret',
        'category': 'api',
        'color': '#8b5cf6',
        'generate_length': 32,
        'targets': [
            {'file': '.env', 'pattern': 'KOJI_SECRET=(.*)'},
            {'file': 'unown/dragonite_config.toml', 'pattern': 'bearer_token = "(.*)"', 'section': 'koji'},
            {'file': 'unown/golbat_config.toml', 'pattern': 'bearer_token = "(.*)"', 'section': 'koji'},
            {'file': 'reactmap/local.json', 'json_path': 'api.kojiOptions.bearerToken'},
        ]
    },
    
    # Golbat Secrets
    'GOLBAT_API_SECRET': {
        'label': 'Golbat API Secret',
        'desc': 'Password to REQUEST data FROM Golbat (used by ReactMap, Dragonite)',
        'default_placeholder': 'SuperSecureGolbatApiSecret',
        'category': 'api',
        'color': '#10b981',
        'generate_length': 32,
        'targets': [
            {'file': '.env', 'pattern': 'GOLBAT_API_SECRET=(.*)'},
            {'file': 'unown/dragonite_config.toml', 'pattern': 'golbat_api_secret = "(.*)"', 'section': 'processors'},
            {'file': 'unown/golbat_config.toml', 'pattern': 'api_secret = "(.*)"'},
            {'file': 'reactmap/local.json', 'json_path': 'database.schemas[type=golbat].secret'},
        ]
    },
    'GOLBAT_RAW_SECRET': {
        'label': 'Golbat Raw Bearer',
        'desc': 'Password to SEND data TO Golbat (used by Dragonite)',
        'default_placeholder': 'SuperSecureGolbatRawSecret',
        'category': 'api',
        'color': '#f59e0b',
        'generate_length': 32,
        'targets': [
            {'file': '.env', 'pattern': 'GOLBAT_RAW_SECRET=(.*)'},
            {'file': 'unown/dragonite_config.toml', 'pattern': 'golbat_raw_bearer = "(.*)"', 'section': 'processors'},
            {'file': 'unown/golbat_config.toml', 'pattern': 'raw_bearer = "(.*)"'},
        ]
    },
    
    # Dragonite Secrets
    'DRAGONITE_PASSWORD': {
        'label': 'Dragonite Admin Password',
        'desc': 'Password to access Dragonite web panel (port 6002)',
        'default_placeholder': 'SuperSecureDragoniteAdminPassword',
        'category': 'api',
        'color': '#06b6d4',
        'generate_length': 32,
        'targets': [
            {'file': '.env', 'pattern': 'DRAGONITE_PASSWORD=(.*)'},
        ]
    },
    'DRAGONITE_API_SECRET': {
        'label': 'Dragonite API Secret',
        'desc': 'Secret for programmatic access to Dragonite API',
        'default_placeholder': 'SuperSecureDragoniteApiSecret',
        'category': 'api',
        'color': '#06b6d4',
        'generate_length': 32,
        'targets': [
            {'file': '.env', 'pattern': 'DRAGONITE_API_SECRET=(.*)'},
        ]
    },
    
    # ReactMap Secrets
    'SESSION_SECRET': {
        'label': 'ReactMap Session Secret',
        'desc': 'Secret key for ReactMap session encryption',
        'default_placeholder': '98ki^e72~!@#(85o3kXLI*#c9wu5l!ZUGA',
        'category': 'api',
        'color': '#ec4899',
        'generate_length': 40,
        'targets': [
            {'file': '.env', 'pattern': 'SESSION_SECRET=(.*)'},
            {'file': 'reactmap/local.json', 'json_path': 'api.sessionSecret'},
        ]
    },
    'REACTMAP_SECRET': {
        'label': 'ReactMap API Secret',
        'desc': 'Additional API secret for ReactMap',
        'default_placeholder': '98ki^e72~!@#(85o3kXLI*#c9wu5l!Zx10venikyoa0',
        'category': 'api',
        'color': '#ec4899',
        'generate_length': 40,
        'targets': [
            {'file': 'reactmap/local.json', 'json_path': 'api.reactMapSecret'},
        ]
    },
    
    # Rotom Secret
    'ROTOM_AUTH_BEARER': {
        'label': 'Rotom Device Auth',
        'desc': 'Password devices use to connect to Rotom (set in Aegis app)',
        'default_placeholder': 'SuperSecretAuthBearerForAegisDevices',
        'category': 'api',
        'color': '#ef4444',
        'generate_length': 32,
        'targets': [
            {'file': '.env', 'pattern': 'ROTOM_AUTH_BEARER=(.*)'},
            {'file': 'unown/rotom_config.json', 'json_path': 'deviceListener.secret'},
        ]
    },
    
    # Poracle Secret
    'PORACLE_API_SECRET': {
        'label': 'Poracle API Secret',
        'desc': 'Secret for ReactMap to communicate with Poracle alerts',
        'default_placeholder': 'SuperSecurePoracleApiSecret',
        'category': 'api',
        'color': '#a855f7',
        'generate_length': 32,
        'targets': [
            {'file': '.env', 'pattern': 'PORACLE_API_SECRET=(.*)'},
            {'file': 'reactmap/local.json', 'json_path': 'webhooks[0].poracleSecret'},
        ]
    },
}

# =============================================================================
# CONFIG VARIABLES STATUS - ONLY variables that MUST be set from defaults
# =============================================================================
# These are the secrets/passwords that get replaced by setup.sh
# Service URLs and other settings have good defaults and don't need to be shown

# Default placeholder values that indicate "not configured"
DEFAULT_PLACEHOLDERS = {
    'V3ryS3cUr3MYSQL_ROOT_P4ssw0rd',
    'SuperSecuredbuserPassword', 
    'SuperSecureKojiSecret',
    'SuperSecureGolbatRawSecret',
    'SuperSecureGolbatApiSecret',
    'SuperSecureDragoniteAdminPassword',
    'SuperSecureDragoniteApiSecret',
    'SuperSecureSessionSecret',
    'SuperSecureReactMapSecret',
    'SuperSecureRotomAuthBearer',
    'SuperSecurePoracleSecret',
    'dbuser',  # Default username placeholder
    'changeme',
    'CHANGE_ME',
    ''
}

# Categories of config variables - ONLY secrets that MUST be changed
CONFIG_VARIABLE_CATEGORIES = {
    'database': {
        'title': '🗄️ Database Credentials',
        'icon': '🗄️',
        'desc': 'Database authentication - must be set and match across all configs',
        'variables': {
            'MYSQL_ROOT_PASSWORD': {
                'label': 'MariaDB Root Password', 
                'required': True, 
                'source': '.env', 
                'secret': True,
                'desc': 'Master database password for admin operations'
            },
            'MYSQL_USER': {
                'label': 'Database Username', 
                'required': True, 
                'source': '.env', 
                'shared': True,
                'desc': 'Username for all services to connect to database'
            },
            'MYSQL_PASSWORD': {
                'label': 'Database Password', 
                'required': True, 
                'source': '.env', 
                'secret': True, 
                'shared': True,
                'desc': 'Password for the database user account'
            },
        }
    },
    'secrets': {
        'title': '🔐 Service Secrets',
        'icon': '🔐',
        'desc': 'API tokens that services use to authenticate with each other',
        'variables': {
            'KOJI_SECRET': {
                'label': 'Koji Bearer Token', 
                'required': True, 
                'source': '.env', 
                'secret': True, 
                'shared': True,
                'desc': 'Token for accessing Koji geofence data'
            },
            'GOLBAT_API_SECRET': {
                'label': 'Golbat API Secret', 
                'required': True, 
                'source': '.env', 
                'secret': True, 
                'shared': True,
                'desc': 'Token to REQUEST data from Golbat'
            },
            'GOLBAT_RAW_SECRET': {
                'label': 'Golbat Raw Bearer', 
                'required': True, 
                'source': '.env', 
                'secret': True, 
                'shared': True,
                'desc': 'Token to SEND data to Golbat'
            },
            'DRAGONITE_PASSWORD': {
                'label': 'Dragonite Admin Password', 
                'required': True, 
                'source': '.env', 
                'secret': True,
                'desc': 'Login password for Dragonite web panel'
            },
            'DRAGONITE_API_SECRET': {
                'label': 'Dragonite API Secret', 
                'required': True, 
                'source': '.env', 
                'secret': True,
                'desc': 'Token for programmatic Dragonite access'
            },
            'REACTMAP_SECRET': {
                'label': 'ReactMap Session Secret', 
                'required': True, 
                'source': '.env', 
                'secret': True,
                'desc': 'Session encryption key for ReactMap'
            },
            'ROTOM_AUTH_BEARER': {
                'label': 'Rotom Device Auth', 
                'required': True, 
                'source': '.env', 
                'secret': True,
                'desc': 'Token devices use to connect to Rotom'
            },
        }
    }
}

# Mapping of where shared variables appear in each config file (from setup.sh)
# These are the ONLY variables that MUST be set - they are replaced by sed in setup.sh
SHARED_VARIABLE_PATHS = {
    'MYSQL_USER': {
        '.env': 'MYSQL_USER',
        'unown/dragonite_config.toml': 'db.dragonite.user',
        'unown/golbat_config.toml': 'database.user',
        'reactmap/local.json': 'database.schemas.1.username',  # schemas[1] has DB config
        'unown/rotom_config.json': None,  # Rotom doesn't use DB directly
        'Poracle/config/local.json': 'database.client.user',
        'init/01.sql': None  # Special handling via template
    },
    'MYSQL_PASSWORD': {
        '.env': 'MYSQL_PASSWORD',
        'unown/dragonite_config.toml': 'db.dragonite.password',
        'unown/golbat_config.toml': 'database.password',
        'reactmap/local.json': 'database.schemas.1.password',  # schemas[1] has DB config
        'Poracle/config/local.json': 'database.client.password',
        'init/01.sql': None  # Special handling via template
    },
    'KOJI_SECRET': {
        '.env': 'KOJI_SECRET',
        'unown/dragonite_config.toml': 'koji.bearer_token',
        'unown/golbat_config.toml': 'koji.bearer_token',
        'reactmap/local.json': 'api.kojiSecret'
    },
    'GOLBAT_API_SECRET': {
        '.env': 'GOLBAT_API_SECRET',
        'unown/dragonite_config.toml': 'processors.golbat_api_secret',
        'unown/golbat_config.toml': 'api_secret',
        'reactmap/local.json': 'api.golbatSecret'
    },
    'GOLBAT_RAW_SECRET': {
        '.env': 'GOLBAT_RAW_SECRET',
        'unown/dragonite_config.toml': 'processors.golbat_raw_bearer',
        'unown/golbat_config.toml': 'raw_bearer'
    },
    'ROTOM_AUTH_BEARER': {
        '.env': 'ROTOM_AUTH_BEARER',
        'unown/rotom_config.json': 'deviceListener.secret'
    }
}

# Shared field indicators (simplified for config editor display)
SHARED_FIELDS = {
    'db_user': {
        'configs': ['unown/dragonite_config.toml', 'unown/golbat_config.toml', 'reactmap/local.json'],
        'label': 'Database Username',
        'desc': 'Must match MYSQL_USER in .env - used by all services',
        'color': '#3b82f6',
        'secret_key': 'MYSQL_USER'
    },
    'db_password': {
        'configs': ['unown/dragonite_config.toml', 'unown/golbat_config.toml', 'reactmap/local.json'],
        'label': 'Database Password',
        'desc': 'Must match MYSQL_PASSWORD in .env - used by all services',
        'color': '#3b82f6',
        'secret_key': 'MYSQL_PASSWORD'
    },
    'koji_secret': {
        'configs': ['unown/dragonite_config.toml', 'unown/golbat_config.toml', 'reactmap/local.json'],
        'label': 'Koji Bearer Token',
        'desc': 'Must match KOJI_SECRET in .env - used to access Koji geofences',
        'color': '#8b5cf6',
        'secret_key': 'KOJI_SECRET'
    },
    'golbat_api_secret': {
        'configs': ['unown/dragonite_config.toml', 'unown/golbat_config.toml', 'reactmap/local.json'],
        'label': 'Golbat API Secret',
        'desc': 'Must match across configs - Dragonite/ReactMap use this to request data from Golbat',
        'color': '#10b981',
        'secret_key': 'GOLBAT_API_SECRET'
    },
    'golbat_raw_secret': {
        'configs': ['unown/dragonite_config.toml', 'unown/golbat_config.toml'],
        'label': 'Golbat Raw Bearer',
        'desc': 'Must match across configs - Dragonite uses this to SEND data to Golbat',
        'color': '#f59e0b',
        'secret_key': 'GOLBAT_RAW_SECRET'
    },
    'rotom_device_secret': {
        'configs': ['unown/rotom_config.json'],
        'label': 'Device Auth Secret',
        'desc': 'Devices use this to authenticate with Rotom',
        'color': '#ef4444',
        'secret_key': 'ROTOM_AUTH_BEARER'
    }
}

# Config field schemas for form-based editing - COMPLETE with all fields
CONFIG_FIELD_SCHEMAS = {
    'unown/dragonite_config.toml': {
        'format': 'toml',
        'sections': {
            'general': {
                'title': '🔧 General Settings',
                'desc': 'Core Dragonite server configuration',
                'fields': {
                    'login_delay': {'type': 'number', 'label': 'Login Delay', 'desc': 'Seconds between account logins on same proxy (0=no delay, higher=safer)', 'default': 0},
                    'token_init_enabled': {'type': 'checkbox', 'label': 'Pre-auth Accounts', 'desc': 'Prepare accounts in background before needed (faster switching)', 'default': True, 'optional': True},
                    'stats': {'type': 'checkbox', 'label': 'Enable Stats', 'desc': 'Record detailed worker performance statistics', 'default': True},
                    'api_host': {'type': 'text', 'label': 'API Host', 'desc': 'Network address to listen on (0.0.0.0 = all interfaces)', 'default': '0.0.0.0'},
                    'api_port': {'type': 'number', 'label': 'API Port', 'desc': 'Port for web interface and API (Docker maps externally)', 'default': 7272},
                    'remote_auth_url': {'type': 'text', 'label': 'Auth Service URL', 'desc': 'Xilriws login helper URL for Pokemon GO authentication', 'default': 'http://xilriws:5090/api/v1/login-code'},
                }
            },
            'auth.ptc': {
                'title': '🎮 PTC Account Settings',
                'desc': 'Pokemon Trainer Club account configuration',
                'fields': {
                    'enable': {'type': 'checkbox', 'label': 'Enable PTC', 'desc': 'Allow PTC accounts for scanning', 'default': True},
                    'login_delay': {'type': 'number', 'label': 'PTC Login Delay', 'desc': 'Seconds between PTC logins (120=safe, lower=faster but riskier)', 'default': 120},
                    'token_init_enabled': {'type': 'checkbox', 'label': 'Pre-auth Accounts', 'desc': 'Prepare accounts before needed (faster switching)', 'default': True},
                    'remote_auth_url': {'type': 'text', 'label': 'PTC Auth URL', 'desc': 'Auth service specifically for PTC accounts', 'default': 'http://xilriws:5090/api/v1/login-code'},
                    'token_refresh_only': {'type': 'checkbox', 'label': 'Token Refresh Only', 'desc': 'Only use accounts with valid cached tokens (safer)', 'default': True},
                }
            },
            'auth.nk': {
                'title': '🎮 Nintendo/Google Account Settings',
                'desc': 'Nintendo-linked or Google-linked account configuration',
                'fields': {
                    'enable': {'type': 'checkbox', 'label': 'Enable NK', 'desc': 'Allow Nintendo/Google linked accounts', 'default': False},
                    'login_delay': {'type': 'number', 'label': 'NK Login Delay', 'desc': 'Seconds between NK login attempts', 'default': 20, 'optional': True},
                    'token_init_enabled': {'type': 'checkbox', 'label': 'Pre-auth Accounts', 'desc': 'Prepare accounts before needed', 'default': True},
                    'token_refresh_only': {'type': 'checkbox', 'label': 'Token Refresh Only', 'desc': 'Only use accounts with valid cached tokens', 'default': True},
                }
            },
            'koji': {
                'title': '🗺️ Koji Geofence Connection',
                'desc': 'Connection to Koji for scan area definitions',
                'fields': {
                    'url': {'type': 'text', 'label': 'Koji URL', 'desc': 'Internal Docker address of Koji service', 'default': 'http://koji:8080'},
                    'bearer_token': {'type': 'password', 'label': 'Koji Bearer Token', 'desc': 'Must match KOJI_SECRET in .env', 'default': '', 'shared': 'koji_secret'},
                }
            },
            'prometheus': {
                'title': '📊 Prometheus Metrics',
                'desc': 'Performance monitoring for Grafana dashboards',
                'fields': {
                    'enabled': {'type': 'checkbox', 'label': 'Enable Metrics', 'desc': 'Send stats to Prometheus (needed for Grafana)', 'default': True},
                }
            },
            'tuning': {
                'title': '⚙️ Account Tuning',
                'desc': 'Control how aggressively accounts are used',
                'fields': {
                    'recycle_gmo_limit': {'type': 'number', 'label': 'GMO Limit', 'desc': 'Max map requests before rotating account (lower=safer, higher=faster)', 'default': 4900, 'optional': True},
                    'recycle_encounter_limit': {'type': 'number', 'label': 'Encounter Limit', 'desc': 'Max Pokemon encounters before rotating account', 'default': 9900, 'optional': True},
                    'recycle_on_jail': {'type': 'checkbox', 'label': 'Recycle Jailed', 'desc': 'Put jailed accounts back in rotation after cooldown', 'default': False},
                    'minimum_account_reuse_hours': {'type': 'number', 'label': 'Account Reuse Hours', 'desc': 'Hours an account must rest before reuse (72=3 days)', 'default': 72},
                    'location_delay': {'type': 'number', 'label': 'Location Delay (ms)', 'desc': 'Milliseconds to wait between location updates', 'default': 0, 'optional': True},
                    'fort_location_delay': {'type': 'number', 'label': 'Fort Location Delay (ms)', 'desc': 'Delay for gym/pokestop scanning', 'default': 0, 'optional': True},
                    'scout_age_limit': {'type': 'number', 'label': 'Scout Age Limit (sec)', 'desc': 'How old encounter data can be before refresh', 'default': 30, 'optional': True},
                }
            },
            'accounts': {
                'title': '👤 Account Requirements',
                'desc': 'Level requirements for scanning accounts',
                'fields': {
                    'required_level': {'type': 'number', 'label': 'Required Level', 'desc': 'Minimum level for most scanning (30 for IV, 31+ for some quests)', 'default': 30, 'optional': True},
                    'leveling_level': {'type': 'number', 'label': 'Leveling Target', 'desc': 'Stop auto-leveling accounts at this level', 'default': 31, 'optional': True},
                }
            },
            'rotom': {
                'title': '📱 Rotom Device Manager',
                'desc': 'Connection to Rotom for device management',
                'fields': {
                    'endpoint': {'type': 'text', 'label': 'Rotom Endpoint', 'desc': 'WebSocket address for Rotom controller', 'default': 'ws://rotom:7071'},
                }
            },
            'logging': {
                'title': '📝 Logging',
                'desc': 'Debug and log file settings',
                'fields': {
                    'save': {'type': 'checkbox', 'label': 'Save Logs', 'desc': 'Write logs to files (needed for Blissey stats)', 'default': False},
                    'debug': {'type': 'checkbox', 'label': 'Debug Mode', 'desc': 'Enable verbose debug logging (only for troubleshooting)', 'default': False, 'optional': True},
                    'max_size': {'type': 'number', 'label': 'Max Log Size (MB)', 'desc': 'Maximum log file size before rotation', 'default': 500, 'optional': True},
                    'max_age': {'type': 'number', 'label': 'Max Log Age (Days)', 'desc': 'Delete log files older than this', 'default': 30, 'optional': True},
                }
            },
            'processors': {
                'title': '🔄 Data Processors',
                'desc': 'Golbat connection for data processing',
                'fields': {
                    'golbat_endpoint': {'type': 'text', 'label': 'Golbat HTTP', 'desc': 'Golbat HTTP address for sending data', 'default': 'http://golbat:9001'},
                    'golbat_raw_bearer': {'type': 'password', 'label': 'Golbat Raw Bearer', 'desc': 'Password to SEND raw data to Golbat', 'default': '', 'shared': 'golbat_raw_secret'},
                    'golbat_api_secret': {'type': 'password', 'label': 'Golbat API Secret', 'desc': 'Password to REQUEST data from Golbat', 'default': '', 'shared': 'golbat_api_secret'},
                    'golbat_grpc_endpoint': {'type': 'text', 'label': 'Golbat gRPC', 'desc': 'Faster data transfer via gRPC (optional)', 'default': 'golbat:50001'},
                }
            },
            'db.dragonite': {
                'title': '🗄️ Dragonite Database',
                'desc': 'Database for Dragonite accounts and settings',
                'fields': {
                    'host': {'type': 'text', 'label': 'DB Host', 'desc': 'Database server (use "database" for Docker)', 'default': 'database'},
                    'port': {'type': 'number', 'label': 'DB Port', 'desc': 'Database port (3306 standard)', 'default': 3306},
                    'user': {'type': 'text', 'label': 'DB Username', 'desc': 'Must match MYSQL_USER in .env', 'default': 'dbuser', 'shared': 'db_user'},
                    'password': {'type': 'password', 'label': 'DB Password', 'desc': 'Must match MYSQL_PASSWORD in .env', 'default': '', 'shared': 'db_password'},
                    'name': {'type': 'text', 'label': 'DB Name', 'desc': 'Database name for Dragonite data', 'default': 'dragonite'},
                    'pool_size': {'type': 'number', 'label': 'Pool Size', 'desc': 'Number of database connections to maintain', 'default': 1},
                }
            },
        }
    },
    'unown/golbat_config.toml': {
        'format': 'toml',
        'sections': {
            'root': {
                'title': '🌐 Network & Security',
                'desc': 'Ports and authentication for Golbat services',
                'fields': {
                    'port': {'type': 'number', 'label': 'HTTP Port', 'desc': 'Port for incoming data and API requests', 'default': 9001},
                    'grpc_port': {'type': 'number', 'label': 'gRPC Port', 'desc': 'Faster communication port using gRPC protocol', 'default': 50001},
                    'raw_bearer': {'type': 'password', 'label': 'Raw Bearer', 'desc': 'Password required to SEND data TO Golbat', 'default': '', 'shared': 'golbat_raw_secret'},
                    'api_secret': {'type': 'password', 'label': 'API Secret', 'desc': 'Password required to REQUEST data FROM Golbat', 'default': '', 'shared': 'golbat_api_secret'},
                    'pokemon_memory_only': {'type': 'checkbox', 'label': 'Memory Only', 'desc': 'Keep Pokemon in RAM only (faster but lost on restart)', 'default': False},
                }
            },
            'koji': {
                'title': '🗺️ Koji Geofence',
                'desc': 'Geofence/area configuration from Koji',
                'fields': {
                    'url': {'type': 'text', 'label': 'Koji Geofence URL', 'desc': 'URL to fetch geofence definitions (include project name)', 'default': 'http://koji:8080/api/v1/geofence/feature-collection/Mapping'},
                    'bearer_token': {'type': 'password', 'label': 'Koji Bearer Token', 'desc': 'Must match KOJI_SECRET in .env', 'default': '', 'shared': 'koji_secret'},
                }
            },
            'cleanup': {
                'title': '🧹 Database Cleanup',
                'desc': 'Automatic deletion of old data',
                'fields': {
                    'pokemon': {'type': 'checkbox', 'label': 'Clean Pokemon', 'desc': 'Delete Pokemon after they despawn', 'default': True},
                    'incidents': {'type': 'checkbox', 'label': 'Clean Incidents', 'desc': 'Remove Team Rocket invasions after expiry', 'default': True},
                    'quests': {'type': 'checkbox', 'label': 'Clean Quests', 'desc': 'Remove quests after midnight reset', 'default': True},
                    'stats': {'type': 'checkbox', 'label': 'Track Stats', 'desc': 'Keep historical statistics', 'default': True},
                    'stats_days': {'type': 'number', 'label': 'Stats Retention Days', 'desc': 'Days to keep statistics history', 'default': 365},
                    'device_hours': {'type': 'number', 'label': 'Device Cleanup Hours', 'desc': 'Remove inactive devices after X hours', 'default': 24},
                }
            },
            'logging': {
                'title': '📝 Logging',
                'desc': 'Debug and log file settings',
                'fields': {
                    'debug': {'type': 'checkbox', 'label': 'Debug Mode', 'desc': 'Enable verbose debug logging', 'default': False},
                    'save_logs': {'type': 'checkbox', 'label': 'Save to Files', 'desc': 'Write logs to disk files', 'default': False},
                    'max_size': {'type': 'number', 'label': 'Max Log Size (MB)', 'desc': 'Maximum size before rotating', 'default': 50},
                    'max_backups': {'type': 'number', 'label': 'Max Backups', 'desc': 'Number of old log files to keep', 'default': 10},
                    'max_age': {'type': 'number', 'label': 'Max Age (Days)', 'desc': 'Delete logs older than this', 'default': 30},
                    'compress': {'type': 'checkbox', 'label': 'Compress Logs', 'desc': 'Gzip old log files to save space', 'default': True},
                }
            },
            'database': {
                'title': '🗄️ Database',
                'desc': 'Where Golbat stores all Pokemon data',
                'fields': {
                    'user': {'type': 'text', 'label': 'DB Username', 'desc': 'Must match MYSQL_USER in .env', 'default': 'dbuser', 'shared': 'db_user'},
                    'password': {'type': 'password', 'label': 'DB Password', 'desc': 'Must match MYSQL_PASSWORD in .env', 'default': '', 'shared': 'db_password'},
                    'address': {'type': 'text', 'label': 'DB Address', 'desc': 'Database host:port', 'default': 'database:3306'},
                    'db': {'type': 'text', 'label': 'DB Name', 'desc': 'Database name for Pokemon/gym/raid data', 'default': 'golbat'},
                }
            },
            'pvp': {
                'title': '⚔️ PVP Rankings',
                'desc': 'Battle League ranking calculations',
                'fields': {
                    'enabled': {'type': 'checkbox', 'label': 'Enable PVP', 'desc': 'Calculate Great/Ultra/Master League rankings', 'default': True},
                    'include_hundos_under_cap': {'type': 'checkbox', 'label': 'Include Hundos', 'desc': 'Show PVP rank for 100% Pokemon under CP cap', 'default': False},
                }
            },
            'prometheus': {
                'title': '📊 Prometheus Metrics',
                'desc': 'Performance monitoring',
                'fields': {
                    'enabled': {'type': 'checkbox', 'label': 'Enable Metrics', 'desc': 'Send stats to Prometheus for Grafana', 'default': True},
                }
            },
            'tuning': {
                'title': '⚙️ Performance Tuning',
                'desc': 'Query and performance adjustments',
                'fields': {
                    'max_pokemon_distance': {'type': 'number', 'label': 'Max Search Distance (km)', 'desc': 'Maximum search radius for ReactMap', 'default': 100},
                    'max_pokemon_results': {'type': 'number', 'label': 'Max Results', 'desc': 'Maximum Pokemon to return per query', 'default': 3000},
                    'extended_timeout': {'type': 'checkbox', 'label': 'Extended Timeout', 'desc': 'Allow longer database queries', 'default': False},
                }
            },
        }
    },
    'unown/rotom_config.json': {
        'format': 'json',
        'sections': {
            'deviceListener': {
                'title': '📱 Device Connections',
                'desc': 'Settings for scanning devices (phones) connecting to Rotom',
                'fields': {
                    'port': {'type': 'number', 'label': 'Device Port', 'desc': 'Port devices connect to (set this in Aegis app)', 'default': 7070},
                    'secret': {'type': 'password', 'label': 'Device Secret', 'desc': 'Password devices need to connect (set in Aegis as Auth Bearer)', 'default': '', 'shared': 'rotom_device_secret'},
                }
            },
            'controllerListener': {
                'title': '🎮 Controller (Dragonite)',
                'desc': 'Settings for Dragonite to control devices',
                'fields': {
                    'port': {'type': 'number', 'label': 'Controller Port', 'desc': 'Internal port for Dragonite connection', 'default': 7071},
                    'secret': {'type': 'password', 'label': 'Controller Secret', 'desc': 'Password for Dragonite (empty = no auth, internal only)', 'default': ''},
                }
            },
            'client': {
                'title': '🌐 Web Dashboard',
                'desc': 'Settings for the Rotom status web page',
                'fields': {
                    'port': {'type': 'number', 'label': 'Web Port', 'desc': 'Internal port for dashboard (Docker maps to 6003)', 'default': 7072},
                    'host': {'type': 'text', 'label': 'Host', 'desc': 'Bind address (0.0.0.0 for Docker)', 'default': '0.0.0.0'},
                }
            },
            'logging': {
                'title': '📝 Logging',
                'desc': 'Log file settings',
                'fields': {
                    'save': {'type': 'checkbox', 'label': 'Save Logs', 'desc': 'Write logs to files', 'default': False},
                    'maxSize': {'type': 'number', 'label': 'Max Size (MB)', 'desc': 'Max log file size before rotation', 'default': 100},
                    'maxAge': {'type': 'number', 'label': 'Max Age (Days)', 'desc': 'Delete logs older than this', 'default': 14},
                    'debug': {'type': 'checkbox', 'label': 'Debug Mode', 'desc': 'Enable detailed debug logging', 'default': False},
                    'consoleStatus': {'type': 'checkbox', 'label': 'Console Status', 'desc': 'Show device status in console (noisy)', 'default': False},
                }
            },
            'monitor': {
                'title': '🔍 Device Monitor',
                'desc': 'Automatic device health monitoring',
                'fields': {
                    'enabled': {'type': 'checkbox', 'label': 'Enable Monitor', 'desc': 'Turn on automatic device health monitoring', 'default': False},
                    'reboot': {'type': 'checkbox', 'label': 'Auto Reboot', 'desc': 'Automatically reboot stuck devices (risky)', 'default': False},
                    'minMemory': {'type': 'number', 'label': 'Min Memory (KB)', 'desc': 'Min free memory before device flagged unhealthy', 'default': 30000},
                    'deviceCooldown': {'type': 'number', 'label': 'Cooldown (sec)', 'desc': 'Wait time before assigning work to new device', 'default': 0},
                }
            },
        }
    },
    'reactmap/local.json': {
        'format': 'json',
        'sections': {
            'general': {
                'title': '🌐 Server Settings',
                'desc': 'General ReactMap server configuration',
                'fields': {
                    'interface': {'type': 'text', 'label': 'Bind Address', 'desc': 'Network interface to bind to', 'default': '0.0.0.0'},
                    'port': {'type': 'number', 'label': 'Port', 'desc': 'Internal port (Docker maps externally)', 'default': 8080},
                }
            },
            'api': {
                'title': '🔑 API Security',
                'desc': 'Session and API security settings',
                'fields': {
                    'sessionSecret': {'type': 'password', 'label': 'Session Secret', 'desc': 'Secret for session encryption (auto-generated)', 'default': ''},
                    'reactMapSecret': {'type': 'password', 'label': 'ReactMap Secret', 'desc': 'Additional API secret', 'default': ''},
                    'maxSessions': {'type': 'number', 'label': 'Max Sessions', 'desc': 'Maximum concurrent sessions per user', 'default': 2},
                }
            },
            'api.kojiOptions': {
                'title': '🗺️ Koji Integration',
                'desc': 'Connection to Koji for geofences',
                'fields': {
                    'bearerToken': {'type': 'password', 'label': 'Koji Bearer Token', 'desc': 'Must match KOJI_SECRET in .env', 'default': '', 'shared': 'koji_secret'},
                }
            },
            'map.general': {
                'title': '🗺️ Map Defaults',
                'desc': 'Default map view settings',
                'fields': {
                    'title': {'type': 'text', 'label': 'Site Title', 'desc': 'Browser tab title', 'default': "Pokemod's PoGo Map"},
                    'headerTitle': {'type': 'text', 'label': 'Header Title', 'desc': 'Title shown on map', 'default': "Pokemod's PoGo Map"},
                    'startLat': {'type': 'number', 'label': 'Start Latitude', 'desc': 'Default map center latitude', 'default': 37.7894, 'step': 0.0001},
                    'startLon': {'type': 'number', 'label': 'Start Longitude', 'desc': 'Default map center longitude', 'default': -122.4016, 'step': 0.0001},
                    'startZoom': {'type': 'number', 'label': 'Start Zoom', 'desc': 'Default zoom level (1-18)', 'default': 12},
                    'minZoom': {'type': 'number', 'label': 'Min Zoom', 'desc': 'Minimum allowed zoom out', 'default': 6},
                    'maxZoom': {'type': 'number', 'label': 'Max Zoom', 'desc': 'Maximum allowed zoom in', 'default': 18},
                    'geoJsonFileName': {'type': 'text', 'label': 'GeoJSON URL', 'desc': 'Koji URL for scan area polygons', 'default': 'http://koji:8080/api/v1/geofence/feature-collection/Reactmap'},
                }
            },
            'database_golbat': {
                'title': '🗄️ Golbat Database',
                'desc': 'Connection to Golbat for Pokemon data',
                'fields': {
                    'endpoint': {'type': 'text', 'label': 'Golbat Endpoint', 'desc': 'Golbat HTTP API address', 'default': 'http://golbat:9001'},
                    'secret': {'type': 'password', 'label': 'Golbat API Secret', 'desc': 'Must match api_secret in golbat_config', 'default': '', 'shared': 'golbat_api_secret'},
                }
            },
            'database_main': {
                'title': '🗄️ Main Database',
                'desc': 'Direct database connection for Pokemon data',
                'fields': {
                    'host': {'type': 'text', 'label': 'DB Host', 'desc': 'Database server hostname', 'default': 'database'},
                    'port': {'type': 'number', 'label': 'DB Port', 'desc': 'Database port', 'default': 3306},
                    'username': {'type': 'text', 'label': 'DB Username', 'desc': 'Must match MYSQL_USER in .env', 'default': 'dbuser', 'shared': 'db_user'},
                    'password': {'type': 'password', 'label': 'DB Password', 'desc': 'Must match MYSQL_PASSWORD in .env', 'default': '', 'shared': 'db_password'},
                    'database': {'type': 'text', 'label': 'DB Name', 'desc': 'Golbat database name', 'default': 'golbat'},
                }
            },
            'scanner': {
                'title': '📡 Scanner Integration',
                'desc': 'On-demand scanning settings',
                'fields': {
                    'platform': {'type': 'text', 'label': 'Scanner Platform', 'desc': 'Scanner type (dragonite)', 'default': 'dragonite'},
                    'apiEndpoint': {'type': 'text', 'label': 'Scanner API', 'desc': 'Dragonite scout endpoint', 'default': 'http://dragonite:7272/scout'},
                    'scanZoneEnabled': {'type': 'checkbox', 'label': 'Enable Scan Zone', 'desc': 'Allow users to request scans', 'default': True},
                    'scanZoneMaxSize': {'type': 'number', 'label': 'Max Scan Size', 'desc': 'Maximum scan zone size', 'default': 4},
                }
            },
        }
    }
}

# Required environment variables
REQUIRED_ENV_VARS = {
    'PUID': {'description': 'User ID for file permissions', 'default': '1000', 'category': 'system'},
    'PGID': {'description': 'Group ID for file permissions', 'default': '1000', 'category': 'system'},
    'MYSQL_ROOT_PASSWORD': {'description': 'Database root password', 'default': '', 'category': 'database', 'secret': True},
    'MYSQL_USER': {'description': 'Database username', 'default': 'dbuser', 'category': 'database'},
    'MYSQL_PASSWORD': {'description': 'Database user password', 'default': '', 'category': 'database', 'secret': True},
    'KOJI_SECRET': {'description': 'Koji API secret', 'default': '', 'category': 'api', 'secret': True},
    'DRAGONITE_PASSWORD': {'description': 'Dragonite admin password', 'default': '', 'category': 'api', 'secret': True},
    'DRAGONITE_API_SECRET': {'description': 'Dragonite API secret', 'default': '', 'category': 'api', 'secret': True},
    'GOLBAT_API_SECRET': {'description': 'Golbat API secret', 'default': '', 'category': 'api', 'secret': True},
    'GOLBAT_RAW_SECRET': {'description': 'Golbat raw data secret', 'default': '', 'category': 'api', 'secret': True},
}

@app.route('/api/setup/status')
def api_setup_status():
    """Get overall setup status - what's configured and what's missing"""
    aegis_root = str(AEGIS_ROOT)  # Use properly resolved global path
    
    status = {
        'configs': {},
        'env_vars': {},
        'services': {},
        'summary': {
            'configs_present': 0,
            'configs_missing': 0,
            'env_vars_set': 0,
            'env_vars_missing': 0,
            'setup_complete': False
        }
    }
    
    # Check config files
    for config_path, config_info in REQUIRED_CONFIGS.items():
        full_path = os.path.join(aegis_root, config_path)
        template_path = os.path.join(aegis_root, config_info['template']) if config_info['template'] else None
        
        exists = os.path.exists(full_path)
        has_template = template_path and os.path.exists(template_path)
        
        status['configs'][config_path] = {
            'name': config_info['name'],
            'description': config_info['description'],
            'exists': exists,
            'critical': config_info['critical'],
            'category': config_info['category'],
            'has_template': has_template,
            'template': config_info['template'],
            'size': os.path.getsize(full_path) if exists else 0,
            'modified': datetime.fromtimestamp(os.path.getmtime(full_path)).isoformat() if exists else None
        }
        
        if exists:
            status['summary']['configs_present'] += 1
        else:
            status['summary']['configs_missing'] += 1
    
    # Check environment variables
    env_file = os.path.join(aegis_root, '.env')
    env_values = {}
    if os.path.exists(env_file):
        try:
            with open(env_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        key, value = line.split('=', 1)
                        env_values[key.strip()] = value.strip()
        except:
            pass
    
    for var_name, var_info in REQUIRED_ENV_VARS.items():
        value = env_values.get(var_name, '')
        is_set = bool(value) and value != var_info.get('default', '')
        
        status['env_vars'][var_name] = {
            'description': var_info['description'],
            'category': var_info['category'],
            'is_set': is_set,
            'is_secret': var_info.get('secret', False),
            'value': '***' if var_info.get('secret', False) and is_set else (value if value else var_info.get('default', ''))
        }
        
        if is_set:
            status['summary']['env_vars_set'] += 1
        else:
            status['summary']['env_vars_missing'] += 1
    
    # Check Docker status
    try:
        result = subprocess.run(['docker', 'info'], capture_output=True, text=True, timeout=5)
        status['services']['docker'] = {
            'installed': True,
            'running': result.returncode == 0
        }
    except:
        status['services']['docker'] = {'installed': False, 'running': False}
    
    # Check Docker Compose
    try:
        result = subprocess.run(['docker', 'compose', 'version'], capture_output=True, text=True, timeout=5)
        status['services']['docker_compose'] = {
            'installed': result.returncode == 0,
            'version': result.stdout.strip() if result.returncode == 0 else None
        }
    except:
        status['services']['docker_compose'] = {'installed': False}
    
    # Determine if setup is complete
    critical_configs = [p for p, i in REQUIRED_CONFIGS.items() if i['critical']]
    critical_present = all(status['configs'].get(p, {}).get('exists', False) for p in critical_configs)
    critical_vars = ['MYSQL_ROOT_PASSWORD', 'MYSQL_PASSWORD']
    critical_vars_set = all(status['env_vars'].get(v, {}).get('is_set', False) for v in critical_vars)
    
    status['summary']['setup_complete'] = critical_present and critical_vars_set and status['services'].get('docker', {}).get('running', False)
    
    return jsonify(status)

@app.route('/api/setup/scripts')
def api_setup_scripts():
    """Get list of available setup scripts"""
    aegis_root = str(AEGIS_ROOT)  # Use properly resolved global path
    shellder_dir = os.path.join(aegis_root, 'Shellder')
    
    scripts = [
        {'name': 'setup.sh', 'description': 'Full initial setup', 'category': 'setup'},
        {'name': 'dbsetup.sh', 'description': 'Database setup & maintenance', 'category': 'setup'},
        {'name': 'nginx-setup.sh', 'description': 'Nginx & SSL configuration', 'category': 'setup'},
        {'name': 'fletchling.sh', 'description': 'Fletchling nest service', 'category': 'service'},
        {'name': 'poracle.sh', 'description': 'Poracle alerts service', 'category': 'service'},
        {'name': 'check.sh', 'description': 'System health check', 'category': 'utility'},
        {'name': 'logs.sh', 'description': 'Log viewer', 'category': 'utility'},
    ]
    
    for script in scripts:
        script_path = os.path.join(shellder_dir, script['name'])
        script['exists'] = os.path.exists(script_path)
        script['path'] = script_path
    
    return jsonify({'scripts': scripts})

# =============================================================================
# STACK SETUP WIZARD API
# =============================================================================

import secrets
import string

@app.route('/api/wizard/status')
def api_wizard_status():
    """Get overall wizard/setup status for all steps"""
    aegis_root = str(AEGIS_ROOT)
    
    status = {
        'steps': {},
        'overall_progress': 0,
        'ready_to_start': False
    }
    
    # Step 1: Docker
    docker_installed = shutil.which('docker') is not None
    compose_installed = shutil.which('docker') is not None  # docker compose is now built-in
    docker_running = False
    try:
        result = subprocess.run(['docker', 'info'], capture_output=True, timeout=5)
        docker_running = result.returncode == 0
    except:
        pass
    
    status['steps']['docker'] = {
        'name': 'Docker & Compose',
        'description': 'Container runtime environment',
        'installed': docker_installed and compose_installed,
        'configured': docker_running,
        'complete': docker_installed and docker_running
    }
    
    # Step 2: Docker Logging
    daemon_json = '/etc/docker/daemon.json'
    log_configured = False
    if os.path.exists(daemon_json):
        try:
            with open(daemon_json) as f:
                config = json.load(f)
                log_configured = 'log-driver' in config or 'log-opts' in config
        except:
            pass
    
    status['steps']['docker_logging'] = {
        'name': 'Docker Logging',
        'description': 'Log rotation to prevent disk issues',
        'installed': True,
        'configured': log_configured,
        'complete': log_configured
    }
    
    # Step 3: Chrome (optional for scanner)
    chrome_installed = shutil.which('google-chrome') is not None or shutil.which('google-chrome-stable') is not None
    chrome_version = None
    if chrome_installed:
        try:
            result = subprocess.run(['google-chrome', '--version'], capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                chrome_version = result.stdout.strip().split()[-1] if result.stdout else None
        except:
            pass
    
    status['steps']['chrome'] = {
        'name': 'Google Chrome',
        'description': 'Required for scanner (specific version)',
        'installed': chrome_installed,
        'version': chrome_version,
        'configured': chrome_installed,
        'complete': chrome_installed,
        'optional': True
    }
    
    # Step 4: System Resources (always complete - just detection)
    ram_gb = 0
    cpu_cores = 0
    try:
        with open('/proc/meminfo') as f:
            for line in f:
                if 'MemTotal' in line:
                    ram_kb = int(line.split()[1])
                    ram_gb = ram_kb // (1024 * 1024)
                    break
        cpu_cores = os.cpu_count() or 4
    except:
        ram_gb = 4
        cpu_cores = 4
    
    status['steps']['resources'] = {
        'name': 'System Resources',
        'description': f'{ram_gb}GB RAM, {cpu_cores} CPU cores detected',
        'installed': True,
        'configured': True,
        'complete': True,
        'ram_gb': ram_gb,
        'cpu_cores': cpu_cores
    }
    
    # Step 5: MariaDB Setup (comprehensive - install, configure, create DBs)
    mariadb_cnf = os.path.join(aegis_root, 'mysql_data', 'mariadb.cnf')
    mariadb_configured = os.path.exists(mariadb_cnf)
    
    # Check MariaDB/MySQL installation  
    mariadb_installed = shutil.which('mariadb') is not None or shutil.which('mysql') is not None
    
    # Check if database container is running and accessible
    db_container_running = False
    db_accessible = False
    try:
        result = subprocess.run(['docker', 'ps', '--filter', 'name=database', '--format', '{{.Names}}'],
                              capture_output=True, text=True, timeout=5)
        db_container_running = 'database' in result.stdout
    except:
        pass
    
    # Check if databases are created
    databases_created = False
    if db_container_running:
        try:
            result = subprocess.run(
                ['docker', 'exec', 'database', 'mysql', '-u', 'root', '-e', 'SHOW DATABASES'],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                db_accessible = True
                output = result.stdout
                databases_created = all(db in output for db in ['dragonite', 'golbat', 'reactmap'])
        except:
            pass
    
    status['steps']['mariadb_setup'] = {
        'name': 'MariaDB Setup',
        'description': 'Database installation & configuration',
        'installed': mariadb_installed or db_container_running,
        'container_running': db_container_running,
        'accessible': db_accessible,
        'databases_created': databases_created,
        'config_exists': mariadb_configured,
        'configured': mariadb_configured and (db_accessible or mariadb_installed),
        'complete': databases_created and mariadb_configured
    }
    
    # Step 6: Config Files
    env_file = os.path.join(aegis_root, '.env')
    compose_file = os.path.exists(os.path.join(aegis_root, 'docker-compose.yaml')) or \
                   os.path.exists(os.path.join(aegis_root, 'docker-compose.yml'))
    
    status['steps']['config_files'] = {
        'name': 'Configuration Files',
        'description': 'Environment and service configs',
        'installed': True,
        'configured': os.path.exists(env_file) and compose_file,
        'complete': os.path.exists(env_file) and compose_file
    }
    
    # Step 7: Passwords
    passwords_set = False
    if os.path.exists(env_file):
        try:
            with open(env_file) as f:
                content = f.read()
                passwords_set = 'MYSQL_ROOT_PASSWORD=' in content and \
                               'MYSQL_PASSWORD=' in content and \
                               'changeme' not in content.lower()
        except:
            pass
    
    status['steps']['passwords'] = {
        'name': 'Passwords & Tokens',
        'description': 'Secure credentials generation',
        'installed': True,
        'configured': passwords_set,
        'complete': passwords_set
    }
    
    # Step 8: Database Container
    db_running = False
    try:
        result = subprocess.run(['docker', 'ps', '--filter', 'name=database', '--format', '{{.Names}}'],
                              capture_output=True, text=True, timeout=5)
        db_running = 'database' in result.stdout
    except:
        pass
    
    status['steps']['database'] = {
        'name': 'Database Service',
        'description': 'MariaDB container',
        'installed': True,
        'configured': db_running,
        'complete': db_running
    }
    
    # Calculate overall progress
    completed = sum(1 for s in status['steps'].values() if s.get('complete'))
    total = len(status['steps'])
    status['overall_progress'] = int((completed / total) * 100)
    status['ready_to_start'] = status['steps']['docker']['complete'] and \
                               status['steps']['config_files']['complete'] and \
                               status['steps']['passwords']['complete']
    
    return jsonify(status)

@app.route('/api/wizard/detect-resources')
def api_wizard_detect_resources():
    """Detect system resources for optimization"""
    resources = {
        'ram_mb': 4096,
        'ram_gb': 4,
        'cpu_cores': 4,
        'storage_type': 'unknown'
    }
    
    # Detect RAM
    try:
        with open('/proc/meminfo') as f:
            for line in f:
                if 'MemTotal' in line:
                    resources['ram_mb'] = int(line.split()[1]) // 1024
                    resources['ram_gb'] = resources['ram_mb'] // 1024
                    break
    except:
        pass
    
    # Detect CPU
    resources['cpu_cores'] = os.cpu_count() or 4
    
    # Detect storage type (basic heuristic)
    try:
        result = subprocess.run(['lsblk', '-d', '-o', 'NAME,ROTA'], capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            # ROTA=0 means SSD, ROTA=1 means HDD
            if '0' in result.stdout:
                resources['storage_type'] = 'ssd'
            else:
                resources['storage_type'] = 'hdd'
    except:
        resources['storage_type'] = 'ssd'  # Default assumption
    
    # Calculate recommended MariaDB settings
    # Rule: 25-40% of RAM when sharing with other services (Golbat, etc.)
    # We use 30% as a safe default, matching the setup.sh script
    ram_mb = resources['ram_mb']
    ram_gb = resources['ram_gb']
    buffer_pool_mb = ram_mb * 30 // 100
    
    # Calculate buffer pool size with granular thresholds matching setup.sh
    if buffer_pool_mb < 512:
        buffer_pool = '512M'
        buffer_pool_gb = 0
    elif buffer_pool_mb < 1024:
        buffer_pool = '512M'
        buffer_pool_gb = 0
    elif buffer_pool_mb < 1536:
        buffer_pool = '1G'
        buffer_pool_gb = 1
    elif buffer_pool_mb < 2560:
        buffer_pool = '2G'
        buffer_pool_gb = 2
    elif buffer_pool_mb < 3584:
        buffer_pool = '3G'
        buffer_pool_gb = 3
    elif buffer_pool_mb < 4608:
        buffer_pool = '4G'
        buffer_pool_gb = 4
    elif buffer_pool_mb < 6144:
        buffer_pool = '5G'
        buffer_pool_gb = 5
    elif buffer_pool_mb < 7168:
        buffer_pool = '6G'
        buffer_pool_gb = 6
    elif buffer_pool_mb < 8192:
        buffer_pool = '7G'
        buffer_pool_gb = 7
    elif buffer_pool_mb < 10240:
        buffer_pool = '8G'
        buffer_pool_gb = 8
    elif buffer_pool_mb < 12288:
        buffer_pool = '10G'
        buffer_pool_gb = 10
    elif buffer_pool_mb < 16384:
        buffer_pool = '12G'
        buffer_pool_gb = 12
    else:
        buffer_pool = '16G'
        buffer_pool_gb = 16
    
    # Calculate I/O threads (CPU cores / 2, minimum 2, maximum 8)
    io_threads = max(2, min(8, resources['cpu_cores'] // 2))
    
    # Calculate max connections based on RAM
    if ram_gb <= 2:
        max_connections = 100
    elif ram_gb <= 4:
        max_connections = 200
    elif ram_gb <= 8:
        max_connections = 300
    elif ram_gb <= 16:
        max_connections = 500
    else:
        max_connections = 750
    
    # Calculate tmp_table_size based on RAM
    if ram_gb <= 2:
        tmp_table_size = '64M'
    elif ram_gb <= 4:
        tmp_table_size = '128M'
    elif ram_gb <= 8:
        tmp_table_size = '256M'
    else:
        tmp_table_size = '512M'
    
    # Calculate log file size based on RAM
    if ram_gb <= 4:
        log_file_size = '256M'
    elif ram_gb <= 8:
        log_file_size = '512M'
    elif ram_gb <= 16:
        log_file_size = '768M'
    else:
        log_file_size = '1G'
    
    # Calculate buffer pool instances (1 per GB, max 8)
    if buffer_pool_gb <= 1:
        buffer_pool_instances = 1
    elif buffer_pool_gb >= 8:
        buffer_pool_instances = 8
    else:
        buffer_pool_instances = buffer_pool_gb
    
    resources['recommended'] = {
        'innodb_buffer_pool_size': buffer_pool,
        'innodb_buffer_pool_instances': buffer_pool_instances,
        'innodb_io_threads': io_threads,
        'max_connections': max_connections,
        'tmp_table_size': tmp_table_size,
        'innodb_log_file_size': log_file_size
    }
    
    return jsonify(resources)

@app.route('/api/wizard/password-status')
def api_wizard_password_status():
    """Check current password status - detect if non-default values exist"""
    aegis_root = str(AEGIS_ROOT)
    env_file = os.path.join(aegis_root, '.env')
    
    # Default/placeholder values to detect
    default_values = {
        'changeme', 'your_password', 'your_root_password', 'password', 
        'secret', 'your_secret', 'change_me', 'CHANGEME', 'PASSWORD',
        'your-password', 'your-secret', 'example', 'test', ''
    }
    
    # Password fields to check
    password_fields = {
        'MYSQL_ROOT_PASSWORD': {'label': 'MySQL Root Password', 'type': 'password'},
        'MYSQL_PASSWORD': {'label': 'MySQL User Password', 'type': 'password'},
        'BEARER_TOKEN': {'label': 'Bearer Token', 'type': 'token'},
        'DRAGONITE_SECRET': {'label': 'Dragonite Secret', 'type': 'token'},
        'GOLBAT_API_SECRET': {'label': 'Golbat API Secret', 'type': 'token'},
        'REACTMAP_SECRET': {'label': 'ReactMap Secret', 'type': 'token'},
        'KOJI_SECRET': {'label': 'Koji Secret', 'type': 'token'}
    }
    
    result = {
        'fields': {},
        'all_configured': True,
        'has_defaults': False,
        'env_exists': os.path.exists(env_file)
    }
    
    current_values = {}
    if os.path.exists(env_file):
        try:
            with open(env_file) as f:
                for line in f:
                    line = line.strip()
                    if '=' in line and not line.startswith('#'):
                        key, value = line.split('=', 1)
                        current_values[key] = value
        except Exception as e:
            result['error'] = str(e)
    
    for key, info in password_fields.items():
        current = current_values.get(key, '')
        is_default = current.lower() in default_values or current == '' or len(current) < 8
        
        # Better masking that handles various lengths
        if len(current) == 0:
            masked = '(not set)'
        elif len(current) < 4:
            masked = '•' * len(current) + ' (too short!)'
        elif len(current) < 8:
            masked = current[:2] + '•' * (len(current) - 2) + ' (weak)'
        elif len(current) < 12:
            masked = current[:3] + '•' * (len(current) - 6) + current[-3:]
        else:
            masked = current[:4] + '•' * (len(current) - 8) + current[-4:]
        
        result['fields'][key] = {
            'label': info['label'],
            'type': info['type'],
            'has_value': bool(current),
            'is_default': is_default,
            'current_masked': masked,
            'current_value': current,  # Include actual value for "keep" option
            'length': len(current)
        }
        
        if is_default or not current:
            result['all_configured'] = False
        if is_default and current:
            result['has_defaults'] = True
    
    return jsonify(result)

@app.route('/api/wizard/generate-passwords', methods=['POST'])
def api_wizard_generate_passwords():
    """Generate secure random passwords, with option for custom values"""
    def generate_password(length=24):
        chars = string.ascii_letters + string.digits
        return ''.join(secrets.choice(chars) for _ in range(length))
    
    def generate_token(length=32):
        return secrets.token_hex(length // 2)
    
    data = request.json or {}
    custom = data.get('custom', {})  # User-provided custom passwords
    keep_existing = data.get('keep_existing', [])  # Fields to keep unchanged
    
    # Get current values if we need to keep some
    aegis_root = str(AEGIS_ROOT)
    env_file = os.path.join(aegis_root, '.env')
    current_values = {}
    if os.path.exists(env_file):
        try:
            with open(env_file) as f:
                for line in f:
                    line = line.strip()
                    if '=' in line and not line.startswith('#'):
                        key, value = line.split('=', 1)
                        current_values[key] = value
        except:
            pass
    
    # Field mapping
    field_mapping = {
        'mysql_root_password': 'MYSQL_ROOT_PASSWORD',
        'mysql_password': 'MYSQL_PASSWORD',
        'bearer_token': 'BEARER_TOKEN',
        'dragonite_secret': 'DRAGONITE_SECRET',
        'golbat_api_secret': 'GOLBAT_API_SECRET',
        'reactmap_secret': 'REACTMAP_SECRET',
        'koji_secret': 'KOJI_SECRET'
    }
    
    passwords = {}
    for field, env_key in field_mapping.items():
        if field in custom and custom[field]:
            # Use custom value provided by user
            passwords[field] = custom[field]
        elif env_key in keep_existing and env_key in current_values:
            # Keep existing value
            passwords[field] = current_values[env_key]
        else:
            # Generate new value
            if 'token' in field or 'secret' in field:
                passwords[field] = generate_token(32)
            else:
                passwords[field] = generate_password(24)
    
    return jsonify(passwords)

@app.route('/api/wizard/apply-passwords', methods=['POST'])
def api_wizard_apply_passwords():
    """Apply generated passwords to .env file"""
    aegis_root = str(AEGIS_ROOT)
    env_file = os.path.join(aegis_root, '.env')
    
    data = request.json or {}
    passwords = data.get('passwords', {})
    
    if not passwords:
        return jsonify({'error': 'No passwords provided'}), 400
    
    try:
        # Read existing .env or create new
        env_content = {}
        if os.path.exists(env_file):
            with open(env_file) as f:
                for line in f:
                    line = line.strip()
                    if '=' in line and not line.startswith('#'):
                        key, value = line.split('=', 1)
                        env_content[key] = value
        
        # Update with new passwords
        mapping = {
            'mysql_root_password': 'MYSQL_ROOT_PASSWORD',
            'mysql_password': 'MYSQL_PASSWORD',
            'bearer_token': 'BEARER_TOKEN',
            'dragonite_secret': 'DRAGONITE_SECRET',
            'golbat_api_secret': 'GOLBAT_API_SECRET',
            'reactmap_secret': 'REACTMAP_SECRET',
            'koji_secret': 'KOJI_SECRET'
        }
        
        for key, env_key in mapping.items():
            if key in passwords:
                env_content[env_key] = passwords[key]
        
        # Write back
        with open(env_file, 'w') as f:
            for key, value in env_content.items():
                f.write(f'{key}={value}\n')
        
        return jsonify({'success': True, 'message': 'Passwords applied to .env'})
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/wizard/apply-mariadb-config', methods=['POST'])
def api_wizard_apply_mariadb_config():
    """Apply optimized MariaDB configuration"""
    aegis_root = str(AEGIS_ROOT)
    mariadb_cnf = os.path.join(aegis_root, 'mysql_data', 'mariadb.cnf')
    
    data = request.json or {}
    settings = data.get('settings', {})
    
    if not settings:
        return jsonify({'error': 'No settings provided'}), 400
    
    try:
        # Ensure directory exists
        os.makedirs(os.path.dirname(mariadb_cnf), exist_ok=True)
        
        # Read existing config or use template
        if os.path.exists(mariadb_cnf):
            with open(mariadb_cnf) as f:
                content = f.read()
        else:
            content = """[mysqld]
# MariaDB Configuration - Auto-generated by Shellder Setup Wizard
innodb_buffer_pool_size = 1G
innodb_buffer_pool_instances = 1
innodb_read_io_threads = 4
innodb_write_io_threads = 4
innodb_purge_threads = 4
innodb_io_capacity = 1000
innodb_io_capacity_max = 4000
max_connections = 200
tmp_table_size = 128M
max_heap_table_size = 128M
innodb_log_file_size = 256M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
"""
        
        # Apply settings
        for key, value in settings.items():
            pattern = f'^{key} = .*$'
            replacement = f'{key} = {value}'
            import re
            if re.search(pattern, content, re.MULTILINE):
                content = re.sub(pattern, replacement, content, flags=re.MULTILINE)
            else:
                # Add new setting
                content += f'\n{key} = {value}'
        
        # Write config
        with open(mariadb_cnf, 'w') as f:
            f.write(content)
        
        return jsonify({'success': True, 'message': 'MariaDB configuration updated'})
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/wizard/copy-configs', methods=['POST'])
def api_wizard_copy_configs():
    """Copy default config files from examples"""
    aegis_root = str(AEGIS_ROOT)
    
    copied = []
    errors = []
    
    # Config files to copy (source -> dest)
    configs = [
        ('unown/dragonite_config.toml.example', 'unown/dragonite_config.toml'),
        ('unown/golbat_config.toml.example', 'unown/golbat_config.toml'),
        ('unown/rotom_config.json.example', 'unown/rotom_config.json'),
        ('reactmap/local.json.example', 'reactmap/local.json'),
        ('fletchling.toml.example', 'fletchling.toml'),
        ('.env.example', '.env'),
    ]
    
    for src, dest in configs:
        src_path = os.path.join(aegis_root, src)
        dest_path = os.path.join(aegis_root, dest)
        
        if os.path.exists(src_path) and not os.path.exists(dest_path):
            try:
                os.makedirs(os.path.dirname(dest_path), exist_ok=True)
                shutil.copy2(src_path, dest_path)
                copied.append(dest)
            except Exception as e:
                errors.append({'file': dest, 'error': str(e)})
    
    return jsonify({
        'success': len(errors) == 0,
        'copied': copied,
        'errors': errors
    })

@app.route('/api/wizard/start-stack', methods=['POST'])
def api_wizard_start_stack():
    """Start the Docker stack - handles already running containers gracefully"""
    aegis_root = str(AEGIS_ROOT)
    
    try:
        # First, get list of services that are NOT running
        ps_result = subprocess.run(
            ['docker', 'compose', 'ps', '--format', 'json'],
            capture_output=True, text=True, timeout=30, cwd=aegis_root
        )
        
        running_services = set()
        if ps_result.returncode == 0 and ps_result.stdout.strip():
            import json as json_mod
            for line in ps_result.stdout.strip().split('\n'):
                try:
                    container = json_mod.loads(line)
                    if container.get('State') == 'running':
                        running_services.add(container.get('Service', ''))
                except:
                    pass
        
        # Get all services from compose file
        config_result = subprocess.run(
            ['docker', 'compose', 'config', '--services'],
            capture_output=True, text=True, timeout=30, cwd=aegis_root
        )
        all_services = set(config_result.stdout.strip().split('\n')) if config_result.returncode == 0 else set()
        
        # Find services that need to be started (not already running)
        services_to_start = all_services - running_services
        
        # Also exclude shellder if host shellder is running on port 5000
        try:
            import socket
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(1)
            result_check = sock.connect_ex(('127.0.0.1', 5000))
            sock.close()
            if result_check == 0:
                # Port 5000 is in use (host shellder running)
                services_to_start.discard('shellder')
                info('DOCKER', 'Skipping shellder container - host shellder already running on port 5000')
        except:
            pass
        
        if not services_to_start:
            return jsonify({
                'success': True,
                'message': 'All containers already running',
                'stdout': '',
                'stderr': '',
                'started': [],
                'already_running': list(running_services)
            })
        
        # Start only the services that aren't running
        result = subprocess.run(
            ['docker', 'compose', 'up', '-d', '--no-recreate'] + list(services_to_start),
            capture_output=True,
            text=True,
            timeout=300,
            cwd=aegis_root
        )
        
        # Check final status
        final_ps = subprocess.run(
            ['docker', 'compose', 'ps', '--format', 'json'],
            capture_output=True, text=True, timeout=30, cwd=aegis_root
        )
        
        final_running = []
        final_failed = []
        if final_ps.returncode == 0 and final_ps.stdout.strip():
            for line in final_ps.stdout.strip().split('\n'):
                try:
                    container = json_mod.loads(line)
                    if container.get('State') == 'running':
                        final_running.append(container.get('Service', ''))
                    else:
                        final_failed.append(container.get('Service', ''))
                except:
                    pass
        
        return jsonify({
            'success': True,  # Mark as success if we attempted to start
            'stdout': result.stdout,
            'stderr': result.stderr,
            'started': list(services_to_start),
            'already_running': list(running_services),
            'final_running': final_running,
            'final_failed': final_failed,
            'message': f'Started {len(services_to_start)} services'
        })
        
    except subprocess.TimeoutExpired:
        return jsonify({'error': 'Stack startup timed out'}), 504
    except Exception as e:
        error('DOCKER', f'Start stack error: {e}')
        return jsonify({'error': str(e)}), 500

@app.route('/api/wizard/check-ports')
def api_wizard_check_ports():
    """Check if required ports are available"""
    ports = {
        6001: 'ReactMap',
        6002: 'Dragonite Admin', 
        6003: 'Rotom UI',
        6004: 'Koji',
        6005: 'phpMyAdmin',
        6006: 'Grafana',
        7070: 'Rotom Devices',
        5090: 'Xilriws'
    }
    
    results = {}
    
    for port, service in ports.items():
        in_use = False
        process = None
        
        try:
            result = subprocess.run(
                ['ss', '-tulnp'],
                capture_output=True,
                text=True,
                timeout=5
            )
            if f':{port} ' in result.stdout:
                in_use = True
                # Try to extract process name
                for line in result.stdout.split('\n'):
                    if f':{port} ' in line:
                        if 'users:' in line:
                            process = line.split('users:')[1].split(')')[0].strip('(("').split('"')[0]
                        break
        except:
            pass
        
        results[port] = {
            'service': service,
            'in_use': in_use,
            'process': process,
            'available': not in_use
        }
    
    all_available = all(r['available'] for r in results.values())
    
    return jsonify({
        'ports': results,
        'all_available': all_available
    })

# =============================================================================
# MARIADB SETUP API ENDPOINTS
# =============================================================================

AEGIS_DATABASES = ['dragonite', 'golbat', 'reactmap', 'koji', 'poracle']

@app.route('/api/mariadb/status')
def api_mariadb_status():
    """Get comprehensive MariaDB status for setup wizard"""
    aegis_root = str(AEGIS_ROOT)
    env_file = os.path.join(aegis_root, '.env')
    
    status = {
        'installation': {
            'mariadb_cli': shutil.which('mariadb') is not None,
            'mysql_cli': shutil.which('mysql') is not None,
            'installed': False
        },
        'container': {
            'running': False,
            'accessible': False,
            'version': None
        },
        'credentials': {
            'root_password_set': False,
            'db_user': None,
            'db_password_set': False,
            'root_user': 'root'  # Default root username
        },
        'databases': {db: {'exists': False, 'size': None} for db in AEGIS_DATABASES},
        'users': {},
        'connection_test': {
            'root': False,
            'db_user': False
        },
        'config': {
            'mariadb_cnf_exists': os.path.exists(os.path.join(aegis_root, 'mysql_data', 'mariadb.cnf')),
            'init_sql_exists': os.path.exists(os.path.join(aegis_root, 'init', '01.sql'))
        }
    }
    
    status['installation']['installed'] = status['installation']['mariadb_cli'] or status['installation']['mysql_cli']
    
    # Load credentials from .env
    if os.path.exists(env_file):
        try:
            with open(env_file) as f:
                for line in f:
                    line = line.strip()
                    if '=' in line and not line.startswith('#'):
                        key, value = line.split('=', 1)
                        if key == 'MYSQL_ROOT_PASSWORD' and value:
                            status['credentials']['root_password_set'] = True
                        elif key == 'MYSQL_USER' and value:
                            status['credentials']['db_user'] = value
                        elif key == 'MYSQL_PASSWORD' and value:
                            status['credentials']['db_password_set'] = True
        except:
            pass
    
    # Check localhost:3306 first (host-installed MariaDB)
    import socket
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        localhost_available = sock.connect_ex(('127.0.0.1', 3306)) == 0
        sock.close()
        status['localhost'] = {
            'port_open': localhost_available,
            'preferred': localhost_available  # Prefer localhost if available
        }
    except:
        status['localhost'] = {'port_open': False, 'preferred': False}
    
    # Check container status (fallback)
    try:
        result = subprocess.run(
            ['docker', 'ps', '--filter', 'name=database', '--format', '{{.Names}}|{{.Status}}'],
            capture_output=True, text=True, timeout=5
        )
        if 'database' in result.stdout:
            status['container']['running'] = True
            
            # Get MariaDB version
            ver_result = subprocess.run(
                ['docker', 'exec', 'database', 'mysql', '-V'],
                capture_output=True, text=True, timeout=10
            )
            if ver_result.returncode == 0:
                status['container']['version'] = ver_result.stdout.strip()
    except:
        pass
    
    # Test database connection via localhost:3306
    import socket
    
    # First check if port 3306 is reachable
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        port_open = sock.connect_ex(('localhost', 3306)) == 0
        sock.close()
        status['connection_test']['port_3306_open'] = port_open
    except:
        port_open = False
        status['connection_test']['port_3306_open'] = False
    
    if port_open or status['container']['running']:
        # Get credentials from env
        root_pass = None
        db_pass = None
        if os.path.exists(env_file):
            try:
                with open(env_file) as f:
                    for line in f:
                        if line.startswith('MYSQL_ROOT_PASSWORD='):
                            root_pass = line.split('=', 1)[1].strip()
                        elif line.startswith('MYSQL_PASSWORD='):
                            db_pass = line.split('=', 1)[1].strip()
            except:
                pass
        
        # Find mysql CLI
        mysql_cmd = shutil.which('mariadb') or shutil.which('mysql')
        
        # Test root connection via localhost:3306
        if root_pass and mysql_cmd:
            try:
                result = subprocess.run(
                    [mysql_cmd, '-u', 'root', f'-p{root_pass}', '-h', 'localhost', '-P', '3306', '-e', 'SELECT 1'],
                    capture_output=True, text=True, timeout=10
                )
                if result.returncode == 0:
                    status['container']['accessible'] = True
                    status['connection_test']['root'] = True
                    status['connection_test']['method'] = 'localhost:3306'
                    
                    # Check databases via localhost
                    db_result = subprocess.run(
                        [mysql_cmd, '-u', 'root', f'-p{root_pass}', '-h', 'localhost', '-P', '3306', '-N', '-e',
                         "SELECT SCHEMA_NAME, ROUND(SUM(data_length + index_length)/1024/1024, 2) as size_mb "
                         "FROM information_schema.SCHEMATA s "
                         "LEFT JOIN information_schema.tables t ON s.SCHEMA_NAME = t.TABLE_SCHEMA "
                         "GROUP BY SCHEMA_NAME"],
                        capture_output=True, text=True, timeout=10
                    )
                    if db_result.returncode == 0:
                        for line in db_result.stdout.strip().split('\n'):
                            if line:
                                parts = line.split('\t')
                                db_name = parts[0]
                                if db_name in AEGIS_DATABASES:
                                    status['databases'][db_name]['exists'] = True
                                    status['databases'][db_name]['size'] = f"{parts[1]}MB" if len(parts) > 1 and parts[1] != 'NULL' else '0MB'
                    
                    # Check users
                    user_result = subprocess.run(
                        [mysql_cmd, '-u', 'root', f'-p{root_pass}', '-h', 'localhost', '-P', '3306', '-N', '-e',
                         "SELECT User, Host FROM mysql.user WHERE User NOT IN ('root', 'mariadb.sys', 'mysql', '')"],
                        capture_output=True, text=True, timeout=10
                    )
                    if user_result.returncode == 0:
                        for line in user_result.stdout.strip().split('\n'):
                            if line:
                                parts = line.split('\t')
                                if len(parts) >= 2:
                                    status['users'][parts[0]] = {'host': parts[1], 'exists': True}
            except:
                pass
        elif root_pass and status['container']['running']:
            # Fallback to docker exec if no local mysql client
            try:
                result = subprocess.run(
                    ['docker', 'exec', 'database', 'mysql', '-u', 'root', f'-p{root_pass}', '-e', 'SELECT 1'],
                    capture_output=True, text=True, timeout=10
                )
                if result.returncode == 0:
                    status['container']['accessible'] = True
                    status['connection_test']['root'] = True
                    status['connection_test']['method'] = 'docker_exec'
                    status['connection_test']['note'] = 'Install mysql-client for localhost:3306 testing'
            except:
                pass
        
        # Test db_user connection via localhost:3306
        db_user = status['credentials'].get('db_user')
        if db_user and db_pass and mysql_cmd:
            try:
                result = subprocess.run(
                    [mysql_cmd, '-u', db_user, f'-p{db_pass}', '-h', 'localhost', '-P', '3306', '-e', 'SELECT 1'],
                    capture_output=True, text=True, timeout=10
                )
                status['connection_test']['db_user'] = result.returncode == 0
            except:
                pass
        elif db_user and db_pass and status['container']['running']:
            # Fallback to docker exec
            try:
                result = subprocess.run(
                    ['docker', 'exec', 'database', 'mysql', '-u', db_user, f'-p{db_pass}', '-e', 'SELECT 1'],
                    capture_output=True, text=True, timeout=10
                )
                status['connection_test']['db_user'] = result.returncode == 0
            except:
                pass
    
    # Calculate completion status
    all_dbs_exist = all(status['databases'][db]['exists'] for db in AEGIS_DATABASES)
    status['setup_complete'] = (
        status['container']['running'] and
        status['container']['accessible'] and
        all_dbs_exist and
        status['connection_test']['db_user']
    )
    
    return jsonify(status)

@app.route('/api/mariadb/credentials')
def api_mariadb_credentials():
    """Get current MariaDB credentials from .env and other config files"""
    aegis_root = str(AEGIS_ROOT)
    env_file = os.path.join(aegis_root, '.env')
    
    credentials = {
        'root_user': 'root',  # Default, MariaDB uses 'root'
        'root_password': '',
        'db_user': 'dbuser',  # Default from init/01.sql
        'db_password': '',
        'databases': AEGIS_DATABASES.copy()
    }
    
    # Load from .env
    if os.path.exists(env_file):
        try:
            with open(env_file) as f:
                for line in f:
                    line = line.strip()
                    if '=' in line and not line.startswith('#'):
                        key, value = line.split('=', 1)
                        if key == 'MYSQL_ROOT_PASSWORD':
                            credentials['root_password'] = value
                        elif key == 'MYSQL_USER':
                            credentials['db_user'] = value
                        elif key == 'MYSQL_PASSWORD':
                            credentials['db_password'] = value
                        elif key == 'MYSQL_DATABASE':
                            # Add to databases if not already in list
                            if value and value not in credentials['databases']:
                                credentials['databases'].append(value)
        except:
            pass
    
    return jsonify(credentials)

@app.route('/api/mariadb/setup', methods=['POST'])
def api_mariadb_setup():
    """Perform MariaDB setup: create databases and users"""
    aegis_root = str(AEGIS_ROOT)
    env_file = os.path.join(aegis_root, '.env')
    init_sql = os.path.join(aegis_root, 'init', '01.sql')
    
    data = request.json or {}
    
    # Get credentials
    root_password = data.get('root_password', '')
    db_user = data.get('db_user', 'dbuser')
    db_password = data.get('db_password', '')
    databases = data.get('databases', AEGIS_DATABASES)
    
    # If not provided, try to load from .env
    if not root_password and os.path.exists(env_file):
        try:
            with open(env_file) as f:
                for line in f:
                    if line.startswith('MYSQL_ROOT_PASSWORD='):
                        root_password = line.split('=', 1)[1].strip()
                        break
        except:
            pass
    
    if not db_password and os.path.exists(env_file):
        try:
            with open(env_file) as f:
                for line in f:
                    if line.startswith('MYSQL_PASSWORD='):
                        db_password = line.split('=', 1)[1].strip()
                        break
        except:
            pass
    
    results = {
        'success': True,
        'steps': [],
        'errors': []
    }
    
    # Find mysql CLI
    mysql_cmd = shutil.which('mariadb') or shutil.which('mysql')
    
    # Determine connection method: try localhost:3306 first, then docker exec
    import socket
    use_localhost = False
    use_docker = False
    
    # Check if port 3306 is accessible on localhost
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        if sock.connect_ex(('127.0.0.1', 3306)) == 0:
            use_localhost = True
            results['steps'].append('✓ MariaDB accessible on localhost:3306')
        sock.close()
    except:
        pass
    
    # If localhost not available, check container
    if not use_localhost:
        try:
            result = subprocess.run(
                ['docker', 'ps', '--filter', 'name=database', '--format', '{{.Names}}'],
                capture_output=True, text=True, timeout=5
            )
            if 'database' in result.stdout:
                use_docker = True
                results['steps'].append('✓ Using database container')
        except:
            pass
    
    if not use_localhost and not use_docker:
        results['errors'].append('No database connection available. Either start MariaDB on localhost:3306 or start the database container.')
        results['success'] = False
        return jsonify(results)
    
    # Helper function to run mysql commands
    def run_mysql(user, password, query, check_db=None):
        if use_localhost and mysql_cmd:
            cmd = [mysql_cmd, '-u', user, f'-p{password}', '-h', '127.0.0.1', '-P', '3306']
            if check_db:
                cmd.extend(['-D', check_db])
            cmd.extend(['-e', query])
            return subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        else:
            cmd = ['docker', 'exec', 'database', 'mysql', '-u', user, f'-p{password}']
            if check_db:
                cmd.extend(['-D', check_db])
            cmd.extend(['-e', query])
            return subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    
    # Test root connection
    try:
        test_result = run_mysql('root', root_password, 'SELECT 1')
        if test_result.returncode != 0:
            results['errors'].append(f'Root connection failed: {test_result.stderr}')
            results['success'] = False
            return jsonify(results)
        results['steps'].append('✓ Root connection verified')
    except Exception as e:
        results['errors'].append(f'Failed to test root connection: {e}')
        results['success'] = False
        return jsonify(results)
    
    # Create databases
    for db in databases:
        try:
            result = run_mysql('root', root_password, f'CREATE DATABASE IF NOT EXISTS `{db}`')
            if result.returncode == 0:
                results['steps'].append(f'✓ Database "{db}" created/verified')
            else:
                results['errors'].append(f'Failed to create database {db}: {result.stderr}')
        except Exception as e:
            results['errors'].append(f'Error creating database {db}: {e}')
    
    # Create user with proper permissions
    if db_user and db_password:
        try:
            # Create user (with proper escape for special chars in password)
            escaped_pass = db_password.replace("'", "\\'")
            result = run_mysql('root', root_password, 
                f"CREATE USER IF NOT EXISTS '{db_user}'@'%' IDENTIFIED BY '{escaped_pass}'")
            if result.returncode == 0:
                results['steps'].append(f'✓ User "{db_user}" created/verified')
            else:
                results['errors'].append(f'Failed to create user: {result.stderr}')
            
            # Grant all privileges on aegis databases
            result = run_mysql('root', root_password,
                f"GRANT ALL PRIVILEGES ON *.* TO '{db_user}'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;")
            if result.returncode == 0:
                results['steps'].append(f'✓ Granted privileges to "{db_user}"')
            else:
                results['errors'].append(f'Failed to grant privileges: {result.stderr}')
        except Exception as e:
            results['errors'].append(f'Error creating user: {e}')
    
    # Test user connection
    if db_user and db_password:
        try:
            result = run_mysql(db_user, db_password, 'SELECT 1')
            if result.returncode == 0:
                results['steps'].append(f'✓ User "{db_user}" connection verified')
            else:
                results['errors'].append(f'User connection test failed: {result.stderr}')
        except Exception as e:
            results['errors'].append(f'Error testing user connection: {e}')
    
    # Update init/01.sql if needed
    if db_user and db_password:
        try:
            init_content = f"""# Create databases and user for Aegis All-in-One
# This file runs ONLY on first database container creation.
# Generated by Shellder Setup Wizard

# Create the database user
CREATE USER IF NOT EXISTS '{db_user}'@'%' IDENTIFIED BY '{db_password}';
GRANT ALL PRIVILEGES ON *.* TO '{db_user}'@'%' WITH GRANT OPTION;

# Create all required databases
"""
            for db in databases:
                init_content += f"CREATE DATABASE IF NOT EXISTS `{db}`;\n"
            
            init_content += "\nFLUSH PRIVILEGES;\n"
            
            # Ensure init directory exists
            os.makedirs(os.path.dirname(init_sql), exist_ok=True)
            
            # Write using safe_write_file to handle permissions
            success, error = safe_write_file(init_sql, init_content)
            if success:
                results['steps'].append('✓ Updated init/01.sql')
            else:
                results['errors'].append(f'Failed to update init/01.sql: {error}')
        except Exception as e:
            results['errors'].append(f'Error updating init/01.sql: {e}')
    
    results['success'] = len(results['errors']) == 0
    
    return jsonify(results)

@app.route('/api/mariadb/test-connection', methods=['POST'])
def api_mariadb_test_connection():
    """Test MariaDB connection directly via localhost:3306"""
    data = request.json or {}
    
    user = data.get('user', 'root')
    password = data.get('password', '')
    host = data.get('host', 'localhost')
    port = data.get('port', 3306)
    database = data.get('database', '')
    
    result = {
        'success': False,
        'message': '',
        'details': {
            'host': host,
            'port': port,
            'user': user
        }
    }
    
    # First, try to connect directly using socket (fastest check)
    import socket
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock_result = sock.connect_ex((host, port))
        sock.close()
        
        if sock_result != 0:
            result['message'] = f'Cannot reach MariaDB on {host}:{port} - is the database running?'
            result['details']['port_open'] = False
            return jsonify(result)
        
        result['details']['port_open'] = True
    except Exception as e:
        result['message'] = f'Network error: {e}'
        return jsonify(result)
    
    # Find mysql/mariadb CLI
    mysql_cmd = shutil.which('mariadb') or shutil.which('mysql')
    
    if mysql_cmd:
        # Use local CLI to connect via localhost:3306
        try:
            cmd = [mysql_cmd, '-u', user, f'-p{password}', '-h', host, '-P', str(port)]
            if database:
                cmd.extend(['-D', database])
            cmd.extend(['-e', 'SELECT VERSION() as version, NOW() as server_time'])
            
            test_result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            
            if test_result.returncode == 0:
                result['success'] = True
                result['message'] = f'Connection successful to {host}:{port}!'
                result['details']['method'] = 'local_cli'
                # Parse output for version info
                for line in test_result.stdout.strip().split('\n'):
                    if 'MariaDB' in line or 'MySQL' in line or '-' in line:
                        result['details']['version'] = line.strip()
                        break
            else:
                # Clean up error message (remove password from output if present)
                error = test_result.stderr or 'Connection failed'
                if password in error:
                    error = error.replace(password, '***')
                result['message'] = error
        except subprocess.TimeoutExpired:
            result['message'] = 'Connection timed out'
        except Exception as e:
            result['message'] = str(e)
    else:
        # Fallback: Try using Python socket to do a basic MySQL handshake check
        # This is a simplified check - just verifies MySQL protocol response
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5)
            sock.connect((host, port))
            
            # Read initial handshake packet
            data = sock.recv(1024)
            sock.close()
            
            if len(data) > 5:
                # MySQL/MariaDB sends a greeting packet
                # Extract version from packet (starts at byte 5)
                version_end = data.find(b'\x00', 5)
                if version_end > 5:
                    version = data[5:version_end].decode('utf-8', errors='ignore')
                    result['success'] = True
                    result['message'] = f'MariaDB server responding on {host}:{port}'
                    result['details']['version'] = version
                    result['details']['method'] = 'socket_handshake'
                    result['details']['note'] = 'Install mysql-client for full authentication test'
            else:
                result['message'] = 'Invalid response from server'
        except Exception as e:
            result['message'] = f'Socket connection failed: {e}'
    
    return jsonify(result)

@app.route('/api/mariadb/install', methods=['POST'])
def api_mariadb_install():
    """Install MariaDB server (system-level, requires sudo)"""
    result = {
        'success': False,
        'message': '',
        'output': ''
    }
    
    try:
        # First check if it's already installed
        check = subprocess.run(['which', 'mariadb'], capture_output=True, text=True)
        if check.returncode == 0:
            result['success'] = True
            result['message'] = 'MariaDB is already installed'
            return jsonify(result)
        
        # Detect package manager and install
        if shutil.which('apt'):
            install_result = subprocess.run(
                ['sudo', 'apt', 'update', '&&', 'sudo', 'apt', 'install', '-y', 'mariadb-server'],
                capture_output=True, text=True, timeout=300, shell=True
            )
        elif shutil.which('yum'):
            install_result = subprocess.run(
                ['sudo', 'yum', 'install', '-y', 'mariadb-server'],
                capture_output=True, text=True, timeout=300
            )
        else:
            result['message'] = 'Unsupported package manager. Please install MariaDB manually.'
            return jsonify(result)
        
        result['output'] = install_result.stdout + '\n' + install_result.stderr
        result['success'] = install_result.returncode == 0
        result['message'] = 'MariaDB installed successfully' if result['success'] else 'Installation failed'
        
    except Exception as e:
        result['message'] = str(e)
    
    return jsonify(result)

# =============================================================================
# FLETCHLING - Nest Detection Setup & Management
# =============================================================================

@app.route('/api/fletchling/status')
def api_fletchling_status():
    """Get comprehensive Fletchling status for management tab"""
    aegis_root = str(AEGIS_ROOT)
    
    status = {
        'docker_compose': {
            'enabled': False,
            'comment_status': 'unknown'
        },
        'config': {
            'file_exists': False,
            'project_configured': False,
            'project_name': None,
            'has_placeholder': False,
            'db_configured': False
        },
        'container': {
            'running': False,
            'tools_running': False,
            'health': 'unknown',
            'image': None
        },
        'database': {
            'nests_table_exists': False,
            'nests_count': 0,
            'active_nests': 0,
            'last_updated': None
        },
        'golbat_webhook': {
            'configured': False
        }
    }
    
    # Check docker-compose.yaml for fletchling service
    compose_file = os.path.join(aegis_root, 'docker-compose.yaml')
    if os.path.exists(compose_file):
        try:
            with open(compose_file, 'r') as f:
                compose_content = f.read()
            
            # Check if fletchling is commented out
            if '# fletchling:' in compose_content:
                status['docker_compose']['enabled'] = False
                status['docker_compose']['comment_status'] = 'commented'
            elif 'fletchling:' in compose_content:
                status['docker_compose']['enabled'] = True
                status['docker_compose']['comment_status'] = 'enabled'
            else:
                status['docker_compose']['comment_status'] = 'not_found'
        except Exception as e:
            status['docker_compose']['comment_status'] = f'error: {str(e)[:30]}'
    
    # Check fletchling.toml config
    config_file = os.path.join(aegis_root, 'fletchling.toml')
    if os.path.exists(config_file):
        status['config']['file_exists'] = True
        try:
            with open(config_file, 'r') as f:
                config_content = f.read()
            
            # Check for placeholder
            if 'YOUR-PROJECT-IN-KOJI-ADMIN-HERE' in config_content:
                status['config']['has_placeholder'] = True
                status['config']['project_configured'] = False
            else:
                status['config']['has_placeholder'] = False
                # Extract project name from koji_url
                import re
                match = re.search(r'koji_url\s*=\s*"[^"]*feature-collection/([^"]+)"', config_content)
                if match:
                    status['config']['project_name'] = match.group(1)
                    status['config']['project_configured'] = True
            
            # Check if database is configured
            if '${MYSQL_ROOT_PASSWORD}' in config_content or 'password = "' in config_content:
                status['config']['db_configured'] = True
        except Exception as e:
            pass
    
    # Check container status
    try:
        result = subprocess.run(
            ['docker', 'ps', '--format', '{{.Names}}:{{.Status}}:{{.Image}}'],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            for line in result.stdout.strip().split('\n'):
                if not line:
                    continue
                parts = line.split(':')
                name = parts[0] if len(parts) > 0 else ''
                container_status = parts[1] if len(parts) > 1 else ''
                image = parts[2] if len(parts) > 2 else ''
                
                if name == 'fletchling':
                    status['container']['running'] = 'Up' in container_status
                    status['container']['health'] = 'healthy' if 'healthy' in container_status else 'running' if 'Up' in container_status else 'unhealthy'
                    status['container']['image'] = image
                elif name == 'fletchling-tools':
                    status['container']['tools_running'] = 'Up' in container_status
    except Exception as e:
        pass
    
    # Check nests table in golbat database
    try:
        result = subprocess.run(
            ['docker', 'exec', 'database', 'mysql', '-u', 'root', '-e',
             'SELECT COUNT(*) as count FROM golbat.nests 2>/dev/null; SELECT COUNT(*) as active FROM golbat.nests WHERE pokemon_id > 0 2>/dev/null;'],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and 'count' in result.stdout:
            status['database']['nests_table_exists'] = True
            lines = result.stdout.strip().split('\n')
            for i, line in enumerate(lines):
                if 'count' in line.lower() and i + 1 < len(lines):
                    try:
                        status['database']['nests_count'] = int(lines[i + 1].strip())
                    except:
                        pass
                if 'active' in line.lower() and i + 1 < len(lines):
                    try:
                        status['database']['active_nests'] = int(lines[i + 1].strip())
                    except:
                        pass
        elif 'exist' in result.stderr.lower() or 'exist' in result.stdout.lower():
            status['database']['nests_table_exists'] = False
    except Exception as e:
        pass
    
    # Check golbat webhook configuration
    golbat_config = os.path.join(aegis_root, 'unown', 'golbat_config.toml')
    if os.path.exists(golbat_config):
        try:
            with open(golbat_config, 'r') as f:
                golbat_content = f.read()
            if 'fletchling' in golbat_content.lower() and 'webhook' in golbat_content.lower():
                status['golbat_webhook']['configured'] = True
        except:
            pass
    
    return jsonify(status)


@app.route('/api/fletchling/enable', methods=['POST'])
def api_fletchling_enable():
    """Enable Fletchling in docker-compose.yaml by uncommenting the service"""
    aegis_root = str(AEGIS_ROOT)
    compose_file = os.path.join(aegis_root, 'docker-compose.yaml')
    
    result = {'success': False, 'message': '', 'changes': []}
    
    if not os.path.exists(compose_file):
        result['message'] = 'docker-compose.yaml not found'
        return jsonify(result), 404
    
    try:
        with open(compose_file, 'r') as f:
            content = f.read()
        
        if '# fletchling:' not in content:
            if 'fletchling:' in content:
                result['success'] = True
                result['message'] = 'Fletchling is already enabled'
            else:
                result['message'] = 'Fletchling service not found in docker-compose.yaml'
            return jsonify(result)
        
        # Uncomment fletchling and fletchling-tools sections
        lines = content.split('\n')
        new_lines = []
        in_fletchling_section = False
        section_depth = 0
        
        for line in lines:
            # Detect start of fletchling or fletchling-tools section
            if line.strip() == '# fletchling:' or line.strip() == '# fletchling-tools:':
                in_fletchling_section = True
                section_depth = 0
                new_lines.append(line.lstrip('# ').rstrip())
                result['changes'].append(f'Enabled: {line.strip().replace("# ", "")}')
                continue
            
            if in_fletchling_section:
                # Check if we're still in the section (by indentation or next service)
                if line.strip() and not line.startswith('#') and not line.startswith(' ') and not line.startswith('\t'):
                    in_fletchling_section = False
                elif line.strip().startswith('# ') and line.strip()[2:3] not in [' ', '\t', '']:
                    # This is a commented line in the section
                    new_lines.append(line.replace('# ', '  ', 1))
                    continue
                elif line.strip().startswith('#') and not line.strip().startswith('# '):
                    # Empty comment or other
                    new_lines.append(line)
                    continue
            
            new_lines.append(line)
        
        new_content = '\n'.join(new_lines)
        
        # Write back
        success, error = safe_write_file(compose_file, new_content)
        if success:
            result['success'] = True
            result['message'] = 'Fletchling enabled in docker-compose.yaml'
        else:
            result['message'] = f'Failed to write: {error}'
    
    except Exception as e:
        result['message'] = str(e)
    
    return jsonify(result)


@app.route('/api/fletchling/configure', methods=['POST'])
def api_fletchling_configure():
    """Configure fletchling.toml with project name"""
    aegis_root = str(AEGIS_ROOT)
    config_file = os.path.join(aegis_root, 'fletchling.toml')
    
    data = request.json or {}
    project_name = data.get('project_name', '').strip()
    
    result = {'success': False, 'message': ''}
    
    if not project_name:
        result['message'] = 'Project name is required'
        return jsonify(result), 400
    
    if not os.path.exists(config_file):
        result['message'] = 'fletchling.toml not found'
        return jsonify(result), 404
    
    try:
        with open(config_file, 'r') as f:
            content = f.read()
        
        # Replace placeholder with project name
        if 'YOUR-PROJECT-IN-KOJI-ADMIN-HERE' in content:
            content = content.replace('YOUR-PROJECT-IN-KOJI-ADMIN-HERE', project_name)
        else:
            # Update existing project name
            import re
            content = re.sub(
                r'(koji_url\s*=\s*"[^"]*feature-collection/)[^"]+"',
                f'\\1{project_name}"',
                content
            )
        
        success, error = safe_write_file(config_file, content)
        if success:
            result['success'] = True
            result['message'] = f'Configured Fletchling with project: {project_name}'
        else:
            result['message'] = f'Failed to write: {error}'
    
    except Exception as e:
        result['message'] = str(e)
    
    return jsonify(result)


@app.route('/api/fletchling/add-webhook', methods=['POST'])
def api_fletchling_add_webhook():
    """Add Fletchling webhook to golbat_config.toml"""
    aegis_root = str(AEGIS_ROOT)
    golbat_config = os.path.join(aegis_root, 'unown', 'golbat_config.toml')
    
    result = {'success': False, 'message': ''}
    
    if not os.path.exists(golbat_config):
        result['message'] = 'golbat_config.toml not found'
        return jsonify(result), 404
    
    try:
        with open(golbat_config, 'r') as f:
            content = f.read()
        
        # Check if already configured
        if 'fletchling' in content.lower():
            result['success'] = True
            result['message'] = 'Fletchling webhook already configured in Golbat'
            return jsonify(result)
        
        # Add webhook section
        webhook_config = '''
# Fletchling nest detection webhook
[[webhooks]]
url = "http://fletchling:9042/webhook"
types = ["pokemon_iv"]
'''
        content += webhook_config
        
        success, error = safe_write_file(golbat_config, content)
        if success:
            result['success'] = True
            result['message'] = 'Added Fletchling webhook to Golbat config. Restart Golbat to apply.'
        else:
            result['message'] = f'Failed to write: {error}'
    
    except Exception as e:
        result['message'] = str(e)
    
    return jsonify(result)


@app.route('/api/fletchling/start', methods=['POST'])
def api_fletchling_start():
    """Start Fletchling containers"""
    result = {'success': False, 'message': '', 'output': ''}
    
    try:
        # Start containers
        proc = subprocess.run(
            ['docker', 'compose', 'up', '-d', 'fletchling', 'fletchling-tools'],
            capture_output=True, text=True, timeout=60,
            cwd=str(AEGIS_ROOT)
        )
        result['output'] = proc.stdout + '\n' + proc.stderr
        result['success'] = proc.returncode == 0
        result['message'] = 'Fletchling containers started' if result['success'] else 'Failed to start containers'
    except Exception as e:
        result['message'] = str(e)
    
    return jsonify(result)


@app.route('/api/fletchling/stop', methods=['POST'])
def api_fletchling_stop():
    """Stop Fletchling containers"""
    result = {'success': False, 'message': '', 'output': ''}
    
    try:
        proc = subprocess.run(
            ['docker', 'compose', 'stop', 'fletchling', 'fletchling-tools'],
            capture_output=True, text=True, timeout=60,
            cwd=str(AEGIS_ROOT)
        )
        result['output'] = proc.stdout + '\n' + proc.stderr
        result['success'] = proc.returncode == 0
        result['message'] = 'Fletchling containers stopped' if result['success'] else 'Failed to stop containers'
    except Exception as e:
        result['message'] = str(e)
    
    return jsonify(result)


# =============================================================================
# INTERACTIVE TERMINAL FOR SCRIPTS (subprocess + PTY)
# =============================================================================

import pty
import select

# Track active terminal sessions
terminal_sessions = {}

class TerminalSession:
    """Manages an interactive PTY session using subprocess"""
    
    def __init__(self, session_id, script_path, cwd):
        self.session_id = session_id
        self.script_path = script_path
        self.cwd = cwd
        self.process = None
        self.master_fd = None
        self.started = datetime.now().isoformat()
        self.active = False
        
    def start(self):
        """Start the PTY process using subprocess"""
        import pty
        import subprocess
        
        # Create master/slave PTY pair
        self.master_fd, slave_fd = pty.openpty()
        
        # Set up environment
        env = os.environ.copy()
        env['TERM'] = 'xterm-256color'
        env['COLUMNS'] = '120'
        env['LINES'] = '30'
        
        # Try to run without sudo first (service may already have privileges)
        # If we're root, run directly; otherwise try sudo without password
        if os.geteuid() == 0:
            cmd = ['bash', self.script_path]
        else:
            # Use sudo with -n (non-interactive, fails if password needed)
            # Fall back to direct execution if sudo fails
            cmd = ['sudo', '-n', 'bash', self.script_path]
        
        # Start process with PTY
        self.process = subprocess.Popen(
            cmd,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            cwd=self.cwd,
            env=env,
            preexec_fn=os.setsid
        )
        
        # Close slave in parent
        os.close(slave_fd)
        self.active = True
        
    def read_output(self):
        """Read available output from PTY"""
        if not self.active or self.master_fd is None:
            return None
            
        try:
            # Check if data available (non-blocking)
            import select
            ready, _, _ = select.select([self.master_fd], [], [], 0.1)
            if ready:
                data = os.read(self.master_fd, 4096)
                if data:
                    return data.decode('utf-8', errors='replace')
                else:
                    # EOF - process ended
                    self.active = False
        except (OSError, IOError) as e:
            if e.errno != 11:  # EAGAIN is ok
                self.active = False
        return None
        
    def write_input(self, data):
        """Write input to PTY"""
        if not self.active or self.master_fd is None:
            return False
            
        try:
            os.write(self.master_fd, data.encode('utf-8'))
            return True
        except (OSError, IOError):
            self.active = False
            return False
                
    def is_alive(self):
        """Check if process is still running"""
        if self.process is None:
            return False
        poll = self.process.poll()
        if poll is not None:
            self.active = False
            return False
        return True
            
    def terminate(self):
        """Terminate the session and ALL child processes"""
        self.active = False
        if self.master_fd is not None:
            try:
                os.close(self.master_fd)
            except:
                pass
            self.master_fd = None
        if self.process is not None:
            try:
                # Kill the entire process group (all children spawned by the script)
                # We use os.setsid in preexec_fn, so the process is its own group leader
                pgid = os.getpgid(self.process.pid)
                os.killpg(pgid, signal.SIGTERM)
                self.process.wait(timeout=3)
            except ProcessLookupError:
                pass  # Process already dead
            except Exception:
                try:
                    # Fallback: force kill the process group
                    pgid = os.getpgid(self.process.pid)
                    os.killpg(pgid, signal.SIGKILL)
                except:
                    pass
                try:
                    # Also try killing just the main process
                    self.process.kill()
                except:
                    pass

def terminal_output_reader(session_id):
    """Background thread to read terminal output and emit via WebSocket"""
    session = terminal_sessions.get(session_id)
    if not session:
        return
    
    while session.active and session.is_alive():
        try:
            output = session.read_output()
            if output and socketio and SOCKETIO_AVAILABLE:
                socketio.emit('terminal_output', {
                    'session_id': session_id,
                    'data': output
                })
        except Exception as e:
            info('TERMINAL', f'Read error: {e}')
            break
        time.sleep(0.02)  # Small delay
    
    # Give a moment for final output
    time.sleep(0.2)
    try:
        final_output = session.read_output()
        if final_output and socketio and SOCKETIO_AVAILABLE:
            socketio.emit('terminal_output', {
                'session_id': session_id,
                'data': final_output
            })
    except:
        pass
    
    # Session ended
    if socketio and SOCKETIO_AVAILABLE:
        exit_code = session.process.returncode if session.process else 'unknown'
        socketio.emit('terminal_output', {
            'session_id': session_id,
            'data': f'\r\n\033[33m[Script exited with code: {exit_code}]\033[0m\r\n',
            'ended': True
        })
    
    # Cleanup
    if session_id in terminal_sessions:
        terminal_sessions[session_id].terminate()
        del terminal_sessions[session_id]

@app.route('/api/terminal/start/<script>', methods=['POST'])
def api_terminal_start(script):
    """Start an interactive terminal session for a script"""
    aegis_root = str(AEGIS_ROOT)
    
    # Whitelist allowed scripts
    allowed_scripts = ['setup.sh', 'dbsetup.sh', 'nginx-setup.sh', 'check.sh', 
                       'fletchling.sh', 'poracle.sh', 'logs.sh', 'shellder.sh']
    if script not in allowed_scripts:
        return jsonify({'error': f'Script not allowed'}), 400
    
    # Find script path
    if script == 'shellder.sh':
        script_path = os.path.join(aegis_root, script)
    else:
        script_path = os.path.join(aegis_root, 'Shellder', script)
        
    if not os.path.exists(script_path):
        return jsonify({'error': 'Script not found', 'path': script_path}), 404
    
    # Generate session ID
    session_id = f"term_{script}_{int(time.time())}"
    
    # Check if same script already has active session
    for sid, session in list(terminal_sessions.items()):
        if not session.is_alive():
            # Clean up dead sessions
            session.terminate()
            del terminal_sessions[sid]
        elif session.script_path == script_path:
            return jsonify({
                'error': f'{script} already has an active session',
                'session_id': sid
            }), 409
    
    try:
        # Create and start session
        session = TerminalSession(session_id, script_path, aegis_root)
        session.start()
        terminal_sessions[session_id] = session
        
        info('TERMINAL', f'Started session {session_id} for {script}')
        
        # Start output reader thread
        thread = threading.Thread(
            target=terminal_output_reader,
            args=(session_id,),
            daemon=True
        )
        thread.start()
        
        return jsonify({
            'success': True,
            'session_id': session_id,
            'script': script
        })
        
    except Exception as e:
        import traceback
        error('TERMINAL', f'Failed to start: {e}', {'traceback': traceback.format_exc()})
        return jsonify({'error': str(e)}), 500

@app.route('/api/terminal/input/<session_id>', methods=['POST'])
def api_terminal_input(session_id):
    """Send input to terminal session"""
    session = terminal_sessions.get(session_id)
    if not session:
        return jsonify({'error': 'Session not found'}), 404
        
    data = request.json.get('data', '')
    if session.write_input(data):
        return jsonify({'success': True})
    return jsonify({'error': 'Failed to write'}), 500

@app.route('/api/terminal/stop/<session_id>', methods=['POST'])
def api_terminal_stop(session_id):
    """Stop terminal session"""
    session = terminal_sessions.get(session_id)
    if session:
        session.terminate()
        if session_id in terminal_sessions:
            del terminal_sessions[session_id]
    return jsonify({'success': True})

@app.route('/api/terminal/sessions')
def api_terminal_sessions():
    """Get active terminal sessions"""
    return jsonify({
        'sessions': [
            {
                'session_id': sid,
                'script': os.path.basename(s.script_path),
                'started': s.started,
                'active': s.is_alive()
            }
            for sid, s in terminal_sessions.items()
        ]
    })

# Legacy endpoint for backwards compatibility
@app.route('/api/setup/run/<script>', methods=['POST'])
def api_setup_run_script(script):
    """Redirect to terminal start"""
    return api_terminal_start(script)

@app.route('/api/config/schema/<path:config_path>')
def api_config_schema(config_path):
    """Get field schema and current values for a config file"""
    if config_path not in CONFIG_FIELD_SCHEMAS:
        return jsonify({'error': 'No schema available for this config', 'has_schema': False}), 200
    
    schema = CONFIG_FIELD_SCHEMAS[config_path]
    aegis_root = str(AEGIS_ROOT)
    full_path = os.path.join(aegis_root, config_path)
    
    # Parse current values if file exists
    current_values = {}
    if os.path.exists(full_path):
        try:
            if schema['format'] == 'toml':
                # Try tomli first, fall back to our simple parser
                try:
                    import tomli
                    with open(full_path, 'rb') as f:
                        current_values = tomli.load(f)
                except ImportError:
                    # Use our simple TOML parser as fallback
                    current_values = parse_simple_toml(full_path)
            elif schema['format'] == 'json':
                with open(full_path, 'r') as f:
                    current_values = json.load(f)
        except Exception as e:
            current_values = {'_parse_error': str(e)}
    
    # Add shared field information to the response
    shared_fields_info = {}
    for section_key, section_info in schema['sections'].items():
        for field_key, field_info in section_info['fields'].items():
            if 'shared' in field_info:
                shared_key = field_info['shared']
                if shared_key in SHARED_FIELDS:
                    shared_data = SHARED_FIELDS[shared_key]
                    # Find other configs that use this field
                    other_configs = [c for c in shared_data['configs'] if c != config_path]
                    shared_fields_info[f"{section_key}.{field_key}"] = {
                        'key': shared_key,
                        'label': shared_data['label'],
                        'desc': shared_data['desc'],
                        'color': shared_data['color'],
                        'other_configs': other_configs,
                        'total_configs': len(shared_data['configs'])
                    }
    
    return jsonify({
        'has_schema': True,
        'format': schema['format'],
        'sections': schema['sections'],
        'current_values': current_values,
        'exists': os.path.exists(full_path),
        'shared_fields': shared_fields_info,
        'all_shared_definitions': SHARED_FIELDS
    })

def is_default_placeholder(value, default_placeholder=None):
    """Check if a value is still at a default placeholder from setup.sh
    
    Args:
        value: The current value to check
        default_placeholder: The specific default for this field (optional)
        
    Returns:
        True if value appears to be an unconfigured default
    """
    # Empty/None is only "default" if the placeholder itself is not empty
    # (some secrets like ROTOM_AUTH_BEARER have empty defaults, meaning any value is valid)
    if not value:
        # If default_placeholder is also empty/None, empty value is "configured as empty"
        # Otherwise, empty value means "not yet configured"
        if default_placeholder is not None and not default_placeholder:
            return False  # Empty is a valid configured value for this field
        return True
    
    str_value = str(value).strip()
    
    # Check if it's a known placeholder pattern
    if str_value in DEFAULT_PLACEHOLDERS:
        return True
    if str_value.startswith('SuperSecure'):
        return True
    
    # Check if it matches the specific default for this field
    if default_placeholder and str_value == str(default_placeholder).strip():
        return True
    
    return False


def parse_config_value(aegis_root, config_file, field_path):
    """Parse a value from a config file given the field path
    
    Supports:
    - Dot notation for nested objects: 'db.dragonite.user'
    - Numeric indices for arrays: 'database.schemas.1.username'
    """
    full_path = os.path.join(aegis_root, config_file)
    
    if not os.path.exists(full_path):
        return None, 'file_missing'
    
    try:
        if config_file.endswith('.toml'):
            data = parse_simple_toml(full_path)
            if not data:
                return None, 'parse_error'
        elif config_file.endswith('.json'):
            with open(full_path) as f:
                data = json.load(f)
        else:
            return None, 'unsupported'
        
        # Navigate to field
        parts = field_path.split('.')
        current = data
        for part in parts:
            # Handle array indices (numeric parts)
            if part.isdigit():
                idx = int(part)
                if isinstance(current, list) and idx < len(current):
                    current = current[idx]
                else:
                    return None, 'index_out_of_bounds'
            elif isinstance(current, dict) and part in current:
                current = current[part]
            else:
                return None, 'field_missing'
        return current, 'ok'
    except Exception as e:
        return None, f'error:{str(e)[:30]}'


@app.route('/api/config/variables-status')
def api_config_variables_status():
    """Get status of REQUIRED config variables (secrets that must be changed from defaults)"""
    aegis_root = str(AEGIS_ROOT)
    env_file = os.path.join(aegis_root, '.env')
    
    # Load .env values
    env_values = {}
    if os.path.exists(env_file):
        try:
            with open(env_file) as f:
                for line in f:
                    line = line.strip()
                    if '=' in line and not line.startswith('#'):
                        key, value = line.split('=', 1)
                        env_values[key] = value.strip('"\'')
        except:
            pass
    
    # Check each shared variable across all config files
    variables_status = {}
    
    for var_name, paths in SHARED_VARIABLE_PATHS.items():
        config_values = {}
        all_values = []
        
        # Get the default placeholder for this variable from AEGIS_SECRETS
        default_placeholder = None
        if var_name in AEGIS_SECRETS:
            default_placeholder = AEGIS_SECRETS[var_name].get('default_placeholder', '')
        
        # Get value from each config file
        for config_file, field_path in paths.items():
            if field_path is None:
                continue
            
            if config_file == '.env':
                value = env_values.get(var_name, '')
                config_values['.env'] = {
                    'value': value,
                    'is_default': is_default_placeholder(value, default_placeholder),
                    'status': 'ok'
                }
                if value:
                    all_values.append(value)
            else:
                value, status = parse_config_value(aegis_root, config_file, field_path)
                config_values[config_file] = {
                    'value': value if value else '',
                    'is_default': is_default_placeholder(value, default_placeholder),
                    'status': status
                }
                if value and status == 'ok':
                    all_values.append(str(value))
        
        # Determine sync status
        unique_non_default = set(v for v in all_values if not is_default_placeholder(v, default_placeholder))
        all_still_default = all(is_default_placeholder(v, default_placeholder) for v in all_values) if all_values else True
        all_match = len(unique_non_default) <= 1
        is_configured = len(unique_non_default) > 0
        
        if all_still_default:
            sync_status = 'not_configured'
        elif all_match and is_configured:
            sync_status = 'synced'
        else:
            sync_status = 'mismatch'
        
        # Get label and description from CONFIG_VARIABLE_CATEGORIES
        label = var_name
        desc = ''
        for cat_info in CONFIG_VARIABLE_CATEGORIES.values():
            if var_name in cat_info.get('variables', {}):
                var_info = cat_info['variables'][var_name]
                label = var_info.get('label', var_name)
                desc = var_info.get('desc', '')
                break
        
        variables_status[var_name] = {
            'label': label,
            'desc': desc,
            'configs': config_values,
            'sync_status': sync_status,
            'is_configured': is_configured,
            'all_match': all_match,
            'unique_values': list(unique_non_default)
        }
    
    # Build summary
    total = len(variables_status)
    configured = sum(1 for v in variables_status.values() if v['is_configured'])
    synced = sum(1 for v in variables_status.values() if v['sync_status'] == 'synced')
    mismatched = sum(1 for v in variables_status.values() if v['sync_status'] == 'mismatch')
    not_configured = sum(1 for v in variables_status.values() if v['sync_status'] == 'not_configured')
    
    # Overall status
    if mismatched > 0:
        overall_status = 'mismatch'
    elif not_configured > 0:
        overall_status = 'incomplete'
    elif synced == total:
        overall_status = 'synced'
    else:
        overall_status = 'ok'
    
    return jsonify({
        'variables': variables_status,
        'summary': {
            'total': total,
            'configured': configured,
            'synced': synced,
            'mismatched': mismatched,
            'not_configured': not_configured,
            'overall_status': overall_status
        },
        'categories': CONFIG_VARIABLE_CATEGORIES
    })

@app.route('/api/config/sync-field', methods=['POST'])
def api_config_sync_field():
    """Sync a field value across all configs that share it"""
    data = request.get_json()
    shared_key = data.get('shared_key')
    new_value = data.get('value')
    source_config = data.get('source_config')
    
    if not shared_key or new_value is None:
        return jsonify({'error': 'shared_key and value are required'}), 400
    
    if shared_key not in SHARED_FIELDS:
        return jsonify({'error': f'Unknown shared field: {shared_key}'}), 400
    
    shared_info = SHARED_FIELDS[shared_key]
    aegis_root = str(AEGIS_ROOT)
    results = []
    
    for config_path in shared_info['configs']:
        if config_path not in CONFIG_FIELD_SCHEMAS:
            results.append({'config': config_path, 'status': 'skipped', 'reason': 'No schema'})
            continue
        
        schema = CONFIG_FIELD_SCHEMAS[config_path]
        full_path = os.path.join(aegis_root, config_path)
        
        if not os.path.exists(full_path):
            results.append({'config': config_path, 'status': 'skipped', 'reason': 'File does not exist'})
            continue
        
        try:
            # Find which field in this config uses this shared key
            field_path = None
            for section_key, section_info in schema['sections'].items():
                for field_key, field_info in section_info['fields'].items():
                    if field_info.get('shared') == shared_key:
                        field_path = (section_key, field_key)
                        break
                if field_path:
                    break
            
            if not field_path:
                results.append({'config': config_path, 'status': 'skipped', 'reason': 'Field not found in schema'})
                continue
            
            # Read current config
            with open(full_path, 'r') as f:
                content = f.read()
            
            # Update the value based on format
            if schema['format'] == 'toml':
                updated_content = update_toml_field(content, field_path[0], field_path[1], new_value, schema['sections'][field_path[0]]['fields'][field_path[1]])
            elif schema['format'] == 'json':
                updated_content = update_json_field(content, field_path[0], field_path[1], new_value)
            else:
                results.append({'config': config_path, 'status': 'error', 'reason': 'Unsupported format'})
                continue
            
            # Write updated config with ownership preservation
            success, error_msg = safe_write_file(full_path, updated_content)
            
            if success:
                results.append({'config': config_path, 'status': 'success', 'field': f"{field_path[0]}.{field_path[1]}"})
            else:
                results.append({'config': config_path, 'status': 'error', 'reason': error_msg})
                
        except Exception as e:
            results.append({'config': config_path, 'status': 'error', 'reason': str(e)})
    
    return jsonify({
        'success': True,
        'shared_key': shared_key,
        'value': '***' if 'password' in shared_key or 'secret' in shared_key else new_value,
        'results': results
    })

def update_toml_field(content, section, field, value, field_info):
    """Update a specific field in TOML content"""
    lines = content.split('\n')
    in_section = False
    section_pattern = re.compile(r'^\s*\[' + re.escape(section) + r'\]\s*$')
    field_pattern = re.compile(r'^(\s*)' + re.escape(field) + r'\s*=')
    new_section_pattern = re.compile(r'^\s*\[')
    
    field_updated = False
    result_lines = []
    
    for i, line in enumerate(lines):
        # Check if we're entering the target section
        if section_pattern.match(line):
            in_section = True
            result_lines.append(line)
            continue
        
        # Check if we're leaving the section
        if in_section and new_section_pattern.match(line) and not section_pattern.match(line):
            # If field wasn't found in section, add it before leaving
            if not field_updated:
                formatted_value = format_toml_value(value, field_info)
                result_lines.append(f'{field} = {formatted_value}')
                field_updated = True
            in_section = False
        
        # Check if this is our field
        if in_section and field_pattern.match(line):
            formatted_value = format_toml_value(value, field_info)
            # Preserve any inline comments
            comment = ''
            if '#' in line:
                comment = ' #' + line.split('#', 1)[1]
            result_lines.append(f'{field} = {formatted_value}{comment}')
            field_updated = True
            continue
        
        result_lines.append(line)
    
    # If we never found the section or field, we might need to add them
    if not field_updated:
        # This is a simplified case - in practice you'd want more robust handling
        formatted_value = format_toml_value(value, field_info)
        result_lines.append('')
        result_lines.append(f'[{section}]')
        result_lines.append(f'{field} = {formatted_value}')
    
    return '\n'.join(result_lines)

def format_toml_value(value, field_info):
    """Format a value for TOML based on field type"""
    field_type = field_info.get('type', 'text')
    if field_type in ('text', 'password'):
        # Escape quotes and backslashes
        escaped = str(value).replace('\\', '\\\\').replace('"', '\\"')
        return f'"{escaped}"'
    elif field_type == 'number':
        return str(value)
    elif field_type == 'checkbox':
        return 'true' if value else 'false'
    else:
        return f'"{value}"'

def update_json_field(content, section, field, value):
    """Update a specific field in JSON content"""
    try:
        data = json.loads(content)
        
        # Handle nested sections like "api.kojiOptions" or "map.general"
        if '.' in section:
            parts = section.split('.')
            target = data
            for part in parts[:-1]:
                if part not in target:
                    target[part] = {}
                target = target[part]
            if parts[-1] not in target:
                target[parts[-1]] = {}
            target[parts[-1]][field] = value
        elif section == 'database_golbat':
            # Special handling for ReactMap database schemas
            if 'database' in data and 'schemas' in data['database']:
                for schema in data['database']['schemas']:
                    if schema.get('type') == 'golbat':
                        schema[field] = value
                        break
        elif section == 'database_main':
            # Special handling for ReactMap database schemas (main DB)
            if 'database' in data and 'schemas' in data['database']:
                for schema in data['database']['schemas']:
                    if 'useFor' in schema and 'gym' in schema.get('useFor', []):
                        schema[field] = value
                        break
        else:
            if section not in data:
                data[section] = {}
            data[section][field] = value
        
        return json.dumps(data, indent=2)
    except Exception as e:
        raise Exception(f'Failed to update JSON: {e}')

# =============================================================================
# COMPREHENSIVE SECRET MANAGEMENT API
# =============================================================================

@app.route('/api/secrets/list')
def api_secrets_list():
    """Get list of all secrets and their current status"""
    aegis_root = str(AEGIS_ROOT)
    secrets_status = {}
    
    for secret_key, secret_info in AEGIS_SECRETS.items():
        # Check if secret has non-default value in .env
        current_value = None
        is_default = True
        
        # Try to read from .env
        env_path = os.path.join(aegis_root, '.env')
        if os.path.exists(env_path):
            try:
                with open(env_path, 'r') as f:
                    for line in f:
                        if line.startswith(f'{secret_key}='):
                            current_value = line.split('=', 1)[1].strip().strip('"\'')
                            is_default = current_value == secret_info.get('default_placeholder', '')
                            break
            except:
                pass
        
        # Also check if it's a default placeholder value
        default_placeholder = secret_info.get('default_placeholder', '')
        if current_value and default_placeholder:
            if current_value == default_placeholder or current_value in DEFAULT_PLACEHOLDERS:
                is_default = True
        
        # Get target file names
        target_files = [t['file'] for t in secret_info['targets']]
        
        secrets_status[secret_key] = {
            'label': secret_info['label'],
            'desc': secret_info['desc'],
            'category': secret_info['category'],
            'color': secret_info['color'],
            'is_default': is_default,
            'has_value': current_value is not None and current_value != '',
            'current_value': current_value if current_value else '',
            'target_count': len(secret_info['targets']),
            'target_files': target_files,
            'generate_length': secret_info.get('generate_length', 32)
        }
    
    return jsonify({
        'secrets': secrets_status,
        'categories': {
            'database': {'label': '🗄️ Database', 'order': 1},
            'api': {'label': '🔑 API Secrets', 'order': 2}
        }
    })

@app.route('/api/secrets/apply', methods=['POST'])
def api_secrets_apply():
    """Apply one or more secrets to ALL their target config files"""
    data = request.get_json()
    secrets_to_apply = data.get('secrets', {})  # {secret_key: value}
    
    if not secrets_to_apply:
        return jsonify({'error': 'No secrets provided'}), 400
    
    aegis_root = str(AEGIS_ROOT)
    results = []
    
    for secret_key, new_value in secrets_to_apply.items():
        if secret_key not in AEGIS_SECRETS:
            results.append({
                'secret': secret_key,
                'status': 'error',
                'reason': f'Unknown secret key: {secret_key}'
            })
            continue
        
        if not new_value:
            results.append({
                'secret': secret_key,
                'status': 'skipped',
                'reason': 'Empty value'
            })
            continue
        
        secret_info = AEGIS_SECRETS[secret_key]
        default_placeholder = secret_info.get('default_placeholder', '')
        target_results = []
        
        for target in secret_info['targets']:
            target_file = target['file']
            full_path = os.path.join(aegis_root, target_file)
            
            if not os.path.exists(full_path):
                target_results.append({
                    'file': target_file,
                    'status': 'skipped',
                    'reason': 'File does not exist'
                })
                continue
            
            try:
                with open(full_path, 'r') as f:
                    content = f.read()
                
                updated_content = content
                
                # Handle different file types
                if target_file.endswith('.json'):
                    # JSON file - use json_path if specified
                    json_path = target.get('json_path')
                    if json_path:
                        updated_content = apply_secret_to_json(content, json_path, new_value, default_placeholder)
                    else:
                        # Simple string replacement
                        updated_content = content.replace(default_placeholder, new_value)
                
                elif target_file.endswith('.toml'):
                    # TOML file - use pattern/section if specified
                    pattern = target.get('pattern')
                    section = target.get('section')
                    if pattern and section:
                        updated_content = apply_secret_to_toml(content, section, pattern, new_value, default_placeholder)
                    elif pattern:
                        # Just pattern replacement
                        updated_content = re.sub(
                            pattern.replace('(.*)', f'({re.escape(default_placeholder)})'),
                            pattern.replace('(.*)', new_value),
                            content
                        )
                    else:
                        updated_content = content.replace(default_placeholder, new_value)
                
                elif target_file.endswith('.sql'):
                    # SQL file - simple replacement
                    updated_content = content.replace(default_placeholder, new_value)
                
                else:
                    # .env or other files - line-based replacement
                    if 'pattern' in target:
                        pattern = target['pattern']
                        if '=' in pattern:
                            # Environment variable pattern like MYSQL_PASSWORD=(.*)
                            var_name = pattern.split('=')[0]
                            lines = content.split('\n')
                            new_lines = []
                            found = False
                            for line in lines:
                                if line.startswith(f'{var_name}='):
                                    new_lines.append(f'{var_name}={new_value}')
                                    found = True
                                else:
                                    new_lines.append(line)
                            # Add the variable if not found
                            if not found:
                                # Find a good spot to add it (after similar vars or at end)
                                new_lines.append(f'{var_name}={new_value}')
                            updated_content = '\n'.join(new_lines)
                        else:
                            updated_content = content.replace(default_placeholder, new_value)
                    else:
                        updated_content = content.replace(default_placeholder, new_value)
                
                # Write the updated content
                if updated_content != content:
                    # Get original file ownership before writing
                    try:
                        import pwd
                        import grp
                        stat_info = os.stat(full_path)
                        original_uid = stat_info.st_uid
                        original_gid = stat_info.st_gid
                    except:
                        original_uid = 1000  # Default to common user
                        original_gid = 1000
                    
                    # Write the file
                    result = subprocess.run(
                        ['sudo', 'tee', full_path],
                        input=updated_content,
                        capture_output=True,
                        text=True,
                        timeout=10
                    )
                    
                    if result.returncode == 0:
                        # Restore original file ownership (prevent root ownership)
                        try:
                            subprocess.run(
                                ['sudo', 'chown', f'{original_uid}:{original_gid}', full_path],
                                capture_output=True,
                                timeout=5
                            )
                        except:
                            pass  # Best effort to restore ownership
                        
                        target_results.append({
                            'file': target_file,
                            'status': 'success'
                        })
                        info('SECRETS', f'Updated {target_file}')
                    else:
                        target_results.append({
                            'file': target_file,
                            'status': 'error',
                            'reason': result.stderr[:100]
                        })
                        error('SECRETS', f'Failed to write {target_file}: {result.stderr[:100]}')
                else:
                    target_results.append({
                        'file': target_file,
                        'status': 'unchanged',
                        'reason': 'Value already set or placeholder not found'
                    })
                    debug('SECRETS', f'{target_file} unchanged - placeholder not found or already set')
                    
            except Exception as e:
                target_results.append({
                    'file': target_file,
                    'status': 'error',
                    'reason': str(e)[:100]
                })
        
        success_count = sum(1 for r in target_results if r['status'] == 'success')
        results.append({
            'secret': secret_key,
            'label': secret_info['label'],
            'status': 'success' if success_count > 0 else 'partial',
            'targets_updated': success_count,
            'targets_total': len(target_results),
            'details': target_results
        })
    
    return jsonify({
        'success': True,
        'results': results,
        'summary': {
            'total_secrets': len(results),
            'successful': sum(1 for r in results if r['status'] == 'success'),
            'partial': sum(1 for r in results if r['status'] == 'partial'),
            'failed': sum(1 for r in results if r['status'] == 'error')
        }
    })

def apply_secret_to_json(content, json_path, new_value, default_placeholder):
    """Apply a secret to a JSON file using a json_path expression"""
    try:
        data = json.loads(content)
        
        # Handle special json_path patterns
        if '[*]' in json_path:
            # Array wildcard - e.g., database.schemas[*].password
            parts = json_path.split('[*]')
            prefix = parts[0].rstrip('.')
            suffix = parts[1].lstrip('.')
            
            # Navigate to the array
            target = data
            for key in prefix.split('.'):
                if key:
                    target = target.get(key, {})
            
            # Update all items in the array
            if isinstance(target, list):
                for item in target:
                    if suffix:
                        # Navigate to the field within each item
                        keys = suffix.split('.')
                        obj = item
                        for key in keys[:-1]:
                            obj = obj.get(key, {})
                        if keys[-1] in obj or obj.get(keys[-1]) == default_placeholder:
                            obj[keys[-1]] = new_value
                    else:
                        # Direct replacement in array items
                        pass
        
        elif '[type=' in json_path:
            # Conditional array access - e.g., database.schemas[type=golbat].secret
            match = re.match(r'(.+)\[(\w+)=(\w+)\]\.(.+)', json_path)
            if match:
                array_path, filter_key, filter_value, field = match.groups()
                
                target = data
                for key in array_path.split('.'):
                    if key:
                        target = target.get(key, {})
                
                if isinstance(target, list):
                    for item in target:
                        if item.get(filter_key) == filter_value:
                            item[field] = new_value
        
        elif '[0]' in json_path:
            # First array element - e.g., webhooks[0].poracleSecret
            parts = json_path.split('[0]')
            prefix = parts[0].rstrip('.')
            suffix = parts[1].lstrip('.')
            
            target = data
            for key in prefix.split('.'):
                if key:
                    target = target.get(key, {})
            
            if isinstance(target, list) and len(target) > 0:
                obj = target[0]
                for key in suffix.split('.')[:-1]:
                    if key:
                        obj = obj.get(key, {})
                final_key = suffix.split('.')[-1]
                if final_key:
                    obj[final_key] = new_value
        
        else:
            # Simple dot notation - e.g., api.sessionSecret
            keys = json_path.split('.')
            target = data
            for key in keys[:-1]:
                if key not in target:
                    target[key] = {}
                target = target[key]
            target[keys[-1]] = new_value
        
        return json.dumps(data, indent=2)
    except Exception as e:
        # Fall back to simple string replacement
        return content.replace(default_placeholder, new_value)

def apply_secret_to_toml(content, section, pattern, new_value, default_placeholder):
    """Apply a secret to a TOML file in a specific section"""
    lines = content.split('\n')
    result_lines = []
    in_section = False
    section_pattern = re.compile(r'^\s*\[' + re.escape(section) + r'\]\s*$')
    new_section_pattern = re.compile(r'^\s*\[')
    
    # Extract field name from pattern like 'password = "(.*)"'
    field_match = re.match(r'(\w+)\s*=', pattern)
    field_name = field_match.group(1) if field_match else None
    
    for line in lines:
        if section_pattern.match(line):
            in_section = True
            result_lines.append(line)
            continue
        
        if in_section and new_section_pattern.match(line) and not section_pattern.match(line):
            in_section = False
        
        if in_section and field_name and line.strip().startswith(f'{field_name} ='):
            # Replace the value
            if default_placeholder in line:
                line = line.replace(default_placeholder, new_value)
            else:
                # Use regex to replace the value portion
                line = re.sub(r'=\s*"[^"]*"', f'= "{new_value}"', line)
        
        result_lines.append(line)
    
    return '\n'.join(result_lines)

@app.route('/api/secrets/generate', methods=['POST'])
def api_secrets_generate():
    """Generate random values for specified secrets"""
    data = request.get_json()
    secrets_to_generate = data.get('secrets', [])  # List of secret keys
    
    if not secrets_to_generate:
        # Generate all secrets
        secrets_to_generate = list(AEGIS_SECRETS.keys())
    
    generated = {}
    for secret_key in secrets_to_generate:
        if secret_key not in AEGIS_SECRETS:
            continue
        
        length = AEGIS_SECRETS[secret_key].get('generate_length', 32)
        # Generate random alphanumeric string
        import secrets as secrets_module
        generated[secret_key] = secrets_module.token_urlsafe(length)[:length]
    
    return jsonify({
        'success': True,
        'generated': generated
    })

@app.route('/api/config/structured', methods=['POST'])
def api_config_structured_save():
    """Save a config file from structured form data"""
    data = request.get_json()
    config_path = data.get('path')
    values = data.get('values', {})
    
    if not config_path:
        return jsonify({'error': 'Path is required'}), 400
    
    if config_path not in CONFIG_FIELD_SCHEMAS:
        return jsonify({'error': 'No schema for this config'}), 400
    
    schema = CONFIG_FIELD_SCHEMAS[config_path]
    aegis_root = str(AEGIS_ROOT)
    full_path = os.path.join(aegis_root, config_path)
    
    # Build config content based on format
    try:
        if schema['format'] == 'toml':
            content = generate_toml_content(schema, values)
        elif schema['format'] == 'json':
            content = json.dumps(values, indent=2)
        else:
            return jsonify({'error': 'Unsupported format'}), 400
        
        # Create directory if needed
        os.makedirs(os.path.dirname(full_path), exist_ok=True)
        
        # Write file with ownership preservation
        success, error_msg = safe_write_file(full_path, content)
        
        if not success:
            return jsonify({'error': f'Failed to write: {error_msg}'}), 500
        
        return jsonify({'success': True, 'path': config_path})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

def generate_toml_content(schema, values):
    """Generate TOML content from structured values"""
    lines = ['# Generated by Shellder Config Editor', '']
    
    for section_key, section_info in schema['sections'].items():
        section_values = values.get(section_key, {})
        if section_values:
            lines.append(f'[{section_key}]')
            for field_key, field_info in section_info['fields'].items():
                if field_key in section_values:
                    value = section_values[field_key]
                    if field_info['type'] in ('text', 'password'):
                        lines.append(f'{field_key} = "{value}"')
                    elif field_info['type'] == 'number':
                        lines.append(f'{field_key} = {value}')
                    elif field_info['type'] == 'checkbox':
                        lines.append(f'{field_key} = {"true" if value else "false"}')
            lines.append('')
    
    return '\n'.join(lines)

@app.route('/api/config/files')
def api_config_files():
    """Get list of all config files with their status"""
    aegis_root = str(AEGIS_ROOT)  # Use properly resolved global path
    
    files = []
    for config_path, config_info in REQUIRED_CONFIGS.items():
        full_path = os.path.join(aegis_root, config_path)
        files.append({
            'path': config_path,
            'full_path': full_path,
            'name': config_info['name'],
            'description': config_info['description'],
            'category': config_info['category'],
            'critical': config_info['critical'],
            'exists': os.path.exists(full_path),
            'template': config_info['template']
        })
    
    return jsonify({'files': files})

@app.route('/api/config/file', methods=['GET'])
def api_config_file_read():
    """Read a config file"""
    path = request.args.get('path')
    if not path:
        return jsonify({'error': 'Path is required'}), 400
    
    aegis_root = str(AEGIS_ROOT)  # Use properly resolved global path
    
    # Security: ensure path is within aegis root
    full_path = os.path.normpath(os.path.join(aegis_root, path))
    if not full_path.startswith(aegis_root):
        return jsonify({'error': 'Invalid path'}), 403
    
    if not os.path.exists(full_path):
        # Check for template
        config_info = REQUIRED_CONFIGS.get(path, {})
        if config_info.get('template'):
            template_path = os.path.join(aegis_root, config_info['template'])
            if os.path.exists(template_path):
                try:
                    with open(template_path, 'r') as f:
                        return jsonify({
                            'content': f.read(),
                            'is_template': True,
                            'template_path': config_info['template']
                        })
                except Exception as e:
                    return jsonify({'error': str(e)}), 500
        return jsonify({'error': 'File not found'}), 404
    
    try:
        with open(full_path, 'r') as f:
            content = f.read()
        return jsonify({
            'content': content,
            'path': path,
            'size': len(content),
            'modified': datetime.fromtimestamp(os.path.getmtime(full_path)).isoformat()
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/config/file', methods=['POST'])
def api_config_file_write():
    """Write a config file"""
    data = request.get_json()
    path = data.get('path')
    content = data.get('content')
    
    if not path or content is None:
        return jsonify({'error': 'Path and content are required'}), 400
    
    aegis_root = str(AEGIS_ROOT)  # Use properly resolved global path
    
    # Security: ensure path is within aegis root
    full_path = os.path.normpath(os.path.join(aegis_root, path))
    if not full_path.startswith(aegis_root):
        return jsonify({'error': 'Invalid path'}), 403
    
    try:
        # Create directory if needed
        os.makedirs(os.path.dirname(full_path), exist_ok=True)
        
        # Write using safe_write_file to preserve ownership
        success, error_msg = safe_write_file(full_path, content)
        
        if not success:
            return jsonify({'error': f'Failed to write: {error_msg}'}), 500
        
        return jsonify({'success': True, 'path': path})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/config/env')
def api_config_env_read():
    """Read environment variables from .env file"""
    aegis_root = str(AEGIS_ROOT)  # Use properly resolved global path
    env_file = os.path.join(aegis_root, '.env')
    
    variables = {}
    raw_content = ''
    
    if os.path.exists(env_file):
        try:
            with open(env_file, 'r') as f:
                raw_content = f.read()
                for line in raw_content.split('\n'):
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        key, value = line.split('=', 1)
                        key = key.strip()
                        value = value.strip()
                        
                        # Check if it's a required var
                        var_info = REQUIRED_ENV_VARS.get(key, {})
                        variables[key] = {
                            'value': value,  # Send actual value - frontend will mask with password field
                            'is_secret': var_info.get('secret', False),
                            'description': var_info.get('description', 'Custom variable'),
                            'category': var_info.get('category', 'custom')
                        }
        except Exception as e:
            return jsonify({'error': str(e)}), 500
    
    # Add missing required vars
    for var_name, var_info in REQUIRED_ENV_VARS.items():
        if var_name not in variables:
            variables[var_name] = {
                'value': '',
                'is_secret': var_info.get('secret', False),
                'description': var_info['description'],
                'category': var_info['category'],
                'missing': True
            }
    
    return jsonify({
        'variables': variables,
        'exists': os.path.exists(env_file),
        'required': list(REQUIRED_ENV_VARS.keys())
    })

@app.route('/api/config/env', methods=['POST'])
def api_config_env_write():
    """Update environment variables in .env file"""
    data = request.get_json()
    updates = data.get('variables', {})
    
    if not updates:
        return jsonify({'error': 'No variables to update'}), 400
    
    aegis_root = str(AEGIS_ROOT)  # Use properly resolved global path
    env_file = os.path.join(aegis_root, '.env')
    
    try:
        # Read existing content
        existing = {}
        lines = []
        if os.path.exists(env_file):
            with open(env_file, 'r') as f:
                for line in f:
                    original_line = line
                    line = line.strip()
                    if line and not line.startswith('#') and '=' in line:
                        key = line.split('=', 1)[0].strip()
                        existing[key] = len(lines)
                    lines.append(original_line)
        
        # Update values
        for key, value in updates.items():
            if value == '***':  # Skip masked values
                continue
            if key in existing:
                # Update existing line
                lines[existing[key]] = f'{key}={value}\n'
            else:
                # Add new line
                lines.append(f'{key}={value}\n')
        
        # Write back with ownership preservation
        content = ''.join(lines)
        success, error_msg = safe_write_file(env_file, content)
        
        if not success:
            return jsonify({'error': f'Failed to write: {error_msg}'}), 500
        
        return jsonify({'success': True, 'updated': list(updates.keys())})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/config/create-from-template', methods=['POST'])
def api_config_create_from_template():
    """Create a config file from its template"""
    data = request.get_json()
    path = data.get('path')
    
    if not path:
        return jsonify({'error': 'Path is required'}), 400
    
    config_info = REQUIRED_CONFIGS.get(path)
    if not config_info or not config_info.get('template'):
        return jsonify({'error': 'No template available for this config'}), 404
    
    aegis_root = str(AEGIS_ROOT)  # Use properly resolved global path
    template_path = os.path.join(aegis_root, config_info['template'])
    target_path = os.path.join(aegis_root, path)
    
    if not os.path.exists(template_path):
        return jsonify({'error': 'Template file not found'}), 404
    
    try:
        # Read template
        with open(template_path, 'r') as f:
            content = f.read()
        
        # Create directory if needed
        os.makedirs(os.path.dirname(target_path), exist_ok=True)
        
        # Copy template
        result = subprocess.run(
            ['sudo', 'cp', template_path, target_path],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode != 0:
            return jsonify({'error': f'Failed to copy: {result.stderr}'}), 500
        
        return jsonify({'success': True, 'path': path})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# =============================================================================
# GITHUB MANAGER API
# =============================================================================

@app.route('/api/github/status')
def api_github_status():
    """Get git repository status"""
    aegis_root = str(AEGIS_ROOT)  # Use properly resolved global path
    
    status = {
        'is_repo': False,
        'branch': None,
        'commit': None,
        'commit_short': None,
        'commit_message': None,
        'commit_date': None,
        'remote_url': None,
        'has_changes': False,
        'behind': 0,
        'ahead': 0
    }
    
    try:
        # Check if it's a git repo
        result = subprocess.run(
            ['git', 'rev-parse', '--git-dir'],
            capture_output=True, text=True, timeout=5, cwd=aegis_root
        )
        if result.returncode != 0:
            return jsonify(status)
        
        status['is_repo'] = True
        
        # Get current branch
        result = subprocess.run(
            ['git', 'branch', '--show-current'],
            capture_output=True, text=True, timeout=5, cwd=aegis_root
        )
        status['branch'] = result.stdout.strip() if result.returncode == 0 else None
        
        # Get current commit
        result = subprocess.run(
            ['git', 'rev-parse', 'HEAD'],
            capture_output=True, text=True, timeout=5, cwd=aegis_root
        )
        status['commit'] = result.stdout.strip() if result.returncode == 0 else None
        status['commit_short'] = status['commit'][:7] if status['commit'] else None
        
        # Get commit message
        result = subprocess.run(
            ['git', 'log', '-1', '--format=%s'],
            capture_output=True, text=True, timeout=5, cwd=aegis_root
        )
        status['commit_message'] = result.stdout.strip() if result.returncode == 0 else None
        
        # Get commit date
        result = subprocess.run(
            ['git', 'log', '-1', '--format=%ci'],
            capture_output=True, text=True, timeout=5, cwd=aegis_root
        )
        status['commit_date'] = result.stdout.strip() if result.returncode == 0 else None
        
        # Get remote URL
        result = subprocess.run(
            ['git', 'remote', 'get-url', 'origin'],
            capture_output=True, text=True, timeout=5, cwd=aegis_root
        )
        status['remote_url'] = result.stdout.strip() if result.returncode == 0 else None
        
        # Check for local changes
        result = subprocess.run(
            ['git', 'status', '--porcelain'],
            capture_output=True, text=True, timeout=5, cwd=aegis_root
        )
        status['has_changes'] = bool(result.stdout.strip()) if result.returncode == 0 else False
        
        # Fetch remote to check for updates
        subprocess.run(['git', 'fetch', '--quiet'], capture_output=True, timeout=30, cwd=aegis_root)
        
        # Check ahead/behind
        result = subprocess.run(
            ['git', 'rev-list', '--count', '--left-right', f'{status["branch"]}...origin/{status["branch"]}'],
            capture_output=True, text=True, timeout=5, cwd=aegis_root
        )
        if result.returncode == 0 and result.stdout.strip():
            parts = result.stdout.strip().split()
            if len(parts) == 2:
                status['ahead'] = int(parts[0])
                status['behind'] = int(parts[1])
        
    except Exception as e:
        status['error'] = str(e)
    
    return jsonify(status)

@app.route('/api/github/pull', methods=['POST'])
def api_github_pull():
    """Pull latest changes from remote"""
    aegis_root = str(AEGIS_ROOT)  # Use properly resolved global path
    
    try:
        # Stash any local changes first
        stash_result = subprocess.run(
            ['git', 'stash', '--include-untracked'],
            capture_output=True, text=True, timeout=30, cwd=aegis_root
        )
        stashed = 'Saved working directory' in stash_result.stdout
        
        # Pull changes
        result = subprocess.run(
            ['git', 'pull', '--ff-only'],
            capture_output=True, text=True, timeout=60, cwd=aegis_root
        )
        
        # Restore stashed changes
        if stashed:
            subprocess.run(['git', 'stash', 'pop'], capture_output=True, timeout=30, cwd=aegis_root)
        
        if result.returncode == 0:
            return jsonify({
                'success': True,
                'output': result.stdout,
                'stashed': stashed
            })
        else:
            return jsonify({
                'success': False,
                'error': result.stderr or result.stdout,
                'stashed': stashed
            })
            
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/github/pull-restart', methods=['POST'])
def api_github_pull_restart():
    """Pull latest changes and restart Shellder service"""
    aegis_root = str(AEGIS_ROOT)  # Use properly resolved global path
    
    steps = []
    
    try:
        # Step 1: Stash changes
        stash_result = subprocess.run(
            ['git', 'stash', '--include-untracked'],
            capture_output=True, text=True, timeout=30, cwd=aegis_root
        )
        stashed = 'Saved working directory' in stash_result.stdout
        steps.append({'step': 'stash', 'success': True, 'stashed': stashed})
        
        # Step 2: Pull changes
        pull_result = subprocess.run(
            ['git', 'pull', '--ff-only'],
            capture_output=True, text=True, timeout=60, cwd=aegis_root
        )
        steps.append({
            'step': 'pull',
            'success': pull_result.returncode == 0,
            'output': pull_result.stdout or pull_result.stderr
        })
        
        if pull_result.returncode != 0:
            # Restore stash if pull failed
            if stashed:
                subprocess.run(['git', 'stash', 'pop'], capture_output=True, timeout=30, cwd=aegis_root)
            return jsonify({'success': False, 'steps': steps, 'error': 'Pull failed'})
        
        # Step 3: Restore stash
        if stashed:
            pop_result = subprocess.run(
                ['git', 'stash', 'pop'],
                capture_output=True, text=True, timeout=30, cwd=aegis_root
            )
            steps.append({'step': 'restore', 'success': pop_result.returncode == 0})
        
        # Step 4: Restart Shellder container
        restart_result = subprocess.run(
            ['docker', 'compose', 'restart', 'shellder'],
            capture_output=True, text=True, timeout=60, cwd=aegis_root
        )
        steps.append({
            'step': 'restart',
            'success': restart_result.returncode == 0,
            'output': restart_result.stdout or restart_result.stderr
        })
        
        return jsonify({
            'success': all(s.get('success', True) for s in steps),
            'steps': steps,
            'message': 'Pull and restart complete. Page will reload shortly.'
        })
        
    except Exception as e:
        return jsonify({'success': False, 'steps': steps, 'error': str(e)})

@app.route('/api/github/changes')
def api_github_changes():
    """Get list of changed files"""
    aegis_root = str(AEGIS_ROOT)  # Use properly resolved global path
    
    try:
        result = subprocess.run(
            ['git', 'status', '--porcelain'],
            capture_output=True, text=True, timeout=10, cwd=aegis_root
        )
        
        if result.returncode != 0:
            return jsonify({'error': result.stderr}), 500
        
        changes = []
        for line in result.stdout.strip().split('\n'):
            if line:
                status = line[:2]
                file_path = line[3:]
                changes.append({
                    'status': status.strip(),
                    'path': file_path,
                    'type': 'modified' if 'M' in status else 'added' if 'A' in status else 'deleted' if 'D' in status else 'untracked' if '?' in status else 'other'
                })
        
        return jsonify({'changes': changes, 'count': len(changes)})
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/github/commits')
def api_github_commits():
    """Get recent commits"""
    aegis_root = str(AEGIS_ROOT)  # Use properly resolved global path
    limit = request.args.get('limit', 10, type=int)
    
    try:
        result = subprocess.run(
            ['git', 'log', f'-{limit}', '--format=%H|%h|%s|%an|%ci'],
            capture_output=True, text=True, timeout=10, cwd=aegis_root
        )
        
        if result.returncode != 0:
            return jsonify({'error': result.stderr}), 500
        
        commits = []
        for line in result.stdout.strip().split('\n'):
            if line:
                parts = line.split('|')
                if len(parts) >= 5:
                    commits.append({
                        'hash': parts[0],
                        'short_hash': parts[1],
                        'message': parts[2],
                        'author': parts[3],
                        'date': parts[4]
                    })
        
        return jsonify({'commits': commits})
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# =============================================================================
# SECURITY SERVICES API
# =============================================================================
# Controls for UFW, fail2ban, Authelia, and basic auth

@app.route('/api/security/status')
def api_security_status():
    """Get status of all security services"""
    services = {}
    
    # UFW (Firewall)
    try:
        result = subprocess.run(['sudo', 'ufw', 'status'], capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            output = result.stdout
            services['ufw'] = {
                'installed': True,
                'active': 'Status: active' in output,
                'status': 'active' if 'Status: active' in output else 'inactive',
                'output': output
            }
        else:
            services['ufw'] = {'installed': False, 'error': result.stderr}
    except FileNotFoundError:
        services['ufw'] = {'installed': False, 'error': 'UFW not installed'}
    except Exception as e:
        services['ufw'] = {'installed': False, 'error': str(e)}
    
    # fail2ban
    try:
        result = subprocess.run(['sudo', 'systemctl', 'is-active', 'fail2ban'], capture_output=True, text=True, timeout=5)
        is_active = result.stdout.strip() == 'active'
        
        # Get banned IPs count
        banned_count = 0
        if is_active:
            try:
                ban_result = subprocess.run(['sudo', 'fail2ban-client', 'status'], capture_output=True, text=True, timeout=5)
                # Parse jails
                jails = []
                if 'Jail list:' in ban_result.stdout:
                    jail_line = ban_result.stdout.split('Jail list:')[1].strip().split('\n')[0]
                    jails = [j.strip() for j in jail_line.split(',') if j.strip()]
                
                # Count banned IPs per jail
                for jail in jails:
                    jail_result = subprocess.run(['sudo', 'fail2ban-client', 'status', jail], capture_output=True, text=True, timeout=5)
                    if 'Currently banned:' in jail_result.stdout:
                        count = int(jail_result.stdout.split('Currently banned:')[1].split('\n')[0].strip())
                        banned_count += count
            except:
                pass
        
        services['fail2ban'] = {
            'installed': True,
            'active': is_active,
            'status': 'active' if is_active else 'inactive',
            'banned_count': banned_count
        }
    except FileNotFoundError:
        services['fail2ban'] = {'installed': False, 'error': 'fail2ban not installed'}
    except Exception as e:
        services['fail2ban'] = {'installed': False, 'error': str(e)}
    
    # Authelia (Docker container)
    try:
        result = subprocess.run(['docker', 'inspect', '--format', '{{.State.Status}}', 'authelia'], 
                              capture_output=True, text=True, timeout=5)
        status = result.stdout.strip()
        services['authelia'] = {
            'installed': True,
            'active': status == 'running',
            'status': status if status else 'not found',
            'type': 'docker'
        }
    except Exception as e:
        services['authelia'] = {'installed': False, 'error': str(e), 'type': 'docker'}
    
    # Basic Auth (htpasswd file)
    htpasswd_paths = ['/etc/nginx/.htpasswd', '/etc/apache2/.htpasswd', '/etc/htpasswd']
    htpasswd_found = None
    htpasswd_users = []
    for path in htpasswd_paths:
        if os.path.exists(path):
            htpasswd_found = path
            try:
                with open(path, 'r') as f:
                    for line in f:
                        if ':' in line:
                            htpasswd_users.append(line.split(':')[0])
            except:
                pass
            break
    
    services['basic_auth'] = {
        'installed': htpasswd_found is not None,
        'active': htpasswd_found is not None and len(htpasswd_users) > 0,
        'path': htpasswd_found,
        'users': htpasswd_users,
        'user_count': len(htpasswd_users)
    }
    
    # SSL Certificates (certbot)
    try:
        result = subprocess.run(['sudo', 'certbot', 'certificates'], capture_output=True, text=True, timeout=10)
        certs = []
        if result.returncode == 0:
            # Parse certificate info
            cert_blocks = result.stdout.split('Certificate Name:')[1:] if 'Certificate Name:' in result.stdout else []
            for block in cert_blocks:
                lines = block.strip().split('\n')
                cert_name = lines[0].strip()
                domains = []
                expiry = None
                for line in lines:
                    if 'Domains:' in line:
                        domains = [d.strip() for d in line.split('Domains:')[1].split()]
                    if 'Expiry Date:' in line:
                        expiry = line.split('Expiry Date:')[1].strip().split(' ')[0]
                certs.append({'name': cert_name, 'domains': domains, 'expiry': expiry})
        
        services['ssl'] = {
            'installed': True,
            'certificates': certs,
            'count': len(certs)
        }
    except Exception as e:
        services['ssl'] = {'installed': False, 'error': str(e)}
    
    return jsonify(services)

@app.route('/api/security/ufw/status')
def api_ufw_status():
    """Get detailed UFW status with rules"""
    try:
        result = subprocess.run(['sudo', 'ufw', 'status', 'verbose'], capture_output=True, text=True, timeout=5)
        
        rules = []
        lines = result.stdout.split('\n')
        in_rules = False
        for line in lines:
            if line.startswith('--'):
                in_rules = True
                continue
            if in_rules and line.strip():
                parts = line.split()
                if len(parts) >= 3:
                    rules.append({
                        'to': parts[0],
                        'action': parts[1],
                        'from': parts[2] if len(parts) > 2 else 'Anywhere'
                    })
        
        return jsonify({
            'active': 'Status: active' in result.stdout,
            'output': result.stdout,
            'rules': rules
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/security/ufw/<action>', methods=['POST'])
def api_ufw_action(action):
    """Control UFW firewall"""
    valid_actions = ['enable', 'disable', 'reload']
    if action not in valid_actions:
        return jsonify({'error': f'Invalid action. Use: {valid_actions}'}), 400
    
    try:
        if action == 'enable':
            cmd = ['sudo', 'ufw', '--force', 'enable']
        elif action == 'disable':
            cmd = ['sudo', 'ufw', 'disable']
        else:
            cmd = ['sudo', 'ufw', 'reload']
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/security/ufw/rule', methods=['POST'])
def api_ufw_add_rule():
    """Add UFW rule"""
    data = request.get_json()
    rule_type = data.get('type', 'allow')  # allow, deny
    port = data.get('port')
    protocol = data.get('protocol', 'tcp')  # tcp, udp, or empty for both
    from_ip = data.get('from')
    
    if not port:
        return jsonify({'error': 'Port is required'}), 400
    
    try:
        cmd = ['sudo', 'ufw']
        if from_ip:
            cmd.extend([rule_type, 'from', from_ip, 'to', 'any', 'port', str(port)])
        else:
            cmd.extend([rule_type, f'{port}/{protocol}' if protocol else str(port)])
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/security/ufw/rule', methods=['DELETE'])
def api_ufw_delete_rule():
    """Delete UFW rule"""
    data = request.get_json()
    rule_number = data.get('number')
    
    if not rule_number:
        return jsonify({'error': 'Rule number is required'}), 400
    
    try:
        result = subprocess.run(
            ['sudo', 'ufw', '--force', 'delete', str(rule_number)],
            capture_output=True, text=True, timeout=10
        )
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/security/fail2ban/status')
def api_fail2ban_status():
    """Get detailed fail2ban status"""
    try:
        # Check if running
        active_result = subprocess.run(['sudo', 'systemctl', 'is-active', 'fail2ban'], 
                                       capture_output=True, text=True, timeout=5)
        is_active = active_result.stdout.strip() == 'active'
        
        if not is_active:
            return jsonify({'active': False, 'jails': []})
        
        # Get jail list
        result = subprocess.run(['sudo', 'fail2ban-client', 'status'], 
                              capture_output=True, text=True, timeout=5)
        
        jails = []
        if 'Jail list:' in result.stdout:
            jail_line = result.stdout.split('Jail list:')[1].strip().split('\n')[0]
            jail_names = [j.strip() for j in jail_line.split(',') if j.strip()]
            
            # Get details for each jail
            for jail in jail_names:
                try:
                    jail_result = subprocess.run(
                        ['sudo', 'fail2ban-client', 'status', jail],
                        capture_output=True, text=True, timeout=5
                    )
                    
                    currently_banned = 0
                    total_banned = 0
                    banned_ips = []
                    
                    output = jail_result.stdout
                    if 'Currently banned:' in output:
                        currently_banned = int(output.split('Currently banned:')[1].split('\n')[0].strip())
                    if 'Total banned:' in output:
                        total_banned = int(output.split('Total banned:')[1].split('\n')[0].strip())
                    if 'Banned IP list:' in output:
                        ip_line = output.split('Banned IP list:')[1].strip().split('\n')[0]
                        banned_ips = [ip.strip() for ip in ip_line.split() if ip.strip()]
                    
                    jails.append({
                        'name': jail,
                        'currently_banned': currently_banned,
                        'total_banned': total_banned,
                        'banned_ips': banned_ips
                    })
                except:
                    jails.append({'name': jail, 'error': 'Could not get status'})
        
        return jsonify({
            'active': True,
            'jails': jails,
            'total_banned': sum(j.get('currently_banned', 0) for j in jails)
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/security/fail2ban/<action>', methods=['POST'])
def api_fail2ban_action(action):
    """Control fail2ban service"""
    valid_actions = ['start', 'stop', 'restart', 'reload']
    if action not in valid_actions:
        return jsonify({'error': f'Invalid action. Use: {valid_actions}'}), 400
    
    try:
        result = subprocess.run(
            ['sudo', 'systemctl', action, 'fail2ban'],
            capture_output=True, text=True, timeout=30
        )
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/security/fail2ban/unban', methods=['POST'])
def api_fail2ban_unban():
    """Unban an IP from fail2ban"""
    data = request.get_json()
    ip = data.get('ip')
    jail = data.get('jail', 'sshd')
    
    if not ip:
        return jsonify({'error': 'IP address is required'}), 400
    
    try:
        result = subprocess.run(
            ['sudo', 'fail2ban-client', 'set', jail, 'unbanip', ip],
            capture_output=True, text=True, timeout=10
        )
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/security/authelia/status')
def api_authelia_status():
    """Get Authelia container status and config info"""
    try:
        # Check container status
        result = subprocess.run(
            ['docker', 'inspect', 'authelia'],
            capture_output=True, text=True, timeout=10
        )
        
        if result.returncode != 0:
            return jsonify({'installed': False, 'error': 'Authelia container not found'})
        
        import json as json_lib
        container_info = json_lib.loads(result.stdout)[0]
        
        state = container_info.get('State', {})
        config = container_info.get('Config', {})
        
        # Check for config file
        config_paths = [
            '/aegis/Authelia/configuration.yml',
            '/app/config/configuration.yml',
            './Authelia/configuration.yml'
        ]
        config_found = None
        for path in config_paths:
            if os.path.exists(path):
                config_found = path
                break
        
        return jsonify({
            'installed': True,
            'status': state.get('Status', 'unknown'),
            'running': state.get('Running', False),
            'started_at': state.get('StartedAt'),
            'health': state.get('Health', {}).get('Status', 'unknown'),
            'image': config.get('Image', 'unknown'),
            'config_path': config_found,
            'ports': container_info.get('NetworkSettings', {}).get('Ports', {})
        })
    except Exception as e:
        return jsonify({'installed': False, 'error': str(e)})

@app.route('/api/security/authelia/<action>', methods=['POST'])
def api_authelia_action(action):
    """Control Authelia container"""
    valid_actions = ['start', 'stop', 'restart']
    if action not in valid_actions:
        return jsonify({'error': f'Invalid action. Use: {valid_actions}'}), 400
    
    try:
        if action == 'start':
            result = subprocess.run(['docker', 'start', 'authelia'], capture_output=True, text=True, timeout=30)
        elif action == 'stop':
            result = subprocess.run(['docker', 'stop', 'authelia'], capture_output=True, text=True, timeout=30)
        else:
            result = subprocess.run(['docker', 'restart', 'authelia'], capture_output=True, text=True, timeout=60)
        
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/security/basicauth/users')
def api_basicauth_users():
    """Get list of basic auth users"""
    htpasswd_paths = ['/etc/nginx/.htpasswd', '/etc/apache2/.htpasswd', '/etc/htpasswd']
    
    for path in htpasswd_paths:
        if os.path.exists(path):
            try:
                users = []
                with open(path, 'r') as f:
                    for line in f:
                        if ':' in line:
                            users.append(line.split(':')[0])
                return jsonify({
                    'path': path,
                    'users': users,
                    'count': len(users)
                })
            except Exception as e:
                return jsonify({'error': str(e)}), 500
    
    return jsonify({'path': None, 'users': [], 'count': 0})

@app.route('/api/security/basicauth/user', methods=['POST'])
def api_basicauth_add_user():
    """Add or update basic auth user"""
    data = request.get_json()
    username = data.get('username')
    password = data.get('password')
    
    if not username or not password:
        return jsonify({'error': 'Username and password are required'}), 400
    
    htpasswd_path = '/etc/nginx/.htpasswd'
    
    try:
        # Check if htpasswd command exists
        if os.path.exists(htpasswd_path):
            # Update/add user
            result = subprocess.run(
                ['sudo', 'htpasswd', '-b', htpasswd_path, username, password],
                capture_output=True, text=True, timeout=10
            )
        else:
            # Create new file
            result = subprocess.run(
                ['sudo', 'htpasswd', '-bc', htpasswd_path, username, password],
                capture_output=True, text=True, timeout=10
            )
        
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/security/basicauth/user/<username>', methods=['DELETE'])
def api_basicauth_delete_user(username):
    """Delete basic auth user"""
    htpasswd_path = '/etc/nginx/.htpasswd'
    
    if not os.path.exists(htpasswd_path):
        return jsonify({'error': 'htpasswd file not found'}), 404
    
    try:
        result = subprocess.run(
            ['sudo', 'htpasswd', '-D', htpasswd_path, username],
            capture_output=True, text=True, timeout=10
        )
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/security/ssl/certificates')
def api_ssl_certificates():
    """Get SSL certificate information"""
    try:
        result = subprocess.run(
            ['sudo', 'certbot', 'certificates'],
            capture_output=True, text=True, timeout=30
        )
        
        certificates = []
        if 'Certificate Name:' in result.stdout:
            cert_blocks = result.stdout.split('Certificate Name:')[1:]
            for block in cert_blocks:
                lines = block.strip().split('\n')
                cert = {'name': lines[0].strip()}
                for line in lines[1:]:
                    if 'Domains:' in line:
                        cert['domains'] = [d.strip() for d in line.split('Domains:')[1].split()]
                    elif 'Expiry Date:' in line:
                        cert['expiry'] = line.split('Expiry Date:')[1].strip()
                    elif 'Certificate Path:' in line:
                        cert['cert_path'] = line.split('Certificate Path:')[1].strip()
                    elif 'Private Key Path:' in line:
                        cert['key_path'] = line.split('Private Key Path:')[1].strip()
                certificates.append(cert)
        
        return jsonify({
            'certificates': certificates,
            'count': len(certificates)
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/security/ssl/renew', methods=['POST'])
def api_ssl_renew():
    """Renew SSL certificates"""
    data = request.get_json() or {}
    domain = data.get('domain')  # Optional: renew specific domain
    
    try:
        if domain:
            cmd = ['sudo', 'certbot', 'renew', '--cert-name', domain, '--force-renewal']
        else:
            cmd = ['sudo', 'certbot', 'renew']
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# =============================================================================
# SITE AVAILABILITY CHECK - 3-LEVEL COMPREHENSIVE CHECK
# =============================================================================

# Known service configurations (name -> port mappings)
KNOWN_SERVICES = {
    'reactmap': {'port': 6001, 'name': 'ReactMap', 'container': 'reactmap'},
    'koji': {'port': 6002, 'name': 'Koji', 'container': 'koji'},
    'dragonite': {'port': 7272, 'name': 'Dragonite', 'container': 'dragonite'},
    'rotom': {'port': 7070, 'name': 'Rotom', 'container': 'rotom'},
    'golbat': {'port': 9001, 'name': 'Golbat', 'container': 'golbat'},
    'shellder': {'port': 5000, 'name': 'Shellder', 'container': 'shellder'},
    'grafana': {'port': 3000, 'name': 'Grafana', 'container': 'grafana'},
    'poracle': {'port': 4201, 'name': 'Poracle', 'container': 'poracle'},
    'authelia': {'port': 9091, 'name': 'Authelia', 'container': 'authelia'},
}

def _parse_nginx_config(config_path):
    """Parse nginx config to extract server_name and proxy_pass port"""
    result = {
        'server_names': [],
        'proxy_port': None,
        'ssl': False,
        'listen_port': 80
    }
    
    try:
        with open(config_path, 'r') as f:
            content = f.read()
        
        # Extract server_name
        server_name_match = re.search(r'server_name\s+([^;]+);', content)
        if server_name_match:
            names = server_name_match.group(1).strip().split()
            result['server_names'] = [n for n in names if n != '_']
        
        # Extract proxy_pass port
        proxy_match = re.search(r'proxy_pass\s+https?://[^:]+:(\d+)', content)
        if proxy_match:
            result['proxy_port'] = int(proxy_match.group(1))
        else:
            # Try localhost format
            proxy_match = re.search(r'proxy_pass\s+https?://localhost:(\d+)', content)
            if proxy_match:
                result['proxy_port'] = int(proxy_match.group(1))
            else:
                # Try 127.0.0.1 format
                proxy_match = re.search(r'proxy_pass\s+https?://127\.0\.0\.1:(\d+)', content)
                if proxy_match:
                    result['proxy_port'] = int(proxy_match.group(1))
        
        # Check for SSL
        result['ssl'] = 'ssl_certificate' in content or 'listen 443' in content
        
        # Check listen port
        listen_match = re.search(r'listen\s+(\d+)', content)
        if listen_match:
            result['listen_port'] = int(listen_match.group(1))
            
    except Exception as e:
        debug('SITES', f'Failed to parse nginx config {config_path}: {e}')
    
    return result

def _check_port_open(port, host='127.0.0.1', timeout=1):
    """Check if a port is open (service is listening)"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        result = sock.connect_ex((host, port))
        sock.close()
        return result == 0
    except Exception:
        return False

def _check_url_accessible(url, timeout=2):
    """Check if a URL is accessible via HTTP(S)"""
    import urllib.request
    import urllib.error
    import ssl
    
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    
    try:
        req = urllib.request.Request(url, method='HEAD')
        req.add_header('User-Agent', 'Shellder-Health-Check/1.0')
        response = urllib.request.urlopen(req, timeout=timeout, context=ctx)
        return {
            'accessible': True,
            'status': response.getcode(),
            'error': None
        }
    except urllib.error.HTTPError as e:
        # HTTP errors mean the server responded (even if with an error)
        return {
            'accessible': e.code < 500,  # 4xx is still "accessible"
            'status': e.code,
            'error': str(e.reason)
        }
    except urllib.error.URLError as e:
        return {
            'accessible': False,
            'status': 0,
            'error': 'Connection refused' if 'refused' in str(e) else str(e.reason)
        }
    except Exception as e:
        return {
            'accessible': False,
            'status': 0,
            'error': str(e)
        }

@app.route('/api/sites/check')
def api_sites_check():
    """
    Comprehensive 3-level site availability check:
    1. Nginx Enabled - Is the site configuration enabled?
    2. Port Available - Is the backend service listening?
    3. Domain Accessible - Can we reach it via domain/subdomain?
    """
    from concurrent.futures import ThreadPoolExecutor, as_completed
    
    info('SITES', 'Comprehensive site availability check started')
    start_time = time.time()
    
    sites = []
    
    # Gather all sites from nginx sites-enabled
    sites_enabled = Path('/etc/nginx/sites-enabled')
    sites_available = Path('/etc/nginx/sites-available')
    
    # Track which sites are enabled vs available
    enabled_sites = set()
    if sites_enabled.exists():
        for site in sites_enabled.iterdir():
            if site.name != 'default' and not site.name.startswith('.'):
                enabled_sites.add(site.name)
    
    available_sites = set()
    if sites_available.exists():
        for site in sites_available.iterdir():
            if site.name != 'default' and not site.name.startswith('.'):
                available_sites.add(site.name)
    
    # Process enabled sites (primary focus)
    for site_name in enabled_sites:
        config_path = sites_enabled / site_name
        if config_path.is_symlink():
            config_path = config_path.resolve()
        
        config = _parse_nginx_config(config_path)
        
        # Determine service name from filename or server_name
        service_name = site_name.split('.')[0].lower()  # e.g., "reactmap.example.com" -> "reactmap"
        known_service = KNOWN_SERVICES.get(service_name, {})
        
        # Use parsed port or known service port
        backend_port = config['proxy_port'] or known_service.get('port')
        
        # Get the primary domain
        primary_domain = config['server_names'][0] if config['server_names'] else site_name
        
        sites.append({
            'name': site_name,
            'display_name': known_service.get('name', site_name.split('.')[0].title()),
            'domain': primary_domain,
            'domains': config['server_names'],
            'backend_port': backend_port,
            'ssl': config['ssl'],
            'nginx_enabled': True,
            'container': known_service.get('container'),
        })
    
    # Add known services that aren't nginx-configured (for port check only)
    for service_key, service_info in KNOWN_SERVICES.items():
        # Check if this service already has a site entry
        has_site = any(
            s.get('backend_port') == service_info['port'] or 
            service_key in s.get('name', '').lower()
            for s in sites
        )
        
        if not has_site:
            sites.append({
                'name': service_info['name'],
                'display_name': service_info['name'],
                'domain': None,
                'domains': [],
                'backend_port': service_info['port'],
                'ssl': False,
                'nginx_enabled': False,
                'container': service_info['container'],
            })
    
    # Parallel checks for all sites
    def check_site(site):
        result = {
            'name': site['name'],
            'display_name': site['display_name'],
            'checks': {
                'nginx_enabled': site['nginx_enabled'],
                'port_available': False,
                'domain_accessible': None,  # None = not applicable
            },
            'details': {
                'domain': site['domain'],
                'domains': site.get('domains', []),
                'backend_port': site['backend_port'],
                'ssl': site['ssl'],
                'container': site['container'],
            },
            'status': 'unknown',
            'status_code': 0,
            'error': None,
        }
        
        # Check 2: Port Available (backend service listening)
        if site['backend_port']:
            result['checks']['port_available'] = _check_port_open(site['backend_port'])
        
        # Check 3: Domain Accessible (only if nginx is enabled and we have a domain)
        if site['nginx_enabled'] and site['domain']:
            protocol = 'https' if site['ssl'] else 'http'
            url = f"{protocol}://{site['domain']}"
            
            url_check = _check_url_accessible(url)
            result['checks']['domain_accessible'] = url_check['accessible']
            result['status_code'] = url_check['status']
            if url_check['error']:
                result['error'] = url_check['error']
        
        # Determine overall status
        nginx_ok = result['checks']['nginx_enabled']
        port_ok = result['checks']['port_available']
        domain_ok = result['checks']['domain_accessible']
        
        if nginx_ok and port_ok and domain_ok:
            result['status'] = 'healthy'
        elif port_ok and (domain_ok is None or domain_ok):
            result['status'] = 'running'  # Service running but maybe no nginx
        elif nginx_ok and not port_ok:
            result['status'] = 'backend_down'
        elif nginx_ok and port_ok and domain_ok is False:
            result['status'] = 'unreachable'
        elif not port_ok:
            result['status'] = 'offline'
        else:
            result['status'] = 'partial'
        
        return result
    
    results = []
    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = {executor.submit(check_site, site): site for site in sites}
        for future in as_completed(futures, timeout=10):
            try:
                result = future.result(timeout=3)
                results.append(result)
            except Exception as e:
                site = futures[future]
                results.append({
                    'name': site['name'],
                    'display_name': site['display_name'],
                    'checks': {
                        'nginx_enabled': site['nginx_enabled'],
                        'port_available': False,
                        'domain_accessible': None,
                    },
                    'details': {
                        'domain': site.get('domain'),
                        'backend_port': site.get('backend_port'),
                    },
                    'status': 'error',
                    'error': str(e),
                })
    
    # Sort: healthy first, then by name
    status_order = {'healthy': 0, 'running': 1, 'partial': 2, 'backend_down': 3, 'unreachable': 4, 'offline': 5, 'error': 6}
    results.sort(key=lambda x: (status_order.get(x['status'], 99), x['name']))
    
    # Calculate summary
    healthy = sum(1 for r in results if r['status'] == 'healthy')
    running = sum(1 for r in results if r['status'] in ('healthy', 'running'))
    total = len(results)
    
    duration = (time.time() - start_time) * 1000
    info('SITES', f'Site check completed in {duration:.0f}ms', {
        'healthy': healthy,
        'running': running,
        'total': total
    })
    
    return jsonify({
        'sites': results,
        'summary': {
            'healthy': healthy,
            'running': running,
            'total': total,
            'text': f'{healthy}/{total} fully healthy, {running}/{total} running'
        },
        'check_time_ms': round(duration),
        'timestamp': datetime.now().isoformat()
    })

# =============================================================================
# ROTOM ENDPOINTS
# =============================================================================

@app.route('/api/rotom/stats')
def api_rotom_stats():
    """Get Rotom device/worker statistics"""
    stats = stats_collector.get_all_stats()
    return jsonify(stats.get('rotom', {}))

@app.route('/api/rotom/devices')
def api_rotom_devices():
    """Get Rotom device list with status"""
    stats = stats_collector.get_all_stats()
    return jsonify(stats.get('rotom', {}).get('devices', {}))

@app.route('/api/rotom/live')
def api_rotom_live():
    """Stream Rotom logs in real-time"""
    return api_container_logs_stream('rotom')

# =============================================================================
# KOJI ENDPOINTS
# =============================================================================

@app.route('/api/koji/stats')
def api_koji_stats():
    """Get Koji API statistics"""
    stats = stats_collector.get_all_stats()
    return jsonify(stats.get('koji', {}))

@app.route('/api/koji/live')
def api_koji_live():
    """Stream Koji logs in real-time"""
    return api_container_logs_stream('koji')

# =============================================================================
# REACTMAP ENDPOINTS
# =============================================================================

@app.route('/api/reactmap/stats')
def api_reactmap_stats():
    """Get Reactmap build/status info"""
    stats = stats_collector.get_all_stats()
    return jsonify(stats.get('reactmap', {}))

@app.route('/api/reactmap/live')
def api_reactmap_live():
    """Stream Reactmap logs in real-time"""
    return api_container_logs_stream('reactmap')

# =============================================================================
# DATABASE ENDPOINTS
# =============================================================================

@app.route('/api/database/stats')
def api_database_stats():
    """Get MariaDB connection statistics"""
    stats = stats_collector.get_all_stats()
    return jsonify(stats.get('database', {}))

@app.route('/api/database/live')
def api_database_live():
    """Stream Database logs in real-time"""
    return api_container_logs_stream('database')

# =============================================================================
# HISTORICAL DATA ENDPOINTS (from SQLite)
# =============================================================================

@app.route('/api/db/proxy-stats')
def api_db_proxy_stats():
    """Get historical proxy statistics from SQLite"""
    limit = request.args.get('limit', 50, type=int)
    return jsonify(shellder_db.get_proxy_stats(limit))

@app.route('/api/db/error-stats')
def api_db_error_stats():
    """Get historical error statistics from SQLite"""
    service = request.args.get('service', None)
    limit = request.args.get('limit', 100, type=int)
    return jsonify(shellder_db.get_error_stats(service, limit))

@app.route('/api/db/container-stats')
def api_db_container_stats():
    """Get historical container statistics from SQLite"""
    return jsonify(shellder_db.get_container_stats())

@app.route('/api/db/log-summaries')
def api_db_log_summaries():
    """Get log summaries from SQLite"""
    days = request.args.get('days', 7, type=int)
    return jsonify(shellder_db.get_log_summaries(days))

@app.route('/api/db/discrepancies')
def api_db_discrepancies():
    """Get config discrepancies from SQLite"""
    return jsonify(shellder_db.get_config_discrepancies())

@app.route('/api/db/events')
def api_db_events():
    """Get system events from SQLite"""
    limit = request.args.get('limit', 50, type=int)
    return jsonify(shellder_db.get_system_events(limit))

# =============================================================================
# STACK DATABASE ENDPOINTS (Cross-reference with MariaDB)
# =============================================================================
# These endpoints query the actual Unown Stack databases (golbat, dragonite, 
# koji, reactmap) for live scanner data cross-referenced with logs

@app.route('/api/stack/test')
def api_stack_test():
    """Test MariaDB stack connection"""
    return jsonify(stack_db.test_connection())

@app.route('/api/stack/databases')
def api_stack_databases():
    """List available stack databases"""
    return jsonify(stack_db.get_available_databases())

@app.route('/api/stack/summary')
def api_stack_summary():
    """Get comprehensive stack summary (all databases)"""
    return jsonify(stack_db.get_full_stack_summary())

@app.route('/api/stack/golbat')
def api_stack_golbat():
    """Get Golbat database stats (Pokemon, Gyms, Stops)"""
    return jsonify(stack_db.get_golbat_stats())

@app.route('/api/stack/dragonite')
def api_stack_dragonite():
    """Get Dragonite database stats (Accounts, Devices, Instances)"""
    return jsonify(stack_db.get_dragonite_stats())

@app.route('/api/stack/koji')
def api_stack_koji():
    """Get Koji database stats (Geofences, Routes, Projects)"""
    return jsonify(stack_db.get_koji_stats())

@app.route('/api/stack/reactmap')
def api_stack_reactmap():
    """Get Reactmap database stats (Users, Sessions)"""
    return jsonify(stack_db.get_reactmap_stats())

@app.route('/api/stack/devices')
def api_stack_devices():
    """Get detailed device status from Dragonite DB"""
    return jsonify(stack_db.get_device_status())

@app.route('/api/stack/accounts')
def api_stack_accounts():
    """Get account health summary from Dragonite DB"""
    return jsonify(stack_db.get_account_health())

@app.route('/api/stack/pokemon')
def api_stack_pokemon():
    """Get Pokemon spawn summary from Golbat DB"""
    hours = request.args.get('hours', 24, type=int)
    return jsonify(stack_db.get_pokemon_summary(hours))

@app.route('/api/stack/efficiency')
def api_stack_efficiency():
    """Get scanner efficiency (cross-reference Dragonite + Golbat)"""
    return jsonify(stack_db.get_scanner_efficiency())

@app.route('/api/stack/health')
def api_stack_health():
    """Get comprehensive health dashboard from all databases"""
    return jsonify(stack_db.get_health_dashboard())

# =============================================================================
# DEVICE MANAGEMENT ENDPOINTS (Cross-reference Rotom/Dragonite logs & DB)
# =============================================================================

@app.route('/api/devices')
def api_devices():
    """Get all devices with cross-referenced stats from logs and database"""
    return jsonify(device_manager.get_all_devices())

@app.route('/api/devices/summary')
def api_devices_summary():
    """Get device summary statistics"""
    return jsonify(device_manager.get_device_summary())

@app.route('/api/devices/<device_name>')
def api_device_detail(device_name):
    """Get detailed info for a specific device"""
    devices = device_manager.get_all_devices()
    for dev in devices:
        if dev.get('uuid') == device_name:
            return jsonify(dev)
    return jsonify({'error': 'Device not found'}), 404

@app.route('/api/devices/<device_name>/crashes')
def api_device_crashes(device_name):
    """Get crash history for a specific device"""
    limit = request.args.get('limit', 50, type=int)
    return jsonify(device_manager.get_device_crash_history(device_name, limit))

@app.route('/api/devices/crashes')
def api_all_crashes():
    """Get all device crashes across all devices"""
    limit = request.args.get('limit', 100, type=int)
    return jsonify(device_manager.get_device_crash_history(None, limit))

@app.route('/api/devices/crashes/<int:crash_id>')
def api_crash_detail(crash_id):
    """Get details of a specific crash"""
    return jsonify(device_manager.get_crash_log_context(crash_id))

@app.route('/api/devices/crashes/<int:crash_id>/context')
def api_crash_context(crash_id):
    """Get log context for a crash with configurable line count"""
    context_lines = request.args.get('lines', 50, type=int)
    return jsonify(device_manager.get_crash_log_context(crash_id, context_lines))

@app.route('/api/devices/log-context/<container>/<int:line>')
def api_device_log_context(container, line):
    """Get log context around a specific line number"""
    context_lines = request.args.get('lines', 50, type=int)
    
    if docker_client:
        try:
            cont = docker_client.containers.get(container)
            if cont.status == 'running':
                logs = cont.logs(tail=2000, timestamps=True).decode('utf-8', errors='ignore')
                lines = logs.split('\n')
                
                start = max(0, line - context_lines)
                end = min(len(lines), line + context_lines)
                
                return jsonify({
                    'container': container,
                    'line': line,
                    'context': '\n'.join(lines[start:end]),
                    'range': {'start': start, 'end': end},
                    'total_lines': len(lines)
                })
        except Exception as e:
            return jsonify({'error': str(e)}), 500
    
    return jsonify({'error': 'Docker not available'}), 503

@app.route('/api/devices/search-logs')
def api_device_search_logs():
    """Search logs for a device across all containers"""
    device = request.args.get('device', '')
    container = request.args.get('container', 'rotom')
    keyword = request.args.get('keyword', '')
    limit = request.args.get('limit', 100, type=int)
    
    if not device and not keyword:
        return jsonify({'error': 'Must specify device or keyword'}), 400
    
    search_term = device or keyword
    results = []
    
    if docker_client:
        containers = [container] if container else ['rotom', 'dragonite']
        for cont_name in containers:
            try:
                cont = docker_client.containers.get(cont_name)
                if cont.status == 'running':
                    logs = cont.logs(tail=2000, timestamps=True).decode('utf-8', errors='ignore')
                    lines = logs.split('\n')
                    
                    for i, line in enumerate(lines):
                        if search_term.lower() in line.lower():
                            results.append({
                                'container': cont_name,
                                'line': i,
                                'content': line[:500],
                                'timestamp': line[:30] if '[' in line[:30] else None
                            })
                            if len(results) >= limit:
                                break
            except Exception as e:
                print(f"Error searching {cont_name}: {e}")
    
    return jsonify({
        'query': search_term,
        'results': results[:limit],
        'total': len(results)
    })

# =============================================================================
# DEVICE MONITOR ENDPOINTS (Real-Time Activity Streaming)
# =============================================================================

@app.route('/api/monitor/start', methods=['POST'])
def api_monitor_start():
    """Start the real-time device monitor"""
    if device_monitor:
        device_monitor.start()
        return jsonify({'status': 'started'})
    return jsonify({'error': 'Monitor not available'}), 503

@app.route('/api/monitor/stop', methods=['POST'])
def api_monitor_stop():
    """Stop the real-time device monitor"""
    if device_monitor:
        device_monitor.stop()
        return jsonify({'status': 'stopped'})
    return jsonify({'error': 'Monitor not available'}), 503

@app.route('/api/monitor/status')
def api_monitor_status():
    """Get monitor status and live summary"""
    if device_monitor:
        return jsonify({
            'running': device_monitor.running,
            'summary': device_monitor.get_live_summary()
        })
    return jsonify({'error': 'Monitor not available'}), 503

@app.route('/api/monitor/activity')
def api_monitor_activity():
    """Get recent activity feed"""
    if not device_monitor:
        return jsonify({'error': 'Monitor not available'}), 503
    
    limit = request.args.get('limit', 50, type=int)
    device = request.args.get('device', None)
    severity = request.args.get('severity', None)
    
    return jsonify(device_monitor.get_activity_feed(limit, device, severity))

@app.route('/api/monitor/devices')
def api_monitor_devices():
    """Get current device states from monitor"""
    if device_monitor:
        return jsonify(device_monitor.get_device_states())
    return jsonify({'error': 'Monitor not available'}), 503

@app.route('/api/monitor/containers')
def api_monitor_containers():
    """Get container health states"""
    if device_monitor:
        return jsonify(device_monitor.get_container_states())
    return jsonify({'error': 'Monitor not available'}), 503

@app.route('/api/monitor/device/<device_name>')
def api_monitor_device(device_name):
    """Get activity for a specific device"""
    if not device_monitor:
        return jsonify({'error': 'Monitor not available'}), 503
    
    states = device_monitor.get_device_states()
    device_state = states.get(device_name, {})
    
    # Get activity feed for this device
    activity = device_monitor.get_activity_feed(50, device=device_name)
    
    return jsonify({
        'state': device_state,
        'activity': activity
    })

@app.route('/api/monitor/port7070')
def api_monitor_port7070():
    """Get active connections to Rotom device port 7070"""
    if not device_monitor:
        return jsonify({'error': 'Monitor not available'}), 503
    
    return jsonify(device_monitor.get_port_7070_connections())

@app.route('/api/monitor/traffic')
def api_monitor_traffic():
    """Get recent device traffic from Rotom logs"""
    if not device_monitor:
        return jsonify({'error': 'Monitor not available'}), 503
    
    lines = request.args.get('lines', 200, type=int)
    return jsonify(device_monitor.get_rotom_device_traffic(lines))

@app.route('/api/monitor/correlations')
def api_monitor_correlations():
    """Get correlated crashes (same incident across Rotom and Dragonite)"""
    if not device_monitor:
        return jsonify({'error': 'Monitor not available'}), 503
    
    # Get all correlated crashes from devices
    correlations = []
    with device_monitor.lock:
        for device_name, dev in device_monitor.devices.items():
            if 'correlated_crashes' in dev:
                for crash in dev['correlated_crashes']:
                    crash['device'] = device_name
                    correlations.append(crash)
    
    # Sort by most recent
    correlations.sort(key=lambda x: x.get('timestamp', ''), reverse=True)
    
    return jsonify({
        'total': len(correlations),
        'correlations': correlations[:50]
    })

@app.route('/api/monitor/workflow')
def api_monitor_workflow():
    """Get the complete device workflow status"""
    if not device_monitor:
        return jsonify({'error': 'Monitor not available'}), 503
    
    summary = device_monitor.get_live_summary()
    port_connections = device_monitor.get_port_7070_connections()
    
    return jsonify({
        'workflow': summary.get('workflow', {}),
        'devices': summary.get('devices', {}),
        'tasks': summary.get('tasks', {}),
        'workers': summary.get('workers', {}),
        'port_7070': {
            'active_connections': port_connections.get('established', 0),
            'unique_devices': port_connections.get('unique_devices', 0)
        },
        'activity': summary.get('activity', {}),
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/monitor/memory')
def api_monitor_memory():
    """Get device memory statistics from Rotom reports"""
    if not device_monitor:
        return jsonify({'error': 'Monitor not available'}), 503
    
    devices_with_memory = []
    
    with device_monitor.lock:
        for name, dev in device_monitor.devices.items():
            if 'memory' in dev:
                devices_with_memory.append({
                    'device': name,
                    'status': dev.get('status', 'unknown'),
                    'memory': dev.get('memory', {}),
                    'last_report': dev.get('last_memory_report'),
                    'history': dev.get('memory_history', [])
                })
    
    # Sort by free memory (lowest first - most concerning)
    devices_with_memory.sort(key=lambda x: x['memory'].get('free_mb', 99999))
    
    return jsonify({
        'devices': devices_with_memory,
        'total_devices': len(devices_with_memory),
        'low_memory_devices': len([d for d in devices_with_memory if d['memory'].get('free_mb', 99999) < 500]),
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/monitor/instances')
def api_monitor_instances():
    """Get scanning statistics per Dragonite instance"""
    if not device_monitor:
        return jsonify({'error': 'Monitor not available'}), 503
    
    instances = []
    
    with device_monitor.lock:
        if hasattr(device_monitor, 'instance_stats'):
            for name, stats in device_monitor.instance_stats.items():
                # Calculate catch rate
                attempts = stats.get('catch_attempts', 0)
                catches = stats.get('catches', 0)
                fled = stats.get('fled', 0)
                escaped = stats.get('escaped', 0)
                catch_rate = round((catches / max(attempts, 1)) * 100, 1)
                
                instances.append({
                    'instance': name,
                    'catches': catches,
                    'fled': fled,
                    'escaped': escaped,
                    'attempts': attempts,
                    'catch_rate': catch_rate,
                    'spins': stats.get('spins', 0),
                    'locations': stats.get('locations', 0),
                    'last_activity': stats.get('last_activity'),
                    'session_start': stats.get('session_start')
                })
    
    # Sort by most catches
    instances.sort(key=lambda x: x['catches'], reverse=True)
    
    # Calculate totals
    total_catches = sum(i['catches'] for i in instances)
    total_fled = sum(i['fled'] for i in instances)
    total_spins = sum(i['spins'] for i in instances)
    total_locations = sum(i['locations'] for i in instances)
    
    return jsonify({
        'instances': instances,
        'totals': {
            'catches': total_catches,
            'fled': total_fled,
            'spins': total_spins,
            'locations': total_locations,
            'catch_rate': round((total_catches / max(total_catches + total_fled, 1)) * 100, 1)
        },
        'timestamp': datetime.now().isoformat()
    })

# =============================================================================
# SYSTEM ENDPOINTS
# =============================================================================

@app.route('/api/ports')
def api_ports():
    """Get port status"""
    stats = stats_collector.get_all_stats()
    return jsonify(list(stats.get('ports', {}).values()))

@app.route('/api/service-status')
def api_service_status():
    """Get service status from stats collector (legacy)"""
    stats = stats_collector.get_all_stats()
    return jsonify(stats.get('services', {}))

@app.route('/api/logs/shellder')
def api_shellder_logs():
    """Get Shellder operation logs"""
    lines = request.args.get('lines', 100, type=int)
    
    if SHELLDER_LOG.exists():
        try:
            with open(SHELLDER_LOG, 'r') as f:
                all_lines = f.readlines()
                return jsonify({
                    'logs': ''.join(all_lines[-lines:]),
                    'lines': len(all_lines[-lines:])
                })
        except Exception as e:
            return jsonify({'logs': f'Error reading log: {e}', 'lines': 0})
    
    return jsonify({'logs': 'Log file not found', 'lines': 0})

@app.route('/api/env')
def api_env():
    """Get environment configuration (sanitized)"""
    env_file = AEGIS_ROOT / '.env'
    if not env_file.exists():
        return jsonify({'configured': False, 'variables': {}})
    
    env_vars = {}
    try:
        with open(env_file, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    if 'PASSWORD' in key or 'SECRET' in key or 'TOKEN' in key:
                        env_vars[key] = '********'
                    else:
                        env_vars[key] = value.strip('"\'')
        return jsonify({'configured': True, 'variables': env_vars})
    except Exception as e:
        return jsonify({'configured': False, 'error': str(e)})

@app.route('/api/services')
def api_system_services():
    """Get status of all system services required by the Aegis stack (fast version)"""
    from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout
    
    info('SERVICES', 'System services check started')
    start_time = time.time()
    
    services = {}
    TIMEOUT = 1  # 1 second timeout per service check (reduced for speed)
    
    def check_docker():
        try:
            # Use docker_client if available (faster)
            if docker_client:
                docker_client.ping()
                return {'name': 'Docker', 'status': 'running', 'icon': '🐳', 'description': 'Container runtime'}
            else:
                result = subprocess.run(['docker', 'ps'], capture_output=True, timeout=TIMEOUT)
                return {
                    'name': 'Docker',
                    'status': 'running' if result.returncode == 0 else 'stopped',
                    'icon': '🐳',
                    'description': 'Container runtime'
                }
        except Exception:
            return {'name': 'Docker', 'status': 'not_found', 'icon': '🐳', 'description': 'Container runtime'}
    
    def check_mariadb():
        try:
            if docker_client:
                for c in docker_client.containers.list():
                    if 'mariadb' in c.name.lower() or 'mysql' in c.name.lower() or c.name == 'database':
                        return {'name': 'MariaDB', 'status': 'running' if c.status == 'running' else 'stopped', 'icon': '🗄️', 'description': 'Database server'}
            # Check native
            result = subprocess.run(['systemctl', 'is-active', 'mariadb'], capture_output=True, text=True, timeout=TIMEOUT)
            if result.stdout.strip() == 'active':
                return {'name': 'MariaDB', 'status': 'running', 'icon': '🗄️', 'description': 'Database server'}
            return {'name': 'MariaDB', 'status': 'stopped', 'icon': '🗄️', 'description': 'Database server'}
        except Exception:
            return {'name': 'MariaDB', 'status': 'stopped', 'icon': '🗄️', 'description': 'Database server'}
    
    def check_python():
        import sys
        return {
            'name': 'Python',
            'status': 'running',
            'version': f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}',
            'icon': '🐍',
            'description': 'Runtime environment'
        }
    
    def check_git():
        try:
            result = subprocess.run(['git', '--version'], capture_output=True, text=True, timeout=TIMEOUT)
            version = result.stdout.strip().replace('git version ', '') if result.returncode == 0 else 'Unknown'
            return {'name': 'Git', 'status': 'running', 'version': version, 'icon': '📦', 'description': 'Version control'}
        except Exception:
            return {'name': 'Git', 'status': 'not_found', 'icon': '📦', 'description': 'Version control'}
    
    def check_nginx():
        try:
            result = subprocess.run(['systemctl', 'is-active', 'nginx'], capture_output=True, text=True, timeout=TIMEOUT)
            return {
                'name': 'Nginx',
                'status': 'running' if result.stdout.strip() == 'active' else 'stopped',
                'icon': '🌐',
                'description': 'Reverse proxy'
            }
        except Exception:
            return {'name': 'Nginx', 'status': 'not_found', 'icon': '🌐', 'description': 'Reverse proxy'}
    
    def check_compose():
        try:
            result = subprocess.run(['docker', 'compose', 'version'], capture_output=True, text=True, timeout=TIMEOUT)
            if result.returncode == 0:
                version = result.stdout.strip().split()[-1].replace('v', '') if result.stdout else 'Unknown'
                return {'name': 'Docker Compose', 'status': 'running', 'version': version, 'icon': '🔧', 'description': 'Container orchestration'}
        except Exception:
            pass
        return {'name': 'Docker Compose', 'status': 'not_found', 'icon': '🔧', 'description': 'Container orchestration'}
    
    # Run all checks in parallel with timeout
    checks = {
        'docker': check_docker,
        'mariadb': check_mariadb,
        'python': check_python,
        'git': check_git,
        'nginx': check_nginx,
        'compose': check_compose,
    }
    
    try:
        with ThreadPoolExecutor(max_workers=6) as executor:
            futures = {key: executor.submit(func) for key, func in checks.items()}
            for key, future in futures.items():
                try:
                    services[key] = future.result(timeout=3)  # Max 3s per check
                except Exception:
                    services[key] = {'name': key.title(), 'status': 'timeout', 'icon': '⏳', 'description': 'Check timed out'}
    except Exception as e:
        return jsonify({'error': str(e), 'services': {}})
    
    # Add Shellder (always running since we're serving this request)
    services['shellder'] = {
        'name': 'Shellder',
        'status': 'running',
        'icon': '🐚',
        'description': 'Control panel',
        'version': '1.0'
    }
    
    # Calculate summary
    running = sum(1 for s in services.values() if s.get('status') == 'running')
    total = len(services)
    duration = (time.time() - start_time) * 1000
    
    info('SERVICES', f'System services check completed in {duration:.0f}ms', {
        'running': running, 
        'total': total,
        'services': list(services.keys())
    })
    
    return jsonify({
        'services': services,
        'summary': {
            'running': running,
            'total': total,
            'healthy': running >= 4  # At least Docker, Python, Git, MariaDB
        }
    })

@app.route('/api/git/status')
def api_git_status():
    """Get git status"""
    try:
        subprocess.run(["git", "fetch"], capture_output=True, timeout=30, cwd=str(AEGIS_ROOT))
        
        result = subprocess.run(
            ["git", "status", "-sb"],
            capture_output=True, text=True, timeout=10,
            cwd=str(AEGIS_ROOT)
        )
        
        return jsonify({
            'status': result.stdout,
            'behind': 'behind' in result.stdout,
            'ahead': 'ahead' in result.stdout,
            'success': True
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/git/pull', methods=['POST'])
def api_git_pull():
    """Pull latest updates"""
    try:
        result = subprocess.run(
            ["git", "pull"],
            capture_output=True, text=True, timeout=60,
            cwd=str(AEGIS_ROOT)
        )
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/files')
def api_files():
    """List files in a directory"""
    path = request.args.get('path', '')
    full_path = AEGIS_ROOT / path
    
    if not full_path.exists() or not full_path.is_dir():
        return jsonify({'error': 'Path not found', 'files': []})
    
    # Security: ensure path is within AEGIS_ROOT
    try:
        full_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'error': 'Access denied', 'files': []})
    
    files = []
    try:
        for item in full_path.iterdir():
            files.append({
                'name': item.name,
                'type': 'directory' if item.is_dir() else 'file',
                'size': item.stat().st_size if item.is_file() else 0,
                'modified': datetime.fromtimestamp(item.stat().st_mtime).isoformat()
            })
        files.sort(key=lambda x: (x['type'] != 'directory', x['name'].lower()))
        return jsonify({'path': path, 'files': files})
    except Exception as e:
        return jsonify({'error': str(e), 'files': []})

@app.route('/api/file')
def api_file_content():
    """Get file content"""
    path = request.args.get('path', '')
    full_path = AEGIS_ROOT / path
    
    if not full_path.exists() or not full_path.is_file():
        return jsonify({'error': 'File not found'})
    
    # Security check
    try:
        full_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'error': 'Access denied'})
    
    # Don't read large files or binaries
    if full_path.stat().st_size > 1024 * 1024:  # 1MB
        return jsonify({'error': 'File too large'})
    
    try:
        with open(full_path, 'r') as f:
            content = f.read()
        return jsonify({'path': path, 'content': content})
    except Exception as e:
        return jsonify({'error': str(e)})


@app.route('/api/files/info')
def api_file_info():
    """Get detailed file information including permissions and ownership"""
    path = request.args.get('path', '')
    full_path = AEGIS_ROOT / path
    
    if not full_path.exists():
        return jsonify({'error': 'Path not found'})
    
    # Security check
    try:
        full_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'error': 'Access denied'})
    
    try:
        stat_info = full_path.stat()
        import pwd
        import grp
        
        # Get owner and group names
        try:
            owner = pwd.getpwuid(stat_info.st_uid).pw_name
        except:
            owner = str(stat_info.st_uid)
        
        try:
            group = grp.getgrgid(stat_info.st_gid).gr_name
        except:
            group = str(stat_info.st_gid)
        
        # Format permissions
        mode = stat_info.st_mode
        perms = oct(mode)[-3:]
        
        return jsonify({
            'path': path,
            'name': full_path.name,
            'type': 'directory' if full_path.is_dir() else 'file',
            'size': stat_info.st_size,
            'owner': owner,
            'group': group,
            'uid': stat_info.st_uid,
            'gid': stat_info.st_gid,
            'permissions': perms,
            'permissions_octal': oct(mode),
            'modified': datetime.fromtimestamp(stat_info.st_mtime).isoformat(),
            'created': datetime.fromtimestamp(stat_info.st_ctime).isoformat(),
            'readable': os.access(full_path, os.R_OK),
            'writable': os.access(full_path, os.W_OK),
            'executable': os.access(full_path, os.X_OK)
        })
    except Exception as e:
        return jsonify({'error': str(e)})


@app.route('/api/files/save', methods=['POST'])
def api_file_save():
    """Save file content"""
    data = request.json or {}
    path = data.get('path', '')
    content = data.get('content', '')
    
    if not path:
        return jsonify({'success': False, 'error': 'Path is required'})
    
    full_path = AEGIS_ROOT / path
    
    # Security check
    try:
        full_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'success': False, 'error': 'Access denied'})
    
    try:
        success, error = safe_write_file(str(full_path), content)
        if success:
            return jsonify({'success': True, 'message': f'Saved {path}'})
        else:
            return jsonify({'success': False, 'error': error})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/files/create', methods=['POST'])
def api_file_create():
    """Create a new file (touch)"""
    data = request.json or {}
    path = data.get('path', '')
    filename = data.get('filename', '')
    
    if not filename:
        return jsonify({'success': False, 'error': 'Filename is required'})
    
    full_path = AEGIS_ROOT / path / filename
    
    # Security check
    try:
        full_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'success': False, 'error': 'Access denied'})
    
    if full_path.exists():
        return jsonify({'success': False, 'error': 'File already exists'})
    
    try:
        full_path.touch()
        # Fix ownership
        result = subprocess.run(['sudo', 'chown', f'{os.getuid()}:{os.getgid()}', str(full_path)],
                               capture_output=True, timeout=5)
        return jsonify({'success': True, 'message': f'Created {filename}'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/files/mkdir', methods=['POST'])
def api_file_mkdir():
    """Create a new directory"""
    data = request.json or {}
    path = data.get('path', '')
    dirname = data.get('dirname', '')
    
    if not dirname:
        return jsonify({'success': False, 'error': 'Directory name is required'})
    
    full_path = AEGIS_ROOT / path / dirname
    
    # Security check
    try:
        full_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'success': False, 'error': 'Access denied'})
    
    if full_path.exists():
        return jsonify({'success': False, 'error': 'Directory already exists'})
    
    try:
        full_path.mkdir(parents=True)
        return jsonify({'success': True, 'message': f'Created directory {dirname}'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/files/delete', methods=['POST'])
def api_file_delete():
    """Delete a file or directory"""
    data = request.json or {}
    path = data.get('path', '')
    
    if not path:
        return jsonify({'success': False, 'error': 'Path is required'})
    
    full_path = AEGIS_ROOT / path
    
    # Security check
    try:
        full_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'success': False, 'error': 'Access denied'})
    
    if not full_path.exists():
        return jsonify({'success': False, 'error': 'Path not found'})
    
    # Prevent deleting critical files
    protected = ['.env', 'docker-compose.yaml', 'docker-compose.yml', 'Shellder']
    if full_path.name in protected or str(path) in protected:
        return jsonify({'success': False, 'error': 'Cannot delete protected file/directory'})
    
    try:
        if full_path.is_dir():
            import shutil
            shutil.rmtree(full_path)
            return jsonify({'success': True, 'message': f'Deleted directory {path}'})
        else:
            full_path.unlink()
            return jsonify({'success': True, 'message': f'Deleted {path}'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/files/rename', methods=['POST'])
def api_file_rename():
    """Rename a file or directory"""
    data = request.json or {}
    path = data.get('path', '')
    new_name = data.get('new_name', '')
    
    if not path or not new_name:
        return jsonify({'success': False, 'error': 'Path and new name are required'})
    
    full_path = AEGIS_ROOT / path
    new_path = full_path.parent / new_name
    
    # Security check
    try:
        full_path.resolve().relative_to(AEGIS_ROOT.resolve())
        new_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'success': False, 'error': 'Access denied'})
    
    if not full_path.exists():
        return jsonify({'success': False, 'error': 'Path not found'})
    
    if new_path.exists():
        return jsonify({'success': False, 'error': 'Target already exists'})
    
    try:
        full_path.rename(new_path)
        return jsonify({'success': True, 'message': f'Renamed to {new_name}'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/files/chown', methods=['POST'])
def api_file_chown():
    """Change file ownership"""
    data = request.json or {}
    path = data.get('path', '')
    owner = data.get('owner', '')
    recursive = data.get('recursive', False)
    
    if not path:
        return jsonify({'success': False, 'error': 'Path is required'})
    
    full_path = AEGIS_ROOT / path
    
    # Security check
    try:
        full_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'success': False, 'error': 'Access denied'})
    
    if not full_path.exists():
        return jsonify({'success': False, 'error': 'Path not found'})
    
    # Default to current user if no owner specified
    if not owner:
        import pwd
        owner = pwd.getpwuid(os.getuid()).pw_name
    
    try:
        cmd = ['sudo', 'chown']
        if recursive and full_path.is_dir():
            cmd.append('-R')
        cmd.extend([owner, str(full_path)])
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            return jsonify({'success': True, 'message': f'Changed ownership to {owner}'})
        else:
            return jsonify({'success': False, 'error': result.stderr or 'Failed to change ownership'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/files/chmod', methods=['POST'])
def api_file_chmod():
    """Change file permissions"""
    data = request.json or {}
    path = data.get('path', '')
    mode = data.get('mode', '')  # e.g., '755', '644'
    recursive = data.get('recursive', False)
    
    if not path or not mode:
        return jsonify({'success': False, 'error': 'Path and mode are required'})
    
    # Validate mode
    if not mode.isdigit() or len(mode) != 3:
        return jsonify({'success': False, 'error': 'Invalid mode format (use 3 digits like 755)'})
    
    full_path = AEGIS_ROOT / path
    
    # Security check
    try:
        full_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'success': False, 'error': 'Access denied'})
    
    if not full_path.exists():
        return jsonify({'success': False, 'error': 'Path not found'})
    
    try:
        cmd = ['sudo', 'chmod']
        if recursive and full_path.is_dir():
            cmd.append('-R')
        cmd.extend([mode, str(full_path)])
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            return jsonify({'success': True, 'message': f'Changed permissions to {mode}'})
        else:
            return jsonify({'success': False, 'error': result.stderr or 'Failed to change permissions'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/files/copy', methods=['POST'])
def api_file_copy():
    """Copy a file or directory"""
    data = request.json or {}
    source = data.get('source', '')
    dest = data.get('dest', '')
    
    if not source or not dest:
        return jsonify({'success': False, 'error': 'Source and destination are required'})
    
    source_path = AEGIS_ROOT / source
    dest_path = AEGIS_ROOT / dest
    
    # Security check
    try:
        source_path.resolve().relative_to(AEGIS_ROOT.resolve())
        dest_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'success': False, 'error': 'Access denied'})
    
    if not source_path.exists():
        return jsonify({'success': False, 'error': 'Source not found'})
    
    try:
        import shutil
        if source_path.is_dir():
            shutil.copytree(source_path, dest_path)
        else:
            shutil.copy2(source_path, dest_path)
        return jsonify({'success': True, 'message': f'Copied to {dest}'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/files/download')
def api_file_download():
    """Download a file"""
    path = request.args.get('path', '')
    
    if not path:
        return jsonify({'error': 'Path is required'}), 400
    
    full_path = AEGIS_ROOT / path
    
    # Security check
    try:
        full_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'error': 'Access denied'}), 403
    
    if not full_path.exists() or not full_path.is_file():
        return jsonify({'error': 'File not found'}), 404
    
    try:
        from flask import send_file
        return send_file(full_path, as_attachment=True, download_name=full_path.name)
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/files/upload', methods=['POST'])
def api_file_upload():
    """Upload a file (can replace existing)"""
    if 'file' not in request.files:
        return jsonify({'success': False, 'error': 'No file provided'})
    
    file = request.files['file']
    path = request.form.get('path', '')
    
    if file.filename == '':
        return jsonify({'success': False, 'error': 'No file selected'})
    
    # Determine destination path
    if path:
        dest_path = AEGIS_ROOT / path / file.filename
    else:
        dest_path = AEGIS_ROOT / file.filename
    
    # Security check
    try:
        dest_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'success': False, 'error': 'Access denied'})
    
    # Check if replacing
    replacing = dest_path.exists()
    
    try:
        # Ensure parent directory exists
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        
        # Save file
        file.save(str(dest_path))
        
        # Fix ownership to actual user (not root)
        try:
            import pwd
            # Try SUDO_USER first, then Aegis dir owner
            current_user = os.environ.get('SUDO_USER')
            if not current_user:
                aegis_stat = os.stat(AEGIS_ROOT)
                current_user = pwd.getpwuid(aegis_stat.st_uid).pw_name
            subprocess.run(['sudo', 'chown', f'{current_user}:{current_user}', str(dest_path)],
                          capture_output=True, timeout=5)
        except:
            pass
        
        action = 'replaced' if replacing else 'uploaded'
        return jsonify({'success': True, 'message': f'File {action}: {file.filename}'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/files/chown-all', methods=['POST'])
def api_file_chown_all():
    """Change ownership of all files in Aegis directory to current user"""
    data = request.json or {}
    path = data.get('path', '')  # Optional: specific subdirectory
    
    # Get the real user (not root if running with sudo)
    current_user = None
    current_group = None
    
    try:
        import pwd
        import grp
        
        # First try SUDO_USER (set when running via sudo)
        current_user = os.environ.get('SUDO_USER')
        if current_user:
            user_info = pwd.getpwnam(current_user)
            current_group = grp.getgrgid(user_info.pw_gid).gr_name
        
        # If no SUDO_USER, try to get owner of the Aegis directory
        if not current_user:
            aegis_stat = os.stat(AEGIS_ROOT)
            user_info = pwd.getpwuid(aegis_stat.st_uid)
            current_user = user_info.pw_name
            current_group = grp.getgrgid(user_info.pw_gid).gr_name
        
        # Last resort: use os.getlogin() or getuid
        if not current_user:
            try:
                current_user = os.getlogin()
            except:
                current_user = pwd.getpwuid(os.getuid()).pw_name
            current_group = current_user
            
    except Exception as e:
        return jsonify({'success': False, 'error': f'Could not determine current user: {e}'})
    
    target_path = AEGIS_ROOT / path if path else AEGIS_ROOT
    
    # Security check
    try:
        target_path.resolve().relative_to(AEGIS_ROOT.resolve())
    except ValueError:
        return jsonify({'success': False, 'error': 'Access denied'})
    
    if not target_path.exists():
        return jsonify({'success': False, 'error': 'Path not found'})
    
    sudo_password = data.get('sudo_password', '')
    
    try:
        if sudo_password:
            # Run with password via stdin
            result = subprocess.run(
                ['sudo', '-S', 'chown', '-R', f'{current_user}:{current_group}', str(target_path)],
                input=sudo_password + '\n',
                capture_output=True, text=True, timeout=120
            )
        else:
            # Try without password first (in case NOPASSWD is set)
            result = subprocess.run(
                ['sudo', '-n', 'chown', '-R', f'{current_user}:{current_group}', str(target_path)],
                capture_output=True, text=True, timeout=120
            )
        
        if result.returncode == 0:
            return jsonify({
                'success': True, 
                'message': f'Changed ownership to {current_user}:{current_group}',
                'path': str(target_path)
            })
        else:
            # Check if password is required
            if 'password' in result.stderr.lower() or 'sudo' in result.stderr.lower():
                return jsonify({
                    'success': False, 
                    'error': 'Password required',
                    'needs_password': True,
                    'target_user': current_user
                })
            return jsonify({'success': False, 'error': result.stderr or 'Failed to change ownership'})
    except subprocess.TimeoutExpired:
        return jsonify({'success': False, 'error': 'Operation timed out (directory may be very large)'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})


@app.route('/api/files/current-user')
def api_files_current_user():
    """Get current user info for ownership operations"""
    try:
        import pwd
        import grp
        
        # Get the real user (not root if running with sudo)
        username = None
        
        # First try SUDO_USER
        username = os.environ.get('SUDO_USER')
        
        # If no SUDO_USER, try owner of Aegis directory
        if not username:
            try:
                aegis_stat = os.stat(AEGIS_ROOT)
                user_info = pwd.getpwuid(aegis_stat.st_uid)
                username = user_info.pw_name
            except:
                pass
        
        # Last resort
        if not username:
            try:
                username = os.getlogin()
            except:
                username = pwd.getpwuid(os.getuid()).pw_name
        
        # Get user info
        user_info = pwd.getpwnam(username)
        group_info = grp.getgrgid(user_info.pw_gid)
        
        return jsonify({
            'username': user_info.pw_name,
            'uid': user_info.pw_uid,
            'group': group_info.gr_name,
            'gid': user_info.pw_gid,
            'home': user_info.pw_dir
        })
    except Exception as e:
        return jsonify({'error': str(e)})


@app.route('/api/stats/live')
def api_stats_live():
    """Get all live statistics"""
    return jsonify(stats_collector.get_all_stats())

# =============================================================================
# WEBSOCKET EVENTS
# =============================================================================

if SOCKETIO_AVAILABLE:
    @socketio.on('connect')
    def handle_connect():
        """Client connected"""
        track_websocket('connect', request.sid)
        # Track connected clients for adaptive polling
        if stats_collector:
            stats_collector.client_connected()
        emit('connected', {'status': 'connected', 'timestamp': datetime.now().isoformat()})

    @socketio.on('disconnect')
    def handle_disconnect():
        """Client disconnected"""
        track_websocket('disconnect', request.sid)
        # Track disconnected clients for adaptive polling
        if stats_collector:
            stats_collector.client_disconnected()

    @socketio.on('subscribe')
    def handle_subscribe(data):
        """Subscribe to specific stats"""
        channel = data.get('channel', 'all')
        print(f"Client {request.sid} subscribed to {channel}")
        
        # Send current stats immediately
        stats = stats_collector.get_all_stats()
        if channel == 'containers':
            emit('container_stats', stats.get('containers', {}))
        elif channel == 'system':
            emit('system_stats', stats.get('system', {}))
        elif channel == 'xilriws':
            emit('xilriws_stats', stats.get('xilriws', {}))
        elif channel == 'ports':
            emit('port_status', stats.get('ports', {}))
        elif channel == 'services':
            emit('service_status', stats.get('services', {}))
        else:
            emit('all_stats', stats)

    @socketio.on('container_action')
    def handle_container_action(data):
        """Handle container action via WebSocket"""
        name = data.get('name')
        action = data.get('action')
        
        if action not in ['start', 'stop', 'restart']:
            emit('action_result', {'success': False, 'error': 'Invalid action'})
            return
        
        try:
            if docker_client:
                container = docker_client.containers.get(name)
                getattr(container, action)()
            else:
                subprocess.run(["docker", action, name], timeout=60)
            emit('action_result', {'success': True, 'message': f'{name} {action}ed'})
        except Exception as e:
            emit('action_result', {'success': False, 'error': str(e)})

    # =========================================================================
    # AI DEBUG WEBSOCKET - Real-time AI debugging interface
    # =========================================================================
    
    @socketio.on('ai_debug_exec')
    def handle_ai_debug_exec(data):
        """Execute command via WebSocket for AI debugging"""
        if not AI_DEBUG_CONFIG.get('websocket_enabled') or not AI_DEBUG_CONFIG.get('command_exec'):
            emit('ai_debug_result', {'error': 'Command execution disabled'})
            return
        
        cmd = data.get('cmd', '')
        timeout = data.get('timeout', 30)
        
        try:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, 
                                   timeout=timeout, cwd=str(AEGIS_ROOT))
            emit('ai_debug_result', {
                'type': 'exec',
                'command': cmd,
                'returncode': result.returncode,
                'stdout': result.stdout,
                'stderr': result.stderr
            })
        except Exception as e:
            emit('ai_debug_result', {'type': 'exec', 'error': str(e)})
    
    @socketio.on('ai_debug_file')
    def handle_ai_debug_file(data):
        """Read/write file via WebSocket for AI debugging"""
        if not AI_DEBUG_CONFIG.get('websocket_enabled') or not AI_DEBUG_CONFIG.get('file_access'):
            emit('ai_debug_result', {'error': 'File access disabled'})
            return
        
        action = data.get('action', 'read')
        path = data.get('path', '')
        
        try:
            full_path = AEGIS_ROOT / path
            full_path.resolve().relative_to(AEGIS_ROOT.resolve())
            
            if action == 'read':
                if full_path.exists():
                    with open(full_path, 'r', encoding='utf-8', errors='replace') as f:
                        content = f.read()
                    emit('ai_debug_result', {'type': 'file', 'action': 'read', 'path': path, 'content': content})
                else:
                    emit('ai_debug_result', {'type': 'file', 'error': 'File not found'})
            elif action == 'write':
                content = data.get('content', '')
                with open(full_path, 'w', encoding='utf-8') as f:
                    f.write(content)
                emit('ai_debug_result', {'type': 'file', 'action': 'write', 'path': path, 'success': True})
        except Exception as e:
            emit('ai_debug_result', {'type': 'file', 'error': str(e)})
    
    @socketio.on('ai_debug_docker')
    def handle_ai_debug_docker(data):
        """Docker operations via WebSocket for AI debugging"""
        if not AI_DEBUG_CONFIG.get('websocket_enabled') or not AI_DEBUG_CONFIG.get('docker_access'):
            emit('ai_debug_result', {'error': 'Docker access disabled'})
            return
        
        cmd = data.get('cmd', 'ps')
        container = data.get('container', '')
        
        try:
            if cmd == 'ps':
                result = subprocess.run(['docker', 'compose', 'ps', '--format', 'json'],
                                       capture_output=True, text=True, cwd=str(AEGIS_ROOT), timeout=30)
                containers = []
                for line in result.stdout.strip().split('\n'):
                    if line:
                        try:
                            containers.append(json.loads(line))
                        except:
                            pass
                emit('ai_debug_result', {'type': 'docker', 'cmd': 'ps', 'containers': containers})
            elif cmd == 'logs' and container:
                result = subprocess.run(['docker', 'logs', '--tail', '100', container],
                                       capture_output=True, text=True, timeout=30)
                emit('ai_debug_result', {'type': 'docker', 'cmd': 'logs', 'container': container, 
                                        'logs': result.stdout + result.stderr})
            else:
                emit('ai_debug_result', {'type': 'docker', 'error': f'Unknown command: {cmd}'})
        except Exception as e:
            emit('ai_debug_result', {'type': 'docker', 'error': str(e)})
    
    @socketio.on('ai_debug_diagnose')
    def handle_ai_debug_diagnose(data):
        """Run diagnostics via WebSocket for AI debugging"""
        if not AI_DEBUG_CONFIG.get('websocket_enabled') or not AI_DEBUG_CONFIG.get('system_info'):
            emit('ai_debug_result', {'error': 'System info disabled'})
            return
        
        # Reuse the REST endpoint logic
        with app.test_request_context():
            result = api_ai_debug_diagnose()
            emit('ai_debug_result', {'type': 'diagnose', 'data': result.get_json()})

# =============================================================================
# MAIN
# =============================================================================

_start_time = time.time()  # Track service start time for uptime

def main():
    global _start_time
    _start_time = time.time()
    
    # Log startup with version
    info('STARTUP', '='*60)
    info('STARTUP', f'SHELLDER SERVICE v{SHELLDER_VERSION} (build {SHELLDER_BUILD})')
    info('STARTUP', '='*60)
    
    startup_config = {
        'VERSION': SHELLDER_VERSION,
        'BUILD': SHELLDER_BUILD,
        'SHELLDER_PORT': SHELLDER_PORT,
        'AEGIS_ROOT': str(AEGIS_ROOT),
        'SHELLDER_DIR': str(SHELLDER_DIR),
        'TEMPLATES_DIR': str(TEMPLATES_DIR),
        'STATIC_DIR': str(STATIC_DIR),
        'DATA_DIR': str(DATA_DIR),
        'LOG_DIR': str(LOG_DIR),
        'SHELLDER_DB': str(SHELLDER_DB),
        'LOCAL_MODE': LOCAL_MODE,
        'DOCKER_AVAILABLE': DOCKER_AVAILABLE,
        'docker_client': 'connected' if docker_client else 'not connected',
        'SOCKETIO_AVAILABLE': SOCKETIO_AVAILABLE,
        'ASYNC_MODE': ASYNC_MODE,
        'PSUTIL_AVAILABLE': PSUTIL_AVAILABLE,
        'DEBUG_LOGGING': DEBUG_LOGGING
    }
    info('STARTUP', 'Configuration', startup_config)
    
    path_checks = {
        'aegis_root_exists': AEGIS_ROOT.exists(),
        'shellder_dir_exists': SHELLDER_DIR.exists(),
        'templates_dir_exists': TEMPLATES_DIR.exists(),
        'static_dir_exists': STATIC_DIR.exists(),
        'data_dir_exists': DATA_DIR.exists(),
        'log_dir_exists': LOG_DIR.exists(),
        'shellder_db_exists': SHELLDER_DB.exists()
    }
    info('STARTUP', 'Path checks', path_checks)
    
    # Log Docker state if available
    if DOCKER_AVAILABLE and docker_client:
        log_docker_state()
    
    print(f"""
╔═══════════════════════════════════════════════════════════════╗
║                 SHELLDER SERVICE v1.0                          ║
║                                                                 ║
║  Live Monitoring & Control Panel for Aegis AIO                  ║
╠═══════════════════════════════════════════════════════════════╣
║  Dashboard:    http://localhost:{SHELLDER_PORT}                            ║
║  API:          http://localhost:{SHELLDER_PORT}/api/                       ║
║  WebSocket:    ws://localhost:{SHELLDER_PORT}/socket.io/                   ║
║  Debug Log:    Shellder/debuglog.txt                            ║
║                                                                 ║
║  Features:                                                      ║
║    • Real-time container monitoring                             ║
║    • Xilriws proxy statistics                                   ║
║    • System resource tracking                                   ║
║    • Port scanning                                              ║
║    • Service status (nginx, fail2ban, ufw)                      ║
║    • SQLite database access                                     ║
║    • File browser                                               ║
║    • WebSocket for live updates                                 ║
║    • COMPREHENSIVE DEBUG LOGGING (debuglog.txt)                 ║
╚═══════════════════════════════════════════════════════════════╝
    """)
    
    print(f"AEGIS_ROOT: {AEGIS_ROOT}")
    print(f"SHELLDER_DB: {SHELLDER_DB} (exists: {SHELLDER_DB.exists()})")
    print(f"Docker available: {DOCKER_AVAILABLE}")
    print(f"Docker client: {'connected' if docker_client else 'not connected'}")
    print(f"WebSocket: {SOCKETIO_AVAILABLE} (mode: {ASYNC_MODE})")
    print(f"psutil: {PSUTIL_AVAILABLE}")
    print(f"Debug Log: {get_log_path()}")
    print()
    
    # Start stats collector
    stats_collector.start()
    
    # Start device monitor for real-time activity
    if device_monitor:
        device_monitor.start()
        print("Device monitor started for real-time activity tracking")
    
    # Run Flask with SocketIO
    if SOCKETIO_AVAILABLE:
        socketio.run(app, host='0.0.0.0', port=SHELLDER_PORT, debug=False)
    else:
        app.run(host='0.0.0.0', port=SHELLDER_PORT, debug=False)

if __name__ == '__main__':
    main()
