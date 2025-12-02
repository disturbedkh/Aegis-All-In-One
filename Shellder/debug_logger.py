#!/usr/bin/env python3
"""
Shellder Comprehensive Debug Logger
====================================
Single unified debug log for AI-assisted debugging.
Captures ALL Shellder operations, system state, and client events.

Output: Shellder/debuglog.txt (always on)
"""

import os
import sys
import json
import time
import threading
import traceback
import functools
import inspect
import platform
import socket
from datetime import datetime
from pathlib import Path
from collections import deque

# =============================================================================
# CONFIGURATION
# =============================================================================

DEBUG_LOG_PATH = Path(__file__).parent / 'debuglog.txt'
MAX_LOG_SIZE_MB = 50  # Rotate after this size
MAX_LOG_LINES = 100000  # Keep last N lines on rotation
ENABLED = True  # Always on for debugging phase
LOG_FUNCTION_ARGS = True  # Log function arguments
LOG_FUNCTION_RESULTS = True  # Log function return values
LOG_SYSTEM_STATE_INTERVAL = 60  # Seconds between system state snapshots

# In-memory buffer for recent logs (for quick access)
_log_buffer = deque(maxlen=5000)
_lock = threading.Lock()
_start_time = time.time()

# =============================================================================
# CORE LOGGING
# =============================================================================

def _format_timestamp():
    """Format timestamp with milliseconds"""
    now = datetime.now()
    elapsed = time.time() - _start_time
    return f"{now.strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]} [+{elapsed:>10.3f}s]"

def _safe_repr(obj, max_len=500):
    """Safely convert object to string representation"""
    try:
        if obj is None:
            return 'None'
        if isinstance(obj, (str, int, float, bool)):
            s = repr(obj)
        elif isinstance(obj, bytes):
            s = f"<bytes len={len(obj)}>"
        elif isinstance(obj, dict):
            s = json.dumps(obj, default=str, ensure_ascii=False)
        elif isinstance(obj, (list, tuple)):
            s = json.dumps(list(obj)[:20], default=str) + (f"... ({len(obj)} items)" if len(obj) > 20 else "")
        else:
            s = repr(obj)
        
        if len(s) > max_len:
            s = s[:max_len] + f"... (truncated, {len(s)} chars)"
        return s
    except Exception as e:
        return f"<repr error: {e}>"

def _write_log(entry):
    """Write log entry to file and buffer"""
    if not ENABLED:
        return
    
    with _lock:
        _log_buffer.append(entry)
        
        try:
            # Check file size and rotate if needed
            if DEBUG_LOG_PATH.exists() and DEBUG_LOG_PATH.stat().st_size > MAX_LOG_SIZE_MB * 1024 * 1024:
                _rotate_log()
            
            with open(DEBUG_LOG_PATH, 'a', encoding='utf-8') as f:
                f.write(entry + '\n')
        except Exception as e:
            print(f"[DEBUG_LOGGER ERROR] Failed to write log: {e}", file=sys.stderr)

def _rotate_log():
    """Rotate log file, keeping last N lines"""
    try:
        if DEBUG_LOG_PATH.exists():
            with open(DEBUG_LOG_PATH, 'r', encoding='utf-8', errors='ignore') as f:
                lines = f.readlines()
            
            # Keep last N lines
            lines = lines[-MAX_LOG_LINES:]
            
            # Write rotated log
            with open(DEBUG_LOG_PATH, 'w', encoding='utf-8') as f:
                f.write(f"{'='*80}\n")
                f.write(f"LOG ROTATED AT {datetime.now().isoformat()}\n")
                f.write(f"Kept last {len(lines)} lines\n")
                f.write(f"{'='*80}\n\n")
                f.writelines(lines)
    except Exception as e:
        print(f"[DEBUG_LOGGER ERROR] Failed to rotate log: {e}", file=sys.stderr)

# =============================================================================
# PUBLIC LOGGING FUNCTIONS
# =============================================================================

def log(level, category, message, data=None, exc_info=False):
    """
    Main logging function
    
    Args:
        level: TRACE, DEBUG, INFO, WARN, ERROR, FATAL
        category: Component name (e.g., NAV, API, DOCKER, etc.)
        message: Human-readable message
        data: Optional dict/object with additional data
        exc_info: Include exception traceback
    """
    ts = _format_timestamp()
    
    # Format the log line
    parts = [ts, f"[{level:5s}]", f"[{category:12s}]", message]
    
    if data is not None:
        parts.append(f"| data={_safe_repr(data)}")
    
    if exc_info:
        parts.append(f"\n{''.join(traceback.format_exc())}")
    
    entry = ' '.join(parts)
    _write_log(entry)
    
    # Also print to console for immediate visibility
    if level in ('ERROR', 'FATAL', 'WARN'):
        print(entry, file=sys.stderr)

def trace(cat, msg, data=None): log('TRACE', cat, msg, data)
def debug(cat, msg, data=None): log('DEBUG', cat, msg, data)
def info(cat, msg, data=None): log('INFO', cat, msg, data)
def warn(cat, msg, data=None): log('WARN', cat, msg, data)
def error(cat, msg, data=None, exc_info=False): log('ERROR', cat, msg, data, exc_info)
def fatal(cat, msg, data=None, exc_info=True): log('FATAL', cat, msg, data, exc_info)

# =============================================================================
# FUNCTION DECORATOR FOR AUTO-LOGGING
# =============================================================================

def logged(category=None):
    """
    Decorator to automatically log function calls, arguments, and results.
    
    Usage:
        @logged('API')
        def my_function(arg1, arg2):
            ...
    """
    def decorator(func):
        cat = category or func.__module__.split('.')[-1].upper()
        
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            func_name = func.__name__
            
            # Log function entry
            if LOG_FUNCTION_ARGS:
                # Get argument names
                sig = inspect.signature(func)
                bound = sig.bind(*args, **kwargs)
                bound.apply_defaults()
                args_str = _safe_repr(dict(bound.arguments), max_len=300)
            else:
                args_str = f"({len(args)} args, {len(kwargs)} kwargs)"
            
            trace(cat, f"→ {func_name}() called", {'args': args_str})
            start_time = time.perf_counter()
            
            try:
                result = func(*args, **kwargs)
                duration = (time.perf_counter() - start_time) * 1000
                
                if LOG_FUNCTION_RESULTS:
                    result_str = _safe_repr(result, max_len=200)
                else:
                    result_str = type(result).__name__
                
                trace(cat, f"← {func_name}() returned [{duration:.2f}ms]", {'result': result_str})
                return result
                
            except Exception as e:
                duration = (time.perf_counter() - start_time) * 1000
                error(cat, f"✗ {func_name}() FAILED [{duration:.2f}ms]", {
                    'error': str(e),
                    'type': type(e).__name__
                }, exc_info=True)
                raise
        
        return wrapper
    return decorator

# =============================================================================
# SYSTEM STATE LOGGING
# =============================================================================

def log_system_state():
    """Log comprehensive system state snapshot"""
    try:
        import psutil
        psutil_available = True
    except ImportError:
        psutil_available = False
    
    state = {
        'timestamp': datetime.now().isoformat(),
        'uptime': time.time() - _start_time,
        'python': {
            'version': sys.version,
            'executable': sys.executable,
            'platform': sys.platform
        },
        'os': {
            'system': platform.system(),
            'release': platform.release(),
            'machine': platform.machine(),
            'hostname': socket.gethostname()
        },
        'process': {
            'pid': os.getpid(),
            'cwd': os.getcwd(),
            'user': os.environ.get('USER', os.environ.get('USERNAME', 'unknown'))
        }
    }
    
    if psutil_available:
        try:
            proc = psutil.Process()
            state['process'].update({
                'memory_mb': round(proc.memory_info().rss / 1024 / 1024, 2),
                'cpu_percent': proc.cpu_percent(),
                'threads': proc.num_threads(),
                'open_files': len(proc.open_files())
            })
            state['system'] = {
                'cpu_percent': psutil.cpu_percent(),
                'memory_percent': psutil.virtual_memory().percent,
                'disk_percent': psutil.disk_usage('/').percent
            }
        except Exception as e:
            state['psutil_error'] = str(e)
    
    info('SYSTEM', 'System state snapshot', state)
    return state

def log_docker_state():
    """Log Docker state"""
    try:
        import docker
        client = docker.from_env()
        
        containers = []
        for c in client.containers.list(all=True):
            containers.append({
                'name': c.name,
                'status': c.status,
                'image': c.image.tags[0] if c.image.tags else 'untagged'
            })
        
        info('DOCKER', f'Docker state: {len(containers)} containers', {
            'containers': containers,
            'version': client.version().get('Version', 'unknown')
        })
    except Exception as e:
        warn('DOCKER', f'Could not get Docker state: {e}')

def log_environment():
    """Log relevant environment variables"""
    relevant_vars = [
        'SHELLDER_PORT', 'AEGIS_ROOT', 'SHELLDER_LOCAL_MODE',
        'PUID', 'PGID', 'USER', 'HOME', 'PATH', 'PYTHONPATH',
        'DOCKER_HOST', 'DISPLAY', 'TERM'
    ]
    
    env = {k: os.environ.get(k, '<not set>') for k in relevant_vars}
    info('ENV', 'Environment variables', env)

# =============================================================================
# CLIENT LOG RECEIVER
# =============================================================================

def log_client_event(event_data):
    """Log event received from browser client"""
    info('CLIENT', 'Browser event received', event_data)

def log_client_logs(log_bundle):
    """
    Log a bundle of client-side logs received from browser.
    Writes each log entry with CLIENT prefix.
    """
    if not log_bundle:
        return
    
    info('CLIENT', f'=== Received {len(log_bundle.get("allLogs", []))} client logs ===')
    
    # Log state snapshot from client
    if 'state' in log_bundle:
        debug('CLIENT', 'Client state snapshot', log_bundle['state'])
    
    # Log individual entries
    for entry in log_bundle.get('allLogs', [])[-100:]:  # Last 100
        level = entry.get('level', 'DEBUG')
        cat = f"CLI/{entry.get('cat', 'UNK')}"
        msg = entry.get('msg', '')
        data = entry.get('data')
        
        log(level, cat[:12], msg, data)

# =============================================================================
# STARTUP
# =============================================================================

def initialize():
    """Initialize the debug logger - call at startup"""
    # Write header
    header = f"""
{'='*80}
SHELLDER DEBUG LOG
Started: {datetime.now().isoformat()}
PID: {os.getpid()}
Python: {sys.version.split()[0]}
Platform: {platform.platform()}
{'='*80}
"""
    _write_log(header)
    
    # Log initial state
    log_environment()
    log_system_state()
    
    info('LOGGER', 'Debug logger initialized', {
        'log_path': str(DEBUG_LOG_PATH),
        'max_size_mb': MAX_LOG_SIZE_MB,
        'log_args': LOG_FUNCTION_ARGS,
        'log_results': LOG_FUNCTION_RESULTS
    })
    
    # Start periodic system state logging
    def _periodic_state():
        while True:
            time.sleep(LOG_SYSTEM_STATE_INTERVAL)
            try:
                log_system_state()
            except Exception as e:
                error('LOGGER', f'Periodic state log failed: {e}')
    
    thread = threading.Thread(target=_periodic_state, daemon=True, name='DebugLogger-State')
    thread.start()

def get_recent_logs(count=100):
    """Get recent log entries from memory buffer"""
    with _lock:
        return list(_log_buffer)[-count:]

def get_log_path():
    """Get path to debug log file"""
    return str(DEBUG_LOG_PATH)

def clear_log():
    """Clear the debug log file"""
    with _lock:
        _log_buffer.clear()
        if DEBUG_LOG_PATH.exists():
            DEBUG_LOG_PATH.unlink()
        info('LOGGER', 'Debug log cleared')

# Auto-initialize when imported
initialize()

