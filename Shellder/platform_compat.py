#!/usr/bin/env python3
"""
Platform Compatibility Layer for Shellder
==========================================

This module provides cross-platform abstractions for Unix-specific functionality,
allowing Shellder to run on both Linux and Windows.

Usage:
    from platform_compat import (
        IS_WINDOWS, IS_LINUX, IS_MACOS,
        get_current_user, get_current_uid, get_current_gid,
        get_user_by_uid, get_group_by_gid,
        is_admin, can_use_pty,
        safe_chown, safe_chmod,
        run_privileged_command
    )
"""

import os
import sys
import platform
import subprocess
import getpass
from pathlib import Path

# =============================================================================
# PLATFORM DETECTION
# =============================================================================

IS_WINDOWS = sys.platform == 'win32'
IS_LINUX = sys.platform.startswith('linux')
IS_MACOS = sys.platform == 'darwin'
IS_UNIX = IS_LINUX or IS_MACOS

PLATFORM_NAME = platform.system()  # 'Windows', 'Linux', 'Darwin'

# =============================================================================
# OPTIONAL UNIX-ONLY IMPORTS
# =============================================================================

# These modules only exist on Unix systems
if IS_UNIX:
    import pwd
    import grp
    try:
        import pty
        import termios
        import tty
        PTY_AVAILABLE = True
    except ImportError:
        PTY_AVAILABLE = False
        pty = None
        termios = None
        tty = None
else:
    pwd = None
    grp = None
    pty = None
    termios = None
    tty = None
    PTY_AVAILABLE = False

# =============================================================================
# USER/GROUP FUNCTIONS
# =============================================================================

def get_current_user():
    """Get current username (cross-platform)"""
    return getpass.getuser()


def get_current_uid():
    """Get current user ID (returns 0 on Windows as 'admin equivalent')"""
    if IS_WINDOWS:
        # On Windows, return 0 if admin, else 1000 (standard user)
        return 0 if is_admin() else 1000
    return os.getuid()


def get_current_gid():
    """Get current group ID (returns 0 on Windows as 'admin equivalent')"""
    if IS_WINDOWS:
        return 0 if is_admin() else 1000
    return os.getgid()


def get_user_by_uid(uid):
    """Get username by UID (returns generic on Windows)"""
    if IS_WINDOWS:
        if uid == 0:
            return 'Administrator'
        return get_current_user()
    try:
        return pwd.getpwuid(uid).pw_name
    except (KeyError, AttributeError):
        return f'uid:{uid}'


def get_group_by_gid(gid):
    """Get group name by GID (returns generic on Windows)"""
    if IS_WINDOWS:
        if gid == 0:
            return 'Administrators'
        return 'Users'
    try:
        return grp.getgrgid(gid).gr_name
    except (KeyError, AttributeError):
        return f'gid:{gid}'


def get_uid_by_name(username):
    """Get UID by username (returns 1000 on Windows for non-admin)"""
    if IS_WINDOWS:
        return 0 if username.lower() == 'administrator' else 1000
    try:
        return pwd.getpwnam(username).pw_uid
    except (KeyError, AttributeError):
        return None


def get_gid_by_name(groupname):
    """Get GID by group name (returns 1000 on Windows for non-admin)"""
    if IS_WINDOWS:
        return 0 if groupname.lower() == 'administrators' else 1000
    try:
        return grp.getgrnam(groupname).gr_gid
    except (KeyError, AttributeError):
        return None


def get_file_owner(path):
    """Get owner username of a file"""
    try:
        if IS_WINDOWS:
            # Windows doesn't have the same ownership model
            # Return current user as a reasonable default
            return get_current_user()
        stat_info = os.stat(path)
        return pwd.getpwuid(stat_info.st_uid).pw_name
    except (OSError, KeyError, AttributeError):
        return 'unknown'


def get_file_group(path):
    """Get group name of a file"""
    try:
        if IS_WINDOWS:
            return 'Users'
        stat_info = os.stat(path)
        return grp.getgrgid(stat_info.st_gid).gr_name
    except (OSError, KeyError, AttributeError):
        return 'unknown'

# =============================================================================
# PRIVILEGE CHECKS
# =============================================================================

def is_admin():
    """Check if running with admin/root privileges (cross-platform)"""
    if IS_WINDOWS:
        try:
            import ctypes
            return ctypes.windll.shell32.IsUserAnAdmin() != 0
        except Exception:
            return False
    return os.geteuid() == 0


def is_root():
    """Alias for is_admin() - Unix terminology"""
    return is_admin()


def can_use_pty():
    """Check if PTY functionality is available (Unix only)"""
    return PTY_AVAILABLE and IS_UNIX

# =============================================================================
# FILE OPERATIONS
# =============================================================================

def safe_chown(path, uid=None, gid=None):
    """
    Change file ownership (no-op on Windows).
    Returns True on success, False on failure.
    """
    if IS_WINDOWS:
        # Windows uses ACLs, not Unix ownership
        # This is a no-op but returns success for compatibility
        return True
    
    try:
        if uid is None:
            uid = -1  # Don't change
        if gid is None:
            gid = -1  # Don't change
        os.chown(path, uid, gid)
        return True
    except OSError:
        return False


def safe_chmod(path, mode):
    """
    Change file permissions (limited on Windows).
    Windows only supports read-only flag.
    """
    try:
        if IS_WINDOWS:
            # On Windows, we can only really toggle read-only
            # Check if mode would make file read-only
            import stat
            current = os.stat(path).st_mode
            if mode & stat.S_IWRITE:
                # Make writable
                os.chmod(path, current | stat.S_IWRITE)
            else:
                # Make read-only
                os.chmod(path, current & ~stat.S_IWRITE)
        else:
            os.chmod(path, mode)
        return True
    except OSError:
        return False


def safe_setsid():
    """
    Returns a preexec_fn for subprocess that creates new session.
    Returns None on Windows (not supported).
    """
    if IS_WINDOWS:
        return None
    return os.setsid

# =============================================================================
# COMMAND EXECUTION
# =============================================================================

def run_privileged_command(cmd, **kwargs):
    """
    Run a command with elevated privileges.
    On Unix: uses sudo
    On Windows: relies on existing admin context
    
    Args:
        cmd: List of command arguments
        **kwargs: Additional arguments to subprocess.run
    
    Returns:
        subprocess.CompletedProcess
    """
    if IS_WINDOWS:
        # Windows doesn't have sudo - command must be run from admin context
        return subprocess.run(cmd, **kwargs)
    
    if not is_admin():
        # Prepend sudo for non-root users
        cmd = ['sudo', '-n'] + list(cmd)
    
    return subprocess.run(cmd, **kwargs)


def get_shell_executable():
    """Get the default shell executable for the platform"""
    if IS_WINDOWS:
        # Prefer PowerShell, fall back to cmd
        powershell = os.environ.get('COMSPEC', r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe')
        if 'powershell' in powershell.lower() or Path(r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe').exists():
            return r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        return os.environ.get('COMSPEC', 'cmd.exe')
    return os.environ.get('SHELL', '/bin/bash')


def get_script_extension():
    """Get the default script extension for the platform"""
    if IS_WINDOWS:
        return '.ps1'  # PowerShell
    return '.sh'  # Bash

# =============================================================================
# PATH UTILITIES
# =============================================================================

def normalize_path(path):
    """Normalize path separators for the current platform"""
    return str(Path(path))


def to_posix_path(path):
    """Convert path to POSIX style (forward slashes)"""
    return str(Path(path)).replace('\\', '/')


def to_native_path(path):
    """Convert path to native style for current platform"""
    return str(Path(path))

# =============================================================================
# SIGNAL HANDLING
# =============================================================================

def get_termination_signals():
    """Get list of signals to handle for graceful shutdown"""
    import signal
    
    signals = [signal.SIGINT, signal.SIGTERM]
    
    if IS_UNIX:
        # Additional Unix signals
        signals.extend([
            signal.SIGHUP,
            signal.SIGQUIT,
        ])
    
    return signals


def safe_signal_handler(sig, handler):
    """
    Safely set a signal handler.
    Some signals may not be available on all platforms.
    """
    import signal
    try:
        signal.signal(sig, handler)
        return True
    except (OSError, ValueError):
        return False

# =============================================================================
# PROCESS UTILITIES
# =============================================================================

def get_process_info():
    """Get current process information"""
    return {
        'pid': os.getpid(),
        'ppid': os.getppid() if hasattr(os, 'getppid') else None,
        'uid': get_current_uid(),
        'gid': get_current_gid(),
        'user': get_current_user(),
        'is_admin': is_admin(),
        'platform': PLATFORM_NAME,
        'python_version': sys.version,
    }

# =============================================================================
# DOCKER UTILITIES
# =============================================================================

def get_docker_socket_path():
    """Get the Docker socket path for the current platform"""
    if IS_WINDOWS:
        # Docker Desktop for Windows uses named pipe
        return '//./pipe/docker_engine'
    return '/var/run/docker.sock'


def is_docker_available():
    """Check if Docker is available and running"""
    try:
        if IS_WINDOWS:
            # Check Docker Desktop
            result = subprocess.run(
                ['docker', 'info'],
                capture_output=True,
                timeout=5
            )
            return result.returncode == 0
        else:
            # Check socket exists and docker works
            socket_path = get_docker_socket_path()
            if not Path(socket_path).exists():
                return False
            result = subprocess.run(
                ['docker', 'info'],
                capture_output=True,
                timeout=5
            )
            return result.returncode == 0
    except Exception:
        return False

# =============================================================================
# PUID/PGID HELPERS (for Docker compatibility)
# =============================================================================

def detect_puid_pgid():
    """
    Detect appropriate PUID/PGID for Docker containers.
    On Windows, returns defaults (1000/1000) since Windows Docker Desktop
    handles permissions differently.
    """
    if IS_WINDOWS:
        # Windows Docker Desktop handles this automatically
        return 1000, 1000
    
    # On Linux, use actual UID/GID
    return os.getuid(), os.getgid()


def should_fix_puid_pgid():
    """
    Determine if PUID/PGID fixing is needed.
    Returns False on Windows since it's not applicable.
    """
    return IS_UNIX

# =============================================================================
# SERVICE STATUS (nginx, fail2ban, etc.)
# =============================================================================

def check_service_status(service_name):
    """
    Check if a system service is running.
    Returns dict with 'running' bool and 'status' string.
    """
    if IS_WINDOWS:
        try:
            result = subprocess.run(
                ['sc', 'query', service_name],
                capture_output=True,
                text=True,
                timeout=5
            )
            running = 'RUNNING' in result.stdout
            return {
                'running': running,
                'status': 'running' if running else 'stopped',
                'available': result.returncode == 0
            }
        except Exception:
            return {'running': False, 'status': 'unknown', 'available': False}
    else:
        try:
            result = subprocess.run(
                ['systemctl', 'is-active', service_name],
                capture_output=True,
                text=True,
                timeout=5
            )
            status = result.stdout.strip()
            return {
                'running': status == 'active',
                'status': status,
                'available': True
            }
        except Exception:
            return {'running': False, 'status': 'unknown', 'available': False}


# =============================================================================
# FEATURE FLAGS
# =============================================================================

# Features that work differently or not at all on Windows
FEATURES = {
    'pty_terminal': PTY_AVAILABLE,
    'unix_signals': IS_UNIX,
    'file_ownership': IS_UNIX,
    'systemd_services': IS_LINUX,
    'sudo': IS_UNIX,
    'bash_scripts': IS_UNIX,  # .sh scripts
    'powershell_scripts': IS_WINDOWS,  # .ps1 scripts
}


def is_feature_available(feature):
    """Check if a platform feature is available"""
    return FEATURES.get(feature, False)


# =============================================================================
# EXPORTS
# =============================================================================

__all__ = [
    # Platform detection
    'IS_WINDOWS', 'IS_LINUX', 'IS_MACOS', 'IS_UNIX', 'PLATFORM_NAME',
    
    # User/group
    'get_current_user', 'get_current_uid', 'get_current_gid',
    'get_user_by_uid', 'get_group_by_gid',
    'get_uid_by_name', 'get_gid_by_name',
    'get_file_owner', 'get_file_group',
    
    # Privileges
    'is_admin', 'is_root', 'can_use_pty',
    
    # File operations
    'safe_chown', 'safe_chmod', 'safe_setsid',
    
    # Commands
    'run_privileged_command', 'get_shell_executable', 'get_script_extension',
    
    # Paths
    'normalize_path', 'to_posix_path', 'to_native_path',
    
    # Signals
    'get_termination_signals', 'safe_signal_handler',
    
    # Process
    'get_process_info',
    
    # Docker
    'get_docker_socket_path', 'is_docker_available',
    
    # PUID/PGID
    'detect_puid_pgid', 'should_fix_puid_pgid',
    
    # Services
    'check_service_status',
    
    # Features
    'FEATURES', 'is_feature_available',
    
    # Optional modules (may be None on Windows)
    'pwd', 'grp', 'pty', 'termios', 'tty', 'PTY_AVAILABLE',
]

