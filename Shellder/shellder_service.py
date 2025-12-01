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

try:
    import eventlet
    eventlet.monkey_patch()
    ASYNC_MODE = 'eventlet'
except ImportError:
    ASYNC_MODE = 'threading'

# =============================================================================
# CONFIGURATION
# =============================================================================

SHELLDER_PORT = int(os.environ.get('SHELLDER_PORT', 5000))
AEGIS_ROOT = Path(os.environ.get('AEGIS_ROOT', '/aegis'))

# When running locally, find the root directory
if not AEGIS_ROOT.exists():
    SCRIPT_DIR = Path(__file__).parent
    AEGIS_ROOT = SCRIPT_DIR.parent

SHELLDER_DIR = AEGIS_ROOT / 'Shellder'
SHELLDER_DB = SHELLDER_DIR / 'shellder.db'
SHELLDER_LOG = SHELLDER_DIR / 'shellder.log'
TEMPLATES_DIR = SHELLDER_DIR / 'gui_templates'
STATIC_DIR = SHELLDER_DIR / 'gui_static'

# Data directories
DATA_DIR = Path('/app/data') if Path('/app/data').exists() else SHELLDER_DIR / 'data'
LOG_DIR = Path('/app/logs') if Path('/app/logs').exists() else SHELLDER_DIR / 'logs'

# Ensure directories exist
DATA_DIR.mkdir(exist_ok=True)
LOG_DIR.mkdir(exist_ok=True)

# =============================================================================
# FLASK APP SETUP
# =============================================================================

app = Flask(__name__,
            template_folder=str(TEMPLATES_DIR),
            static_folder=str(STATIC_DIR))
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'shellder-secret-key')
CORS(app)

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
# SQLITE DATABASE ACCESS
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

# Initialize database accessor
shellder_db = ShellderDB(SHELLDER_DB)

# =============================================================================
# STATS COLLECTOR (Real-time)
# =============================================================================

class StatsCollector:
    """Collects and stores live statistics"""
    
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
        
        # Xilriws log parser thread
        threading.Thread(target=self._parse_xilriws_logs, daemon=True).start()
        
        # Port scanner thread
        threading.Thread(target=self._scan_ports, daemon=True).start()
        
        # System services thread
        threading.Thread(target=self._check_system_services, daemon=True).start()
        
        print("Stats collector started")
    
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
            
            time.sleep(10)
    
    def _parse_xilriws_logs(self):
        """Parse Xilriws container logs for proxy statistics"""
        last_log_pos = 0
        
        while self.running:
            if docker_client:
                try:
                    container = docker_client.containers.get('xilriws')
                    if container.status != 'running':
                        time.sleep(30)
                        continue
                    
                    # Get recent logs
                    logs = container.logs(tail=500, timestamps=False).decode('utf-8', errors='ignore')
                    
                    # Parse proxy stats from logs
                    stats = {
                        'total_requests': 0,
                        'successful': 0,
                        'auth_banned': 0,
                        'invalid_credentials': 0,
                        'tunneling_errors': 0,
                        'code_15': 0,
                        'rate_limited': 0,
                        'timeouts': 0,
                        'connection_refused': 0,
                        'proxy_errors': 0,
                        'recent_errors': []
                    }
                    
                    for line in logs.split('\n'):
                        if not line.strip():
                            continue
                        
                        line_lower = line.lower()
                        
                        # Count successes
                        if 'success' in line_lower or 'got cookie' in line_lower or 'token obtained' in line_lower:
                            stats['successful'] += 1
                        
                        # Count specific errors (order matters - check most specific first)
                        if 'auth-banned' in line_lower or 'auth banned' in line_lower:
                            stats['auth_banned'] += 1
                        elif 'invalid' in line_lower and ('credential' in line_lower or 'password' in line_lower):
                            stats['invalid_credentials'] += 1
                        elif ('tunnel' in line_lower or 'connect' in line_lower) and 'error' in line_lower:
                            # Fixed: added parentheses for correct operator precedence
                            stats['tunneling_errors'] += 1
                        elif 'code 15' in line_lower or 'code:15' in line_lower or 'code: 15' in line_lower:
                            stats['code_15'] += 1
                        elif 'rate limit' in line_lower or 'ratelimit' in line_lower or '429' in line:
                            stats['rate_limited'] += 1
                        elif 'timeout' in line_lower or 'timed out' in line_lower:
                            stats['timeouts'] += 1
                        elif 'refused' in line_lower or 'connection refused' in line_lower:
                            stats['connection_refused'] += 1
                        elif 'proxy' in line_lower and ('error' in line_lower or 'fail' in line_lower):
                            stats['proxy_errors'] += 1
                        
                        # Track errors
                        if 'error' in line_lower or 'fail' in line_lower or 'banned' in line_lower:
                            stats['recent_errors'].append({
                                'time': datetime.now().isoformat(),
                                'message': line[:200]
                            })
                    
                    # Keep only last 50 errors
                    stats['recent_errors'] = stats['recent_errors'][-50:]
                    
                    # Calculate totals
                    stats['failed'] = (stats['auth_banned'] + stats['invalid_credentials'] + 
                                      stats['tunneling_errors'] + stats['code_15'] + 
                                      stats['rate_limited'] + stats['timeouts'] + 
                                      stats['connection_refused'] + stats['proxy_errors'])
                    stats['total_requests'] = stats['successful'] + stats['failed']
                    
                    # Calculate success rate
                    if stats['total_requests'] > 0:
                        stats['success_rate'] = round((stats['successful'] / stats['total_requests']) * 100, 1)
                    else:
                        stats['success_rate'] = 0
                    
                    with self.lock:
                        self.xilriws_stats = stats
                    
                    if socketio and SOCKETIO_AVAILABLE:
                        socketio.emit('xilriws_stats', stats)
                    
                except docker.errors.NotFound:
                    pass
                except Exception as e:
                    print(f"Error parsing Xilriws logs: {e}")
            
            time.sleep(10)
    
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
    """Serve static files"""
    return send_from_directory(str(STATIC_DIR), filename)

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

@app.route('/api/status')
def api_status():
    """Get overall system status"""
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
    stats = stats_collector.get_all_stats()
    return jsonify(list(stats.get('containers', {}).values()))

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
    proxy_file = AEGIS_ROOT / 'unown' / 'proxies.txt'
    if not proxy_file.exists():
        return jsonify({'exists': False, 'count': 0, 'proxies': []})
    
    try:
        with open(proxy_file, 'r') as f:
            lines = [l.strip() for l in f.readlines() if l.strip() and not l.startswith('#')]
        
        return jsonify({
            'exists': True,
            'count': len(lines),
            'sample': lines[:10] if len(lines) > 10 else lines,
            'file': str(proxy_file)
        })
    except Exception as e:
        return jsonify({'exists': False, 'error': str(e)})

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
# SYSTEM ENDPOINTS
# =============================================================================

@app.route('/api/ports')
def api_ports():
    """Get port status"""
    stats = stats_collector.get_all_stats()
    return jsonify(list(stats.get('ports', {}).values()))

@app.route('/api/services')
def api_services():
    """Get system services status"""
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
        print(f"Client connected: {request.sid}")
        emit('connected', {'status': 'connected', 'timestamp': datetime.now().isoformat()})

    @socketio.on('disconnect')
    def handle_disconnect():
        """Client disconnected"""
        print(f"Client disconnected: {request.sid}")

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

def main():
    print(f"""
╔═══════════════════════════════════════════════════════════════╗
║                 SHELLDER SERVICE v1.0                          ║
║                                                                 ║
║  Live Monitoring & Control Panel for Aegis AIO                  ║
╠═══════════════════════════════════════════════════════════════╣
║  Dashboard:    http://localhost:{SHELLDER_PORT}                            ║
║  API:          http://localhost:{SHELLDER_PORT}/api/                       ║
║  WebSocket:    ws://localhost:{SHELLDER_PORT}/socket.io/                   ║
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
╚═══════════════════════════════════════════════════════════════╝
    """)
    
    print(f"AEGIS_ROOT: {AEGIS_ROOT}")
    print(f"SHELLDER_DB: {SHELLDER_DB} (exists: {SHELLDER_DB.exists()})")
    print(f"Docker available: {DOCKER_AVAILABLE}")
    print(f"Docker client: {'connected' if docker_client else 'not connected'}")
    print(f"WebSocket: {SOCKETIO_AVAILABLE} (mode: {ASYNC_MODE})")
    print(f"psutil: {PSUTIL_AVAILABLE}")
    print()
    
    # Start stats collector
    stats_collector.start()
    
    # Run Flask with SocketIO
    if SOCKETIO_AVAILABLE:
        socketio.run(app, host='0.0.0.0', port=SHELLDER_PORT, debug=False)
    else:
        app.run(host='0.0.0.0', port=SHELLDER_PORT, debug=False)

if __name__ == '__main__':
    main()
