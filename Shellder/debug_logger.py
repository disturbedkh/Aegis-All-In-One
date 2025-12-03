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

# Determine log path - prefer /app/logs (Docker) or Shellder/logs (local)
_LOG_DIR = Path('/app/logs') if Path('/app/logs').exists() else Path(__file__).parent / 'logs'
_LOG_DIR.mkdir(exist_ok=True, parents=True)
DEBUG_LOG_PATH = _LOG_DIR / 'debuglog.txt'
MAX_LOG_SIZE_MB = 50  # Rotate after this size
MAX_LOG_LINES = 100000  # Keep last N lines on rotation
ENABLED = True  # Always on for debugging phase
LOG_FUNCTION_ARGS = True  # Log function arguments
LOG_FUNCTION_RESULTS = True  # Log function return values
LOG_SYSTEM_STATE_INTERVAL = 60  # Seconds between system state snapshots
LOG_HTTP_REQUESTS = True  # Log all HTTP requests
LOG_HTTP_RESPONSES = True  # Log HTTP response summaries
MAX_DATA_LEN = 1000  # Increase truncation limit for data

# In-memory buffer for recent logs (for quick access)
_log_buffer = deque(maxlen=5000)
_lock = threading.Lock()
_start_time = time.time()

# =============================================================================
# API ENDPOINT TRACKING (for detecting missing calls)
# =============================================================================

_api_call_counts = {}  # endpoint -> count
_api_last_called = {}  # endpoint -> timestamp
_expected_endpoints = [
    '/api/status',
    '/api/services', 
    '/api/metrics/sparklines',
    '/api/containers/updates',
    '/api/sites/check'
]
_websocket_connections = {}  # sid -> connection info
_client_sessions = {}  # IP -> session info
_client_versions = {}  # IP -> detected JS version info
_error_dedup = {}  # error_key -> {count, first_seen, last_seen}

# =============================================================================
# CORE LOGGING
# =============================================================================

def _format_timestamp():
    """Format timestamp with milliseconds"""
    now = datetime.now()
    elapsed = time.time() - _start_time
    return f"{now.strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]} [+{elapsed:>10.3f}s]"

def _safe_repr(obj, max_len=None):
    """Safely convert object to string representation"""
    if max_len is None:
        max_len = MAX_DATA_LEN
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
            s = json.dumps(list(obj)[:50], default=str) + (f"... ({len(obj)} items)" if len(obj) > 50 else "")
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

def log_client_logs(log_bundle, client_ip=None):
    """
    Log a bundle of client-side logs received from browser.
    Writes each log entry with CLIENT prefix.
    
    Features for AI debugging:
    - Detects client JS version from state
    - Deduplicates repeated errors (shows count instead of spam)
    - Warns about outdated client JS
    """
    global _client_versions, _error_dedup
    
    if not log_bundle:
        return
    
    all_logs = log_bundle.get('allLogs', [])
    info('CLIENT', f'=== Received {len(all_logs)} client logs ===')
    
    # Detect client JS version from state
    if 'state' in log_bundle:
        state = log_bundle['state']
        debug('CLIENT', 'Client state snapshot', state)
        
        # Check if client reports endpoints it's calling
        if client_ip and 'config' in state:
            config = state['config']
            # Track which endpoints the client thinks it should call
            if 'apiBase' in config:
                _client_versions[client_ip] = {
                    'last_seen': time.time(),
                    'has_services_call': '/api/services' in str(all_logs),
                    'has_sparklines_call': '/api/metrics/sparklines' in str(all_logs),
                    'user_agent': state.get('browser', {}).get('userAgent', 'unknown')
                }
    
    # Deduplicate and count errors
    error_counts = {}
    other_logs = []
    
    for entry in all_logs[-100:]:  # Last 100
        level = entry.get('level', 'DEBUG')
        msg = entry.get('msg', '')
        
        # Deduplicate errors and fatals
        if level in ('ERROR', 'FATAL'):
            # Create a key from the error message (first 100 chars)
            error_key = f"{level}:{msg[:100]}"
            error_counts[error_key] = error_counts.get(error_key, 0) + 1
        else:
            other_logs.append(entry)
    
    # Log deduplicated errors first (summarized)
    if error_counts:
        for error_key, count in error_counts.items():
            level, msg = error_key.split(':', 1)
            if count > 1:
                warn('CLI/ERROR', f'[x{count}] {msg}', {'repeated_count': count})
            else:
                log(level, 'CLI/ERROR', msg)
    
    # Log other entries
    for entry in other_logs:
        level = entry.get('level', 'DEBUG')
        cat = f"CLI/{entry.get('cat', 'UNK')}"
        msg = entry.get('msg', '')
        data = entry.get('data')
        
        log(level, cat[:12], msg, data)
    
    # Check if client is calling expected endpoints (detect old JS)
    all_logs_str = str(all_logs)
    missing_calls = []
    if '/api/status' in all_logs_str:  # Client is calling something
        if '/api/services' not in all_logs_str:
            missing_calls.append('/api/services')
        if '/api/metrics' not in all_logs_str:
            missing_calls.append('/api/metrics/sparklines')
    
    if missing_calls:
        warn('CLIENT', f'⚠️ Client NOT calling expected endpoints (OLD JS?)', {
            'missing': missing_calls,
            'advice': 'Client may have old cached JavaScript. User needs Ctrl+F5.',
            'client_ip': client_ip
        })

# =============================================================================
# HTTP REQUEST/RESPONSE LOGGING
# =============================================================================

_request_start_times = {}
_error_counts = {}  # Track error frequencies to reduce spam
_last_error_log = {}  # Timestamp of last log for each error type

# Expected static file sizes (for cache debugging)
EXPECTED_STATIC_FILES = {
    'script.js': {'min_size': 145000, 'description': 'Main JavaScript'},
    'style.css': {'min_size': 60000, 'description': 'Main stylesheet'}
}

def log_http_request(request):
    """Log incoming HTTP request - call from Flask before_request"""
    if not LOG_HTTP_REQUESTS:
        return
    
    request_id = id(request)
    _request_start_times[request_id] = time.time()
    
    # Track API calls for statistics (only /api/ paths)
    if request.path.startswith('/api/'):
        track_api_call(request.path, request.remote_addr)
    
    # Log cache-related headers for static files (helps debug 304 issues)
    cache_headers = {}
    if request.path.startswith('/static/'):
        cache_headers = {
            'if_none_match': request.headers.get('If-None-Match'),
            'if_modified_since': request.headers.get('If-Modified-Since'),
            'cache_control': request.headers.get('Cache-Control')
        }
    
    info('HTTP_REQ', f'{request.method} {request.path}', {
        'method': request.method,
        'path': request.path,
        'query': request.query_string.decode('utf-8', errors='ignore')[:200] if request.query_string else None,
        'remote_addr': request.remote_addr,
        'user_agent': request.headers.get('User-Agent', '')[:100],
        'content_type': request.content_type,
        'content_length': request.content_length,
        **cache_headers
    })

def log_http_response(response, request):
    """Log HTTP response - call from Flask after_request"""
    if not LOG_HTTP_RESPONSES:
        return response
    
    request_id = id(request)
    start_time = _request_start_times.pop(request_id, None)
    duration_ms = (time.time() - start_time) * 1000 if start_time else 0
    
    level = 'DEBUG' if response.status_code < 400 else 'WARN' if response.status_code < 500 else 'ERROR'
    
    extra_data = {}
    
    # Special handling for static files - detect caching issues
    if request.path.startswith('/static/'):
        filename = request.path.split('/')[-1]
        
        # Check for 304 responses (cached) - this is often a problem!
        if response.status_code == 304:
            warn('CACHE', f'⚠️ 304 NOT MODIFIED for {filename} - client using cached version!', {
                'file': filename,
                'client_has_etag': request.headers.get('If-None-Match'),
                'advice': 'Client may have old JS. User should Ctrl+F5 to force refresh.'
            })
        
        # Check if served file size matches expected
        if filename in EXPECTED_STATIC_FILES and response.content_length:
            expected = EXPECTED_STATIC_FILES[filename]
            if response.content_length < expected['min_size']:
                warn('CACHE', f'⚠️ {filename} smaller than expected ({response.content_length} < {expected["min_size"]})', {
                    'file': filename,
                    'actual_size': response.content_length,
                    'expected_min': expected['min_size']
                })
        
        extra_data['etag'] = response.headers.get('ETag')
        extra_data['cache_control'] = response.headers.get('Cache-Control')
    
    log(level, 'HTTP_RES', f'{request.method} {request.path} → {response.status_code} [{duration_ms:.1f}ms]', {
        'status': response.status_code,
        'status_text': response.status,
        'duration_ms': round(duration_ms, 2),
        'content_type': response.content_type,
        'content_length': response.content_length,
        **extra_data
    })
    
    return response

def log_http_error(error, request):
    """Log HTTP error - call from Flask error handlers"""
    request_id = id(request)
    start_time = _request_start_times.pop(request_id, None)
    duration_ms = (time.time() - start_time) * 1000 if start_time else 0
    
    error_code = getattr(error, 'code', 500)
    error('HTTP_ERR', f'{request.method} {request.path} → {error_code} [{duration_ms:.1f}ms]', {
        'error_type': type(error).__name__,
        'error_msg': str(error),
        'duration_ms': round(duration_ms, 2),
        'path': request.path,
        'remote_addr': request.remote_addr
    }, exc_info=True)

# =============================================================================
# STARTUP
# =============================================================================

def initialize(fresh_start=True):
    """Initialize the debug logger - call at startup
    
    Args:
        fresh_start: If True, clears existing log file for a clean session
    """
    global _start_time
    _start_time = time.time()
    
    # Clear existing log on fresh start (new launch/git pull)
    if fresh_start:
        with _lock:
            _log_buffer.clear()
            if DEBUG_LOG_PATH.exists():
                try:
                    # Keep a backup of the last log
                    backup_path = DEBUG_LOG_PATH.with_suffix('.txt.bak')
                    DEBUG_LOG_PATH.rename(backup_path)
                except Exception:
                    # If rename fails, just truncate
                    DEBUG_LOG_PATH.unlink(missing_ok=True)
    
    # Write header
    header = f"""
{'='*80}
SHELLDER DEBUG LOG
Started: {datetime.now().isoformat()}
PID: {os.getpid()}
Python: {sys.version.split()[0]}
Platform: {platform.platform()}
Session: {'FRESH START' if fresh_start else 'CONTINUING'}
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
        'log_results': LOG_FUNCTION_RESULTS,
        'log_http': LOG_HTTP_REQUESTS
    })
    
    # Start periodic system state logging
    def _periodic_state():
        iteration = 0
        while True:
            time.sleep(LOG_SYSTEM_STATE_INTERVAL)
            try:
                iteration += 1
                log_system_state()
                
                # Every 5 minutes, log a summary
                if iteration % 5 == 0:
                    log_summary()
            except Exception as e:
                error('LOGGER', f'Periodic state log failed: {e}')
    
    thread = threading.Thread(target=_periodic_state, daemon=True, name='DebugLogger-State')
    thread.start()

def track_api_call(endpoint, remote_addr=None):
    """Track an API endpoint call for statistics"""
    global _api_call_counts, _api_last_called, _client_sessions
    
    now = time.time()
    _api_call_counts[endpoint] = _api_call_counts.get(endpoint, 0) + 1
    _api_last_called[endpoint] = now
    
    # Track client sessions
    if remote_addr:
        if remote_addr not in _client_sessions:
            _client_sessions[remote_addr] = {
                'first_seen': now,
                'request_count': 0,
                'endpoints': set()
            }
        _client_sessions[remote_addr]['request_count'] += 1
        _client_sessions[remote_addr]['last_seen'] = now
        _client_sessions[remote_addr]['endpoints'].add(endpoint)

def track_websocket(event, sid, data=None):
    """Track WebSocket connection events"""
    global _websocket_connections
    
    now = time.time()
    if event == 'connect':
        _websocket_connections[sid] = {
            'connected_at': now,
            'messages_sent': 0,
            'messages_received': 0
        }
        info('WEBSOCKET', f'Client connected: {sid}', {'total_connections': len(_websocket_connections)})
    elif event == 'disconnect':
        if sid in _websocket_connections:
            duration = now - _websocket_connections[sid]['connected_at']
            info('WEBSOCKET', f'Client disconnected: {sid}', {
                'duration_s': round(duration, 1),
                'messages_sent': _websocket_connections[sid]['messages_sent'],
                'messages_received': _websocket_connections[sid]['messages_received']
            })
            del _websocket_connections[sid]
    elif event == 'message':
        if sid in _websocket_connections:
            _websocket_connections[sid]['messages_received'] += 1

def get_missing_endpoints():
    """Check which expected endpoints haven't been called recently"""
    now = time.time()
    missing = []
    stale = []  # Called but not recently (>5 minutes)
    
    for endpoint in _expected_endpoints:
        if endpoint not in _api_last_called:
            missing.append(endpoint)
        elif now - _api_last_called[endpoint] > 300:  # 5 minutes
            stale.append({
                'endpoint': endpoint,
                'last_called_ago_s': round(now - _api_last_called[endpoint], 1)
            })
    
    return {'never_called': missing, 'stale': stale}

def get_client_summary():
    """Get summary of connected clients"""
    now = time.time()
    active = []
    for ip, session in _client_sessions.items():
        if now - session.get('last_seen', 0) < 60:  # Active in last minute
            active.append({
                'ip': ip,
                'requests': session['request_count'],
                'endpoints': list(session['endpoints'])[:5],
                'session_duration_s': round(now - session['first_seen'], 1)
            })
    return active

def log_summary():
    """Log a comprehensive summary of recent activity"""
    with _lock:
        recent = list(_log_buffer)[-500:]
    
    # Count by level
    level_counts = {}
    category_counts = {}
    for entry in recent:
        # Parse level and category from log entry
        if '[INFO ]' in entry: level_counts['INFO'] = level_counts.get('INFO', 0) + 1
        elif '[DEBUG]' in entry: level_counts['DEBUG'] = level_counts.get('DEBUG', 0) + 1
        elif '[WARN ]' in entry: level_counts['WARN'] = level_counts.get('WARN', 0) + 1
        elif '[ERROR]' in entry: level_counts['ERROR'] = level_counts.get('ERROR', 0) + 1
        elif '[TRACE]' in entry: level_counts['TRACE'] = level_counts.get('TRACE', 0) + 1
        
        # Extract category
        if '[HTTP_REQ' in entry: category_counts['HTTP'] = category_counts.get('HTTP', 0) + 1
        elif '[API' in entry: category_counts['API'] = category_counts.get('API', 0) + 1
        elif '[CLIENT' in entry: category_counts['CLIENT'] = category_counts.get('CLIENT', 0) + 1
    
    # Check for missing endpoints
    missing = get_missing_endpoints()
    
    # Get client summary
    clients = get_client_summary()
    
    # Top endpoints by call count
    top_endpoints = sorted(_api_call_counts.items(), key=lambda x: x[1], reverse=True)[:10]
    
    info('SUMMARY', f'=== PERIODIC SUMMARY ({len(recent)} recent entries) ===', {
        'by_level': level_counts,
        'by_category': category_counts,
        'total_buffer_entries': len(_log_buffer),
        'log_file_size_kb': round(DEBUG_LOG_PATH.stat().st_size / 1024, 1) if DEBUG_LOG_PATH.exists() else 0,
        'uptime_minutes': round((time.time() - _start_time) / 60, 1)
    })
    
    # Log endpoint stats
    info('ENDPOINTS', 'API endpoint call counts', {
        'top_10': dict(top_endpoints),
        'total_unique': len(_api_call_counts)
    })
    
    # Log missing/stale endpoints (important for debugging!)
    if missing['never_called'] or missing['stale']:
        warn('ENDPOINTS', '⚠️ Expected endpoints not called', missing)
    
    # Log active clients
    if clients:
        info('CLIENTS', f'{len(clients)} active client(s)', {'clients': clients})
    
    # Log WebSocket status
    info('WEBSOCKET', f'{len(_websocket_connections)} active WebSocket connection(s)')
    
    # Log client version status (helps detect old cached JS)
    if _client_versions:
        outdated_clients = []
        for ip, info_data in _client_versions.items():
            if not info_data.get('has_services_call'):
                outdated_clients.append(ip)
        
        if outdated_clients:
            warn('CACHE', f'⚠️ {len(outdated_clients)} client(s) may have outdated JS', {
                'outdated_ips': outdated_clients,
                'advice': 'These clients are not calling /api/services - likely old cached JS'
            })
    
    # Log any cache-related warnings from recent logs
    cache_warnings = sum(1 for entry in recent if '[CACHE' in entry and 'WARN' in entry)
    if cache_warnings:
        warn('CACHE', f'⚠️ {cache_warnings} cache-related warnings in last {len(recent)} entries')

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

