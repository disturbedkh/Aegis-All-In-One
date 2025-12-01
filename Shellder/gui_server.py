#!/usr/bin/env python3
"""
Shellder GUI Server
A web-based interface for managing Aegis AIO through Shellder

Run with: python3 Shellder/gui_server.py
Access at: http://localhost:5000
"""

import os
import sys
import json
import subprocess
import threading
import time
import signal
from datetime import datetime
from pathlib import Path

try:
    from flask import Flask, render_template, jsonify, request, Response
    from flask_cors import CORS
except ImportError:
    print("Installing required packages...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "flask", "flask-cors", "-q"])
    from flask import Flask, render_template, jsonify, request, Response
    from flask_cors import CORS

# Get the Shellder directory
SHELLDER_DIR = Path(__file__).parent
ROOT_DIR = SHELLDER_DIR.parent
TEMPLATES_DIR = SHELLDER_DIR / "gui_templates"
STATIC_DIR = SHELLDER_DIR / "gui_static"

app = Flask(__name__, 
            template_folder=str(TEMPLATES_DIR),
            static_folder=str(STATIC_DIR))
CORS(app)

# Store running processes
running_processes = {}

def get_docker_status():
    """Get status of Docker containers"""
    try:
        result = subprocess.run(
            ["docker", "ps", "-a", "--format", "{{.Names}}|{{.Status}}|{{.State}}"],
            capture_output=True, text=True, timeout=10
        )
        containers = []
        for line in result.stdout.strip().split('\n'):
            if line and '|' in line:
                parts = line.split('|')
                if len(parts) >= 3:
                    containers.append({
                        'name': parts[0],
                        'status': parts[1],
                        'state': parts[2]
                    })
        return containers
    except Exception as e:
        return []

def get_system_info():
    """Get system information"""
    info = {}
    
    # Memory
    try:
        result = subprocess.run(["free", "-h"], capture_output=True, text=True, timeout=5)
        lines = result.stdout.strip().split('\n')
        if len(lines) > 1:
            parts = lines[1].split()
            info['memory'] = {
                'total': parts[1] if len(parts) > 1 else 'N/A',
                'used': parts[2] if len(parts) > 2 else 'N/A',
                'free': parts[3] if len(parts) > 3 else 'N/A'
            }
    except:
        info['memory'] = {'total': 'N/A', 'used': 'N/A', 'free': 'N/A'}
    
    # Disk
    try:
        result = subprocess.run(["df", "-h", str(ROOT_DIR)], capture_output=True, text=True, timeout=5)
        lines = result.stdout.strip().split('\n')
        if len(lines) > 1:
            parts = lines[1].split()
            info['disk'] = {
                'total': parts[1] if len(parts) > 1 else 'N/A',
                'used': parts[2] if len(parts) > 2 else 'N/A',
                'free': parts[3] if len(parts) > 3 else 'N/A',
                'percent': parts[4] if len(parts) > 4 else 'N/A'
            }
    except:
        info['disk'] = {'total': 'N/A', 'used': 'N/A', 'free': 'N/A', 'percent': 'N/A'}
    
    # Uptime
    try:
        result = subprocess.run(["uptime", "-p"], capture_output=True, text=True, timeout=5)
        info['uptime'] = result.stdout.strip()
    except:
        info['uptime'] = 'N/A'
    
    return info

def read_shellder_log(lines=50):
    """Read recent lines from shellder.log"""
    log_file = SHELLDER_DIR / "shellder.log"
    if not log_file.exists():
        return []
    
    try:
        with open(log_file, 'r') as f:
            all_lines = f.readlines()
            return all_lines[-lines:]
    except:
        return []

def check_env_file():
    """Check if .env file exists and get key values"""
    env_file = ROOT_DIR / ".env"
    if not env_file.exists():
        return None
    
    env_vars = {}
    try:
        with open(env_file, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    # Don't expose passwords
                    if 'PASSWORD' in key or 'SECRET' in key or 'TOKEN' in key:
                        env_vars[key] = '********'
                    else:
                        env_vars[key] = value.strip('"\'')
        return env_vars
    except:
        return None

# =============================================================================
# ROUTES
# =============================================================================

@app.route('/')
def index():
    """Main dashboard"""
    return render_template('index.html')

@app.route('/api/status')
def api_status():
    """Get overall system status"""
    containers = get_docker_status()
    system = get_system_info()
    env = check_env_file()
    
    # Count container states
    running = sum(1 for c in containers if c['state'] == 'running')
    stopped = len(containers) - running
    
    return jsonify({
        'containers': {
            'total': len(containers),
            'running': running,
            'stopped': stopped,
            'list': containers
        },
        'system': system,
        'env_configured': env is not None,
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/containers')
def api_containers():
    """Get detailed container status"""
    return jsonify(get_docker_status())

@app.route('/api/container/<name>/logs')
def api_container_logs(name):
    """Get logs for a specific container"""
    lines = request.args.get('lines', 100, type=int)
    try:
        result = subprocess.run(
            ["docker", "logs", "--tail", str(lines), name],
            capture_output=True, text=True, timeout=30
        )
        return jsonify({
            'container': name,
            'logs': result.stdout + result.stderr,
            'success': True
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/container/<name>/<action>', methods=['POST'])
def api_container_action(name, action):
    """Perform action on container (start/stop/restart)"""
    if action not in ['start', 'stop', 'restart']:
        return jsonify({'success': False, 'error': 'Invalid action'})
    
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
    """Docker compose actions (up/down/restart)"""
    os.chdir(ROOT_DIR)
    
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
            cwd=str(ROOT_DIR)
        )
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/logs/shellder')
def api_shellder_logs():
    """Get Shellder operation logs"""
    lines = request.args.get('lines', 100, type=int)
    logs = read_shellder_log(lines)
    return jsonify({
        'logs': ''.join(logs),
        'lines': len(logs)
    })

@app.route('/api/script/<script>', methods=['POST'])
def api_run_script(script):
    """Run a Shellder script"""
    allowed_scripts = [
        'setup.sh', 'check.sh', 'dbsetup.sh', 'logs.sh',
        'nginx-setup.sh', 'files.sh', 'poracle.sh', 'fletchling.sh'
    ]
    
    if script not in allowed_scripts:
        return jsonify({'success': False, 'error': 'Script not allowed'})
    
    script_path = SHELLDER_DIR / script
    if not script_path.exists():
        return jsonify({'success': False, 'error': 'Script not found'})
    
    # Note: This would need to run in a terminal for interactive scripts
    return jsonify({
        'success': True,
        'message': f'Script {script} queued. For interactive scripts, use terminal.',
        'command': f'sudo bash Shellder/{script}'
    })

@app.route('/api/env')
def api_env():
    """Get environment configuration (sanitized)"""
    env = check_env_file()
    return jsonify({
        'configured': env is not None,
        'variables': env or {}
    })

@app.route('/api/git/status')
def api_git_status():
    """Get git status"""
    try:
        # Check if behind
        subprocess.run(["git", "fetch"], capture_output=True, timeout=30, cwd=str(ROOT_DIR))
        
        result = subprocess.run(
            ["git", "status", "-sb"],
            capture_output=True, text=True, timeout=10,
            cwd=str(ROOT_DIR)
        )
        
        behind = 'behind' in result.stdout
        ahead = 'ahead' in result.stdout
        
        return jsonify({
            'status': result.stdout,
            'behind': behind,
            'ahead': ahead,
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
            cwd=str(ROOT_DIR)
        )
        return jsonify({
            'success': result.returncode == 0,
            'output': result.stdout + result.stderr
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

# =============================================================================
# MAIN
# =============================================================================

def main():
    print("""
╔═══════════════════════════════════════════════════════════════╗
║                    SHELLDER GUI SERVER                         ║
║                                                                 ║
║  Access the dashboard at: http://localhost:5000                 ║
║  Or from network: http://<your-ip>:5000                         ║
║                                                                 ║
║  Press Ctrl+C to stop the server                                ║
╚═══════════════════════════════════════════════════════════════╝
    """)
    
    # Ensure template and static directories exist
    TEMPLATES_DIR.mkdir(exist_ok=True)
    STATIC_DIR.mkdir(exist_ok=True)
    
    app.run(host='0.0.0.0', port=5000, debug=False)

if __name__ == '__main__':
    main()

