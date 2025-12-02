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
SHELLDER_VERSION = "1.0.12"  # 2025-12-02: Added live debug panel, fixed CPU, version tracking
SHELLDER_BUILD = "20251202-1"  # Date-based build number

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
import sqlite3
import subprocess
import socket
from datetime import datetime, timedelta
from pathlib import Path
from collections import defaultdict
from functools import wraps

# =============================================================================
# DEBUG LOGGER - MUST BE EARLY
# =============================================================================
try:
    from debug_logger import (
        log, trace, debug, info, warn, error, fatal,
        logged, log_system_state, log_docker_state, log_client_logs,
        get_recent_logs, get_log_path, clear_log
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

if SOCKETIO_AVAILABLE:
    socketio = SocketIO(app, cors_allowed_origins="*", async_mode=ASYNC_MODE)
else:
    socketio = None

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
            
            time.sleep(10)
    
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
            return
        
        try:
            cursor = conn.cursor()
            for name, value in metrics.items():
                if value is not None:
                    cursor.execute("""
                        INSERT INTO metrics_history (metric_name, metric_value)
                        VALUES (?, ?)
                    """, (name, float(value)))
            conn.commit()
        except Exception as e:
            print(f"Error recording metrics batch: {e}")
        finally:
            conn.close()
    
    def get_metric_history(self, metric_name, hours=24, limit=500):
        """Get historical values for a metric"""
        conn = self._connect()
        if not conn:
            return []
        
        try:
            cursor = conn.cursor()
            cursor.execute("""
                SELECT metric_value, recorded_at
                FROM metrics_history
                WHERE metric_name = ?
                  AND recorded_at >= datetime('now', ?)
                ORDER BY recorded_at ASC
                LIMIT ?
            """, (metric_name, f'-{hours} hours', limit))
            
            return [{'value': row[0], 'time': row[1]} for row in cursor.fetchall()]
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
    """Collects and stores live statistics for all Aegis AIO components"""
    
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
        
        print("Stats collector started with parsers for: Xilriws, Rotom, Koji, Reactmap, Database")
    
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
            
            time.sleep(5)
    
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
            
            # Record metrics to history database (every 30 seconds)
            if hasattr(self, '_last_metric_record'):
                if time.time() - self._last_metric_record >= 30:
                    self._record_system_metrics(stats)
                    self._last_metric_record = time.time()
            else:
                self._last_metric_record = time.time()
                self._record_system_metrics(stats)
            
            time.sleep(10)
    
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
                service_db.record_metrics_batch(metrics)
        except Exception as e:
            print(f"Error recording system metrics: {e}")
    
    def _cleanup_old_metrics(self):
        """Periodically clean up old metrics to prevent database bloat"""
        while self.running:
            try:
                # Wait 1 hour between cleanups
                time.sleep(3600)
                # Keep 7 days of metrics
                service_db.cleanup_old_metrics(days=7)
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
            
            time.sleep(5)  # More frequent updates for live monitoring
    
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
            
            time.sleep(10)
    
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
            
            time.sleep(15)
    
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
            
            time.sleep(30)  # Reactmap logs don't change frequently
    
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
            
            time.sleep(15)
    
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
            
            time.sleep(30)
    
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
            
            time.sleep(60)
    
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
    hours = request.args.get('hours', 24, type=int)
    limit = request.args.get('limit', 500, type=int)
    
    # Validate metric name
    valid_metrics = ['cpu_percent', 'memory_percent', 'memory_used', 'disk_percent']
    if metric_name not in valid_metrics:
        return jsonify({'error': f'Invalid metric. Valid: {valid_metrics}'}), 400
    
    history = service_db.get_metric_history(metric_name, hours, limit)
    return jsonify({
        'metric': metric_name,
        'hours': hours,
        'data': history
    })

@app.route('/api/metrics/sparklines')
def api_metrics_sparklines():
    """Get sparkline data for all system metrics"""
    points = request.args.get('points', 20, type=int)
    
    return jsonify({
        'cpu': service_db.get_metric_sparkline('cpu_percent', points),
        'memory': service_db.get_metric_sparkline('memory_percent', points),
        'disk': service_db.get_metric_sparkline('disk_percent', points)
    })

@app.route('/api/metrics/current')
def api_metrics_current():
    """Get current system metrics with sparkline data"""
    stats = stats_collector.get_all_stats()
    system = stats.get('system', {})
    
    # Get sparklines
    sparklines = {
        'cpu': service_db.get_metric_sparkline('cpu_percent', 20),
        'memory': service_db.get_metric_sparkline('memory_percent', 20),
        'disk': service_db.get_metric_sparkline('disk_percent', 20)
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
    
    debug_log = SHELLDER_DIR / 'debuglog.txt'
    
    if not debug_log.exists():
        return jsonify({'error': 'debuglog.txt not found', 'path': str(debug_log)}), 404
    
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
    debug_log = SHELLDER_DIR / 'debuglog.txt'
    
    if not debug_log.exists():
        return jsonify({'error': 'debuglog.txt not found'}), 404
    
    info('API', 'Debug log download requested', {'client': request.remote_addr})
    return send_from_directory(
        SHELLDER_DIR,
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

@app.route('/api/debug/clear', methods=['POST'])
def api_debug_clear():
    """Clear debug logs"""
    global client_debug_logs
    client_debug_logs = []
    
    # Clear client debug log file
    client_log = LOG_DIR / 'client_debug.json'
    if client_log.exists():
        client_log.unlink()
    
    return jsonify({'success': True, 'message': 'Debug logs cleared'})

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
    """Docker compose actions"""
    cmd_map = {
        'up': ['docker', 'compose', 'up', '-d'],
        'down': ['docker', 'compose', 'down'],
        'restart': ['docker', 'compose', 'restart'],
        'pull': ['docker', 'compose', 'pull']
    }
    
    if action not in cmd_map:
        return jsonify({'success': False, 'error': 'Invalid action'})
    
    try:
        result = subprocess.run(
            cmd_map[action],
            capture_output=True, text=True, timeout=300,
            cwd=str(AEGIS_ROOT)
        )
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

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
# SITE AVAILABILITY CHECK
# =============================================================================

@app.route('/api/sites/check')
def api_sites_check():
    """Check availability of configured sites"""
    import urllib.request
    import urllib.error
    import ssl
    
    sites_to_check = []
    
    # Get configured sites from nginx
    sites_enabled = Path('/etc/nginx/sites-enabled')
    if sites_enabled.exists():
        for site in sites_enabled.iterdir():
            if site.name != 'default':
                sites_to_check.append(site.name)
    
    # Also check local services
    local_services = [
        {'name': 'ReactMap', 'url': 'http://localhost:6001', 'port': 6001},
        {'name': 'Koji', 'url': 'http://localhost:6002', 'port': 6002},
        {'name': 'Dragonite', 'url': 'http://localhost:7272', 'port': 7272},
        {'name': 'Rotom', 'url': 'http://localhost:7070', 'port': 7070},
        {'name': 'Golbat', 'url': 'http://localhost:9001', 'port': 9001},
        {'name': 'Shellder', 'url': 'http://localhost:5000', 'port': 5000},
    ]
    
    results = []
    healthy = 0
    total = 0
    
    # Check local services
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    
    for svc in local_services:
        total += 1
        try:
            req = urllib.request.Request(svc['url'], method='HEAD')
            req.add_header('User-Agent', 'Shellder-Health-Check')
            response = urllib.request.urlopen(req, timeout=5, context=ctx)
            status = response.getcode()
            results.append({
                'name': svc['name'],
                'url': svc['url'],
                'status': status,
                'healthy': 200 <= status < 400,
                'type': 'local'
            })
            if 200 <= status < 400:
                healthy += 1
        except urllib.error.HTTPError as e:
            results.append({
                'name': svc['name'],
                'url': svc['url'],
                'status': e.code,
                'healthy': False,
                'error': str(e.reason),
                'type': 'local'
            })
        except Exception as e:
            results.append({
                'name': svc['name'],
                'url': svc['url'],
                'status': 0,
                'healthy': False,
                'error': 'Connection failed',
                'type': 'local'
            })
    
    # Check external sites
    for site_name in sites_to_check:
        total += 1
        url = f'https://{site_name}'
        try:
            req = urllib.request.Request(url, method='HEAD')
            req.add_header('User-Agent', 'Shellder-Health-Check')
            response = urllib.request.urlopen(req, timeout=10, context=ctx)
            status = response.getcode()
            results.append({
                'name': site_name,
                'url': url,
                'status': status,
                'healthy': 200 <= status < 400,
                'type': 'external'
            })
            if 200 <= status < 400:
                healthy += 1
        except urllib.error.HTTPError as e:
            results.append({
                'name': site_name,
                'url': url,
                'status': e.code,
                'healthy': e.code < 500,
                'error': str(e.reason),
                'type': 'external'
            })
            if e.code < 500:
                healthy += 1
        except Exception as e:
            # Try HTTP if HTTPS fails
            try:
                url = f'http://{site_name}'
                req = urllib.request.Request(url, method='HEAD')
                response = urllib.request.urlopen(req, timeout=10)
                status = response.getcode()
                results.append({
                    'name': site_name,
                    'url': url,
                    'status': status,
                    'healthy': 200 <= status < 400,
                    'type': 'external',
                    'note': 'HTTP only'
                })
                if 200 <= status < 400:
                    healthy += 1
            except:
                results.append({
                    'name': site_name,
                    'url': f'https://{site_name}',
                    'status': 0,
                    'healthy': False,
                    'error': 'Connection failed',
                    'type': 'external'
                })
    
    return jsonify({
        'sites': results,
        'healthy': healthy,
        'total': total,
        'summary': f'{healthy}/{total}'
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
    
    services = {}
    TIMEOUT = 2  # 2 second timeout per service check
    
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
        debug_logger.track_websocket('connect', request.sid)
        emit('connected', {'status': 'connected', 'timestamp': datetime.now().isoformat()})

    @socketio.on('disconnect')
    def handle_disconnect():
        """Client disconnected"""
        debug_logger.track_websocket('disconnect', request.sid)

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
