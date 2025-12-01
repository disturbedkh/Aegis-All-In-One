#!/usr/bin/env python3
"""
Shellder Service - Live Monitoring & Control Panel for Aegis AIO
=================================================================

Features:
- Web Dashboard (GUI) on port 5000
- Real-time container stats via WebSocket
- Xilriws proxy monitoring and stats
- Log aggregation and streaming
- System resource monitoring

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
from datetime import datetime, timedelta
from pathlib import Path
from collections import defaultdict

# Flask and WebSocket
from flask import Flask, render_template, jsonify, request, Response
from flask_cors import CORS
from flask_socketio import SocketIO, emit

# Docker and System
try:
    import docker
    DOCKER_AVAILABLE = True
except ImportError:
    DOCKER_AVAILABLE = False

try:
    import psutil
    PSUTIL_AVAILABLE = True
except ImportError:
    PSUTIL_AVAILABLE = False

import requests

# =============================================================================
# CONFIGURATION
# =============================================================================

SHELLDER_PORT = int(os.environ.get('SHELLDER_PORT', 5000))
AEGIS_ROOT = os.environ.get('AEGIS_ROOT', '/aegis')
DATA_DIR = Path('/app/data')
LOG_DIR = Path('/app/logs')

# Ensure directories exist
DATA_DIR.mkdir(exist_ok=True)
LOG_DIR.mkdir(exist_ok=True)

# =============================================================================
# FLASK APP SETUP
# =============================================================================

app = Flask(__name__,
            template_folder='gui_templates',
            static_folder='gui_static')
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'shellder-secret-key')
CORS(app)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='eventlet')

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
# STATS STORAGE (In-memory with periodic persistence)
# =============================================================================

class StatsCollector:
    """Collects and stores live statistics"""
    
    def __init__(self):
        self.container_stats = {}
        self.xilriws_stats = {
            'total_requests': 0,
            'successful': 0,
            'failed': 0,
            'by_proxy': defaultdict(lambda: {'requests': 0, 'success': 0, 'fail': 0}),
            'recent_errors': [],
            'requests_per_minute': []
        }
        self.system_stats = {}
        self.log_stats = defaultdict(lambda: {'errors': 0, 'warnings': 0, 'lines': 0})
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
        
        print("Stats collector started")
    
    def stop(self):
        self.running = False
    
    def _collect_container_stats(self):
        """Collect Docker container statistics"""
        while self.running:
            if docker_client:
                try:
                    containers = docker_client.containers.list(all=True)
                    stats = {}
                    
                    for container in containers:
                        try:
                            container_stats = container.stats(stream=False)
                            
                            # Calculate CPU usage
                            cpu_delta = container_stats['cpu_stats']['cpu_usage']['total_usage'] - \
                                       container_stats['precpu_stats']['cpu_usage']['total_usage']
                            system_delta = container_stats['cpu_stats']['system_cpu_usage'] - \
                                          container_stats['precpu_stats']['system_cpu_usage']
                            cpu_percent = 0.0
                            if system_delta > 0:
                                cpu_percent = (cpu_delta / system_delta) * 100.0
                            
                            # Calculate memory usage
                            mem_usage = container_stats['memory_stats'].get('usage', 0)
                            mem_limit = container_stats['memory_stats'].get('limit', 1)
                            mem_percent = (mem_usage / mem_limit) * 100.0
                            
                            stats[container.name] = {
                                'name': container.name,
                                'status': container.status,
                                'cpu_percent': round(cpu_percent, 2),
                                'memory_usage': mem_usage,
                                'memory_limit': mem_limit,
                                'memory_percent': round(mem_percent, 2),
                                'image': container.image.tags[0] if container.image.tags else 'unknown'
                            }
                        except Exception as e:
                            stats[container.name] = {
                                'name': container.name,
                                'status': container.status,
                                'error': str(e)
                            }
                    
                    with self.lock:
                        self.container_stats = stats
                    
                    # Emit to connected clients
                    socketio.emit('container_stats', stats)
                    
                except Exception as e:
                    print(f"Error collecting container stats: {e}")
            
            time.sleep(5)  # Update every 5 seconds
    
    def _collect_system_stats(self):
        """Collect system resource statistics"""
        while self.running:
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
                        'timestamp': datetime.now().isoformat()
                    }
                    
                    with self.lock:
                        self.system_stats = stats
                    
                    socketio.emit('system_stats', stats)
                    
                except Exception as e:
                    print(f"Error collecting system stats: {e}")
            
            time.sleep(10)  # Update every 10 seconds
    
    def _parse_xilriws_logs(self):
        """Parse Xilriws container logs for proxy statistics"""
        last_timestamp = datetime.now()
        
        while self.running:
            if docker_client:
                try:
                    # Get xilriws container
                    try:
                        container = docker_client.containers.get('xilriws')
                    except docker.errors.NotFound:
                        time.sleep(30)
                        continue
                    
                    if container.status != 'running':
                        time.sleep(30)
                        continue
                    
                    # Get recent logs
                    logs = container.logs(since=last_timestamp, timestamps=True).decode('utf-8', errors='ignore')
                    last_timestamp = datetime.now()
                    
                    # Parse proxy stats from logs
                    for line in logs.split('\n'):
                        if not line:
                            continue
                        
                        # Parse proxy request patterns
                        # Example: [2024-01-01 12:00:00] proxy1: request success
                        proxy_match = re.search(r'proxy[_-]?(\d+|[a-zA-Z]+)', line, re.IGNORECASE)
                        
                        with self.lock:
                            self.xilriws_stats['total_requests'] += 1
                            
                            if 'success' in line.lower() or 'ok' in line.lower() or '200' in line:
                                self.xilriws_stats['successful'] += 1
                                if proxy_match:
                                    proxy_name = proxy_match.group(0)
                                    self.xilriws_stats['by_proxy'][proxy_name]['success'] += 1
                                    self.xilriws_stats['by_proxy'][proxy_name]['requests'] += 1
                            
                            elif 'error' in line.lower() or 'fail' in line.lower() or '4' in line[:3] or '5' in line[:3]:
                                self.xilriws_stats['failed'] += 1
                                if proxy_match:
                                    proxy_name = proxy_match.group(0)
                                    self.xilriws_stats['by_proxy'][proxy_name]['fail'] += 1
                                    self.xilriws_stats['by_proxy'][proxy_name]['requests'] += 1
                                
                                # Track recent errors
                                self.xilriws_stats['recent_errors'].append({
                                    'time': datetime.now().isoformat(),
                                    'message': line[:200]
                                })
                                # Keep only last 50 errors
                                self.xilriws_stats['recent_errors'] = self.xilriws_stats['recent_errors'][-50:]
                    
                    # Emit xilriws stats
                    socketio.emit('xilriws_stats', dict(self.xilriws_stats))
                    
                except Exception as e:
                    print(f"Error parsing Xilriws logs: {e}")
            
            time.sleep(5)  # Check every 5 seconds
    
    def get_all_stats(self):
        """Get all collected statistics"""
        with self.lock:
            return {
                'containers': self.container_stats,
                'system': self.system_stats,
                'xilriws': dict(self.xilriws_stats),
                'logs': dict(self.log_stats)
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
    if not docker_client:
        return "Docker not available"
    
    try:
        container = docker_client.containers.get(container_name)
        logs = container.logs(tail=lines, timestamps=True).decode('utf-8', errors='ignore')
        return logs
    except Exception as e:
        return f"Error: {str(e)}"

# =============================================================================
# API ROUTES
# =============================================================================

@app.route('/')
def index():
    """Main dashboard"""
    return render_template('index.html')

@app.route('/api/health')
def health():
    """Health check endpoint"""
    return jsonify({
        'status': 'healthy',
        'timestamp': datetime.now().isoformat(),
        'docker': docker_client is not None,
        'version': '1.0'
    })

@app.route('/api/status')
def api_status():
    """Get overall system status"""
    stats = stats_collector.get_all_stats()
    
    containers = []
    running = 0
    stopped = 0
    
    if docker_client:
        try:
            for container in docker_client.containers.list(all=True):
                containers.append({
                    'name': container.name,
                    'status': container.status,
                    'state': container.status
                })
                if container.status == 'running':
                    running += 1
                else:
                    stopped += 1
        except Exception as e:
            print(f"Error getting containers: {e}")
    
    # System info
    system = {}
    if PSUTIL_AVAILABLE:
        mem = psutil.virtual_memory()
        disk = psutil.disk_usage('/')
        system = {
            'memory': {
                'total': format_bytes(mem.total),
                'used': format_bytes(mem.used),
                'free': format_bytes(mem.available)
            },
            'disk': {
                'total': format_bytes(disk.total),
                'used': format_bytes(disk.used),
                'free': format_bytes(disk.free),
                'percent': f"{disk.percent}%"
            },
            'uptime': 'N/A'
        }
    
    return jsonify({
        'containers': {
            'total': len(containers),
            'running': running,
            'stopped': stopped,
            'list': containers
        },
        'system': system,
        'env_configured': True,
        'xilriws': stats.get('xilriws', {}),
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/containers')
def api_containers():
    """Get detailed container status"""
    containers = []
    if docker_client:
        try:
            for container in docker_client.containers.list(all=True):
                containers.append({
                    'name': container.name,
                    'status': container.short_id,
                    'state': container.status
                })
        except Exception as e:
            pass
    return jsonify(containers)

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

@app.route('/api/container/<name>/<action>', methods=['POST'])
def api_container_action(name, action):
    """Perform action on container"""
    if action not in ['start', 'stop', 'restart']:
        return jsonify({'success': False, 'error': 'Invalid action'})
    
    if not docker_client:
        return jsonify({'success': False, 'error': 'Docker not available'})
    
    try:
        container = docker_client.containers.get(name)
        getattr(container, action)()
        return jsonify({'success': True, 'message': f'{name} {action}ed'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/docker/<action>', methods=['POST'])
def api_docker_action(action):
    """Docker compose actions"""
    import subprocess
    
    aegis_root = os.environ.get('AEGIS_ROOT', '/aegis')
    
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
            cwd=aegis_root
        )
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/xilriws/stats')
def api_xilriws_stats():
    """Get Xilriws proxy statistics"""
    stats = stats_collector.get_all_stats()
    return jsonify(stats.get('xilriws', {}))

@app.route('/api/xilriws/live')
def api_xilriws_live():
    """Stream Xilriws logs in real-time"""
    def generate():
        if not docker_client:
            yield "data: Docker not available\n\n"
            return
        
        try:
            container = docker_client.containers.get('xilriws')
            for log in container.logs(stream=True, follow=True, tail=10):
                yield f"data: {log.decode('utf-8', errors='ignore')}\n\n"
        except Exception as e:
            yield f"data: Error: {str(e)}\n\n"
    
    return Response(generate(), mimetype='text/event-stream')

@app.route('/api/logs/shellder')
def api_shellder_logs():
    """Get Shellder operation logs"""
    log_file = Path(AEGIS_ROOT) / 'Shellder' / 'shellder.log'
    lines = request.args.get('lines', 100, type=int)
    
    if log_file.exists():
        try:
            with open(log_file, 'r') as f:
                all_lines = f.readlines()
                return jsonify({
                    'logs': ''.join(all_lines[-lines:]),
                    'lines': len(all_lines[-lines:])
                })
        except Exception as e:
            return jsonify({'logs': f'Error reading log: {e}', 'lines': 0})
    
    return jsonify({'logs': 'Log file not found', 'lines': 0})

@app.route('/api/stats/live')
def api_stats_live():
    """Get all live statistics"""
    return jsonify(stats_collector.get_all_stats())

# =============================================================================
# WEBSOCKET EVENTS
# =============================================================================

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
    else:
        emit('all_stats', stats)

# =============================================================================
# MAIN
# =============================================================================

def main():
    print("""
╔═══════════════════════════════════════════════════════════════╗
║                 SHELLDER SERVICE                               ║
║                                                                 ║
║  Live Monitoring & Control Panel for Aegis AIO                  ║
╠═══════════════════════════════════════════════════════════════╣
║  Dashboard:    http://localhost:5000                            ║
║  API:          http://localhost:5000/api/                       ║
║  WebSocket:    ws://localhost:5000/socket.io/                   ║
╚═══════════════════════════════════════════════════════════════╝
    """)
    
    # Start stats collector
    stats_collector.start()
    
    # Run Flask with SocketIO
    socketio.run(app, host='0.0.0.0', port=SHELLDER_PORT, debug=False)

if __name__ == '__main__':
    main()

