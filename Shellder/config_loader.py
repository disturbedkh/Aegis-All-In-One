#!/usr/bin/env python3
"""
Shellder Configuration Loader
=============================
Loads and manages stack configuration from shellder_config.toml

This module provides a centralized way to access configuration for all
stack components, supporting both local Docker containers and remote services.

Usage:
    from config_loader import config, get_component_url, is_component_local
    
    # Get a specific setting
    db_host = config.get('database', 'host')
    
    # Check if component is local
    if is_component_local('dragonite'):
        # Use Docker commands
    else:
        # Use remote API
    
    # Get component URL
    url = get_component_url('golbat')  # Returns http://localhost:9001 or remote URL
"""

import os
import sys
from pathlib import Path
from typing import Any, Dict, Optional, Union

# Try to import toml/tomli
try:
    import tomllib  # Python 3.11+
except ImportError:
    try:
        import tomli as tomllib  # Python < 3.11
    except ImportError:
        tomllib = None

# =============================================================================
# CONFIGURATION CLASS
# =============================================================================

class ShellderConfig:
    """
    Configuration manager for Shellder stack components.
    
    Loads configuration from shellder_config.toml and provides
    easy access to component settings with sensible defaults.
    """
    
    # Default configuration values
    DEFAULTS = {
        'general': {
            'aegis_root': '',
            'shellder_data_dir': 'Shellder/data',
            'docker_compose_file': 'docker-compose.yaml',
            'env_file': '.env',
        },
        'database': {
            'enabled': True,
            'local': True,
            'container_name': 'database',
            'host': 'localhost',
            'port': 3306,
            'username': '',
            'password': '',
            'root_password': '',
            'db_golbat': 'golbat',
            'db_dragonite': 'dragonite',
            'db_reactmap': 'reactmap',
            'db_koji': 'koji',
            'db_poracle': 'poracle',
        },
        'dragonite': {
            'enabled': True,
            'local': True,
            'container_name': 'dragonite',
            'host': 'localhost',
            'api_port': 7272,
            'admin_port': 6002,
            'config_file': 'unown/dragonite_config.toml',
            'config_default': 'unown/dragonite_config-default.toml',
            'admin_container_name': 'admin',
        },
        'golbat': {
            'enabled': True,
            'local': True,
            'container_name': 'golbat',
            'host': 'localhost',
            'api_port': 9001,
            'grpc_port': 50001,
            'config_file': 'unown/golbat_config.toml',
            'config_default': 'unown/golbat_config-default.toml',
            'cache_dir': 'unown/golbat_cache',
        },
        'rotom': {
            'enabled': True,
            'local': True,
            'container_name': 'rotom',
            'host': 'localhost',
            'device_port': 7070,
            'controller_port': 7071,
            'web_port': 6003,
            'config_file': 'unown/rotom_config.json',
            'config_default': 'unown/rotom_config-default.json',
            'jobs_dir': 'unown/rotom_jobs',
        },
        'xilriws': {
            'enabled': True,
            'local': True,
            'container_name': 'xilriws',
            'host': 'localhost',
            'port': 5090,
            'proxies_file': 'unown/proxies.txt',
        },
        'reactmap': {
            'enabled': True,
            'local': True,
            'container_name': 'reactmap',
            'host': 'localhost',
            'port': 6001,
            'config_file': 'reactmap/local.json',
            'config_default': 'reactmap/local-default.json',
            'env_file': 'reactmap/env',
        },
        'koji': {
            'enabled': True,
            'local': True,
            'container_name': 'koji',
            'host': 'localhost',
            'port': 6004,
        },
        'poracle': {
            'enabled': False,
            'local': True,
            'container_name': 'poracle',
            'host': 'localhost',
            'port': 6007,
            'config_dir': 'Poracle/config',
            'config_file': 'Poracle/config/local.json',
            'geofence_dir': 'Poracle/geofence',
        },
        'fletchling': {
            'enabled': False,
            'local': True,
            'container_name': 'fletchling',
            'config_file': 'fletchling.toml',
            'data_dir': 'fletchling',
        },
        'grafana': {
            'enabled': True,
            'local': True,
            'container_name': 'grafana',
            'host': 'localhost',
            'port': 6006,
            'dashboards_dir': 'grafana',
        },
        'victoriametrics': {
            'enabled': True,
            'local': True,
            'container_name': 'victoriametrics',
            'host': 'localhost',
            'port': 8428,
            'data_dir': 'victoriametrics/data',
            'vmagent': {
                'container_name': 'vmagent',
                'config_file': 'vmagent/prometheus.yml',
                'data_dir': 'vmagent/data',
            },
        },
        'phpmyadmin': {
            'enabled': True,
            'local': True,
            'container_name': 'pma',
            'host': 'localhost',
            'port': 6005,
        },
        'shellder': {
            'web_port': 5000,
            'api_port': 5050,
            'log_file': 'Shellder/shellder.log',
            'log_level': 'INFO',
            'db_file': 'Shellder/shellder.db',
        },
        'nginx': {
            'enabled': True,
            'config_dir': '/etc/nginx',
            'sites_available': '/etc/nginx/sites-available',
            'sites_enabled': '/etc/nginx/sites-enabled',
            'ssl_dir': '/etc/letsencrypt/live',
        },
        'remote': {
            'ssh_enabled': False,
            'ssh_user': '',
            'ssh_key_file': '',
            'api_key': '',
            'allowed_hosts': '',
        },
        'paths': {
            'mysql_data': 'mysql_data',
            'init_dir': 'init',
            'scanner_logs': 'unown/logs',
        },
    }
    
    def __init__(self, config_path: Optional[str] = None):
        """
        Initialize configuration loader.
        
        Args:
            config_path: Path to shellder_config.toml. If None, auto-detect.
        """
        self._config: Dict[str, Any] = {}
        self._config_path: Optional[Path] = None
        self._aegis_root: Optional[Path] = None
        self._shellder_dir: Optional[Path] = None
        
        # Determine paths
        self._detect_paths(config_path)
        
        # Load configuration
        self._load_config()
    
    def _detect_paths(self, config_path: Optional[str] = None) -> None:
        """Detect Shellder and Aegis root directories."""
        # Find Shellder directory (where this script lives)
        if config_path:
            self._config_path = Path(config_path)
            self._shellder_dir = self._config_path.parent
        else:
            # Auto-detect based on this file's location
            self._shellder_dir = Path(__file__).parent
            self._config_path = self._shellder_dir / 'shellder_config.toml'
        
        # Aegis root is parent of Shellder directory
        self._aegis_root = self._shellder_dir.parent
    
    def _load_config(self) -> None:
        """Load configuration from TOML file."""
        # Start with defaults
        self._config = self._deep_copy_defaults()
        
        # Try to load from file
        if self._config_path and self._config_path.exists():
            if tomllib:
                try:
                    with open(self._config_path, 'rb') as f:
                        file_config = tomllib.load(f)
                    self._merge_config(file_config)
                except Exception as e:
                    print(f"Warning: Error loading config file: {e}")
            else:
                print("Warning: tomllib/tomli not available, using defaults")
        
        # Apply aegis_root if specified
        if self._config.get('general', {}).get('aegis_root'):
            self._aegis_root = Path(self._config['general']['aegis_root'])
    
    def _deep_copy_defaults(self) -> Dict[str, Any]:
        """Create a deep copy of defaults."""
        import copy
        return copy.deepcopy(self.DEFAULTS)
    
    def _merge_config(self, file_config: Dict[str, Any]) -> None:
        """Merge file configuration into defaults."""
        for section, values in file_config.items():
            if section not in self._config:
                self._config[section] = {}
            if isinstance(values, dict):
                for key, value in values.items():
                    if isinstance(value, dict) and key in self._config.get(section, {}):
                        # Nested dict (like victoriametrics.vmagent)
                        self._config[section][key].update(value)
                    else:
                        self._config[section][key] = value
            else:
                self._config[section] = values
    
    # =========================================================================
    # PUBLIC API
    # =========================================================================
    
    @property
    def aegis_root(self) -> Path:
        """Get the Aegis AIO root directory."""
        return self._aegis_root
    
    @property
    def shellder_dir(self) -> Path:
        """Get the Shellder directory."""
        return self._shellder_dir
    
    @property
    def config_path(self) -> Optional[Path]:
        """Get the path to the config file."""
        return self._config_path
    
    def get(self, section: str, key: str, default: Any = None) -> Any:
        """
        Get a configuration value.
        
        Args:
            section: Configuration section (e.g., 'dragonite', 'database')
            key: Configuration key within the section
            default: Default value if not found
            
        Returns:
            Configuration value or default
        """
        return self._config.get(section, {}).get(key, default)
    
    def get_section(self, section: str) -> Dict[str, Any]:
        """
        Get an entire configuration section.
        
        Args:
            section: Configuration section name
            
        Returns:
            Dictionary of section values
        """
        return self._config.get(section, {})
    
    def get_path(self, section: str, key: str) -> Optional[Path]:
        """
        Get a path value, resolved relative to aegis_root.
        
        Args:
            section: Configuration section
            key: Configuration key (should be a path)
            
        Returns:
            Resolved Path object or None
        """
        value = self.get(section, key)
        if not value:
            return None
        
        path = Path(value)
        if path.is_absolute():
            return path
        return self._aegis_root / path
    
    def is_enabled(self, component: str) -> bool:
        """Check if a component is enabled."""
        return self.get(component, 'enabled', False)
    
    def is_local(self, component: str) -> bool:
        """Check if a component is running locally (Docker) vs remote."""
        return self.get(component, 'local', True)
    
    def get_container_name(self, component: str) -> str:
        """Get the Docker container name for a component."""
        return self.get(component, 'container_name', component)
    
    def get_host(self, component: str) -> str:
        """Get the host for a component (localhost for local, configured for remote)."""
        if self.is_local(component):
            return 'localhost'
        return self.get(component, 'host', 'localhost')
    
    def get_port(self, component: str, port_key: str = 'port') -> int:
        """Get a port number for a component."""
        return self.get(component, port_key, 0)
    
    def get_url(self, component: str, port_key: str = 'port', protocol: str = 'http') -> str:
        """
        Get the full URL for a component.
        
        Args:
            component: Component name
            port_key: Key for the port (default 'port', or 'api_port', etc.)
            protocol: URL protocol (default 'http')
            
        Returns:
            Full URL string (e.g., 'http://localhost:9001')
        """
        host = self.get_host(component)
        port = self.get_port(component, port_key)
        return f"{protocol}://{host}:{port}"
    
    def get_all_components(self) -> list:
        """Get list of all component names."""
        return [
            'database', 'dragonite', 'golbat', 'rotom', 'xilriws',
            'reactmap', 'koji', 'poracle', 'fletchling', 'grafana',
            'victoriametrics', 'phpmyadmin', 'shellder'
        ]
    
    def get_enabled_components(self) -> list:
        """Get list of enabled component names."""
        return [c for c in self.get_all_components() if self.is_enabled(c)]
    
    def get_local_containers(self) -> list:
        """Get list of container names for local components."""
        containers = []
        for component in self.get_enabled_components():
            if self.is_local(component):
                containers.append(self.get_container_name(component))
                # Handle special cases with multiple containers
                if component == 'dragonite':
                    admin = self.get('dragonite', 'admin_container_name')
                    if admin:
                        containers.append(admin)
                elif component == 'victoriametrics':
                    vmagent = self.get('victoriametrics', 'vmagent', {})
                    if isinstance(vmagent, dict) and vmagent.get('container_name'):
                        containers.append(vmagent['container_name'])
        return containers
    
    def to_dict(self) -> Dict[str, Any]:
        """Export configuration as dictionary."""
        return self._config.copy()
    
    def to_env_vars(self) -> Dict[str, str]:
        """
        Export configuration as environment variables.
        
        Returns dictionary suitable for os.environ.update() or subprocess.
        Variable names are SHELLDER_<SECTION>_<KEY> in uppercase.
        """
        env = {}
        for section, values in self._config.items():
            if isinstance(values, dict):
                for key, value in values.items():
                    if isinstance(value, dict):
                        # Handle nested dicts
                        for nkey, nvalue in value.items():
                            env_key = f"SHELLDER_{section}_{key}_{nkey}".upper()
                            env[env_key] = str(nvalue)
                    else:
                        env_key = f"SHELLDER_{section}_{key}".upper()
                        env[env_key] = str(value)
        return env
    
    def save(self, path: Optional[str] = None) -> bool:
        """
        Save current configuration to file.
        
        Args:
            path: Path to save to (default: original config path)
            
        Returns:
            True if successful
        """
        save_path = Path(path) if path else self._config_path
        if not save_path:
            return False
        
        try:
            # Generate TOML content
            lines = [
                "# Shellder Stack Configuration",
                "# Auto-generated - see shellder_config.toml for documentation",
                ""
            ]
            
            for section, values in self._config.items():
                if isinstance(values, dict):
                    lines.append(f"[{section}]")
                    for key, value in values.items():
                        if isinstance(value, dict):
                            # Nested section
                            lines.append(f"[{section}.{key}]")
                            for nkey, nvalue in value.items():
                                lines.append(self._format_toml_value(nkey, nvalue))
                        else:
                            lines.append(self._format_toml_value(key, value))
                    lines.append("")
            
            with open(save_path, 'w') as f:
                f.write('\n'.join(lines))
            return True
        except Exception as e:
            print(f"Error saving config: {e}")
            return False
    
    def _format_toml_value(self, key: str, value: Any) -> str:
        """Format a value for TOML output."""
        if isinstance(value, bool):
            return f"{key} = {str(value).lower()}"
        elif isinstance(value, int):
            return f"{key} = {value}"
        elif isinstance(value, str):
            return f'{key} = "{value}"'
        else:
            return f'{key} = "{value}"'
    
    def reload(self) -> None:
        """Reload configuration from file."""
        self._load_config()


# =============================================================================
# GLOBAL INSTANCE & CONVENIENCE FUNCTIONS
# =============================================================================

# Global config instance (lazy-loaded)
_config: Optional[ShellderConfig] = None


def get_config() -> ShellderConfig:
    """Get the global configuration instance."""
    global _config
    if _config is None:
        _config = ShellderConfig()
    return _config


def reload_config() -> ShellderConfig:
    """Reload configuration from file."""
    global _config
    _config = ShellderConfig()
    return _config


# Convenience functions
def get(section: str, key: str, default: Any = None) -> Any:
    """Get a configuration value."""
    return get_config().get(section, key, default)


def get_path(section: str, key: str) -> Optional[Path]:
    """Get a resolved path value."""
    return get_config().get_path(section, key)


def is_component_enabled(component: str) -> bool:
    """Check if a component is enabled."""
    return get_config().is_enabled(component)


def is_component_local(component: str) -> bool:
    """Check if a component is local (Docker) vs remote."""
    return get_config().is_local(component)


def get_component_url(component: str, port_key: str = 'port') -> str:
    """Get the URL for a component."""
    return get_config().get_url(component, port_key)


def get_container_name(component: str) -> str:
    """Get the Docker container name for a component."""
    return get_config().get_container_name(component)


def get_aegis_root() -> Path:
    """Get the Aegis root directory."""
    return get_config().aegis_root


# =============================================================================
# CLI FOR TESTING
# =============================================================================

if __name__ == '__main__':
    import json
    
    config = get_config()
    
    print(f"Aegis Root: {config.aegis_root}")
    print(f"Shellder Dir: {config.shellder_dir}")
    print(f"Config Path: {config.config_path}")
    print()
    
    print("Enabled Components:")
    for comp in config.get_enabled_components():
        local_str = "local" if config.is_local(comp) else "remote"
        print(f"  - {comp} ({local_str})")
    
    print()
    print("Local Containers:")
    for container in config.get_local_containers():
        print(f"  - {container}")
    
    print()
    print("Component URLs:")
    for comp in ['golbat', 'dragonite', 'reactmap', 'koji']:
        if config.is_enabled(comp):
            url = config.get_url(comp, 'api_port' if comp in ['golbat', 'dragonite'] else 'port')
            print(f"  - {comp}: {url}")

