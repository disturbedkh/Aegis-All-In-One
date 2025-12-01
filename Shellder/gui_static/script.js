/**
 * Shellder GUI - JavaScript
 * Client-side functionality for the Aegis AIO control panel
 */

// =============================================================================
// STATE & CONFIG
// =============================================================================

const API_BASE = '';
let refreshInterval = null;
let currentPage = 'dashboard';

// =============================================================================
// INITIALIZATION
// =============================================================================

document.addEventListener('DOMContentLoaded', () => {
    initNavigation();
    refreshData();
    startAutoRefresh();
});

function initNavigation() {
    document.querySelectorAll('.nav-item').forEach(item => {
        item.addEventListener('click', (e) => {
            e.preventDefault();
            const page = item.dataset.page;
            navigateTo(page);
        });
    });
}

function navigateTo(page) {
    // Update nav
    document.querySelectorAll('.nav-item').forEach(item => {
        item.classList.toggle('active', item.dataset.page === page);
    });
    
    // Update pages
    document.querySelectorAll('.page').forEach(p => {
        p.classList.toggle('active', p.id === `page-${page}`);
    });
    
    // Update title
    const titles = {
        'dashboard': 'Dashboard',
        'containers': 'Containers',
        'scripts': 'Scripts',
        'logs': 'Logs',
        'updates': 'Updates'
    };
    document.getElementById('pageTitle').textContent = titles[page] || page;
    
    currentPage = page;
    
    // Load page-specific data
    if (page === 'logs') {
        loadShellderLogs();
    } else if (page === 'updates') {
        checkGitStatus();
    } else if (page === 'containers') {
        loadContainerDetails();
    }
}

// =============================================================================
// DATA FETCHING
// =============================================================================

async function fetchAPI(endpoint, options = {}) {
    try {
        const response = await fetch(`${API_BASE}${endpoint}`, {
            ...options,
            headers: {
                'Content-Type': 'application/json',
                ...options.headers
            }
        });
        return await response.json();
    } catch (error) {
        console.error('API Error:', error);
        throw error;
    }
}

async function refreshData() {
    try {
        const data = await fetchAPI('/api/status');
        updateDashboard(data);
        updateConnectionStatus(true);
        updateLastUpdate();
    } catch (error) {
        updateConnectionStatus(false);
        showToast('Failed to fetch status', 'error');
    }
}

function startAutoRefresh() {
    if (refreshInterval) clearInterval(refreshInterval);
    refreshInterval = setInterval(refreshData, 10000); // Every 10 seconds
}

// =============================================================================
// DASHBOARD UPDATES
// =============================================================================

function updateDashboard(data) {
    // Stats
    document.getElementById('containersRunning').textContent = data.containers.running;
    document.getElementById('containersStopped').textContent = data.containers.stopped;
    
    if (data.system.memory) {
        document.getElementById('memoryUsed').textContent = data.system.memory.used;
        document.getElementById('memoryInfo').textContent = 
            `${data.system.memory.used} / ${data.system.memory.total}`;
    }
    
    if (data.system.disk) {
        document.getElementById('diskUsed').textContent = data.system.disk.percent;
        document.getElementById('diskInfo').textContent = 
            `${data.system.disk.used} / ${data.system.disk.total} (${data.system.disk.percent})`;
    }
    
    document.getElementById('systemUptime').textContent = data.system.uptime || 'N/A';
    document.getElementById('envStatus').textContent = 
        data.env_configured ? '✓ Configured' : '✗ Not configured';
    
    // Container list
    updateContainerList(data.containers.list);
}

function updateContainerList(containers) {
    const listEl = document.getElementById('containerList');
    
    if (!containers || containers.length === 0) {
        listEl.innerHTML = '<div class="loading">No containers found</div>';
        return;
    }
    
    listEl.innerHTML = containers.map(c => `
        <div class="container-item">
            <div class="container-status ${c.state}"></div>
            <div class="container-name">${c.name}</div>
            <div class="container-state">${c.state}</div>
        </div>
    `).join('');
}

function updateConnectionStatus(connected) {
    const dot = document.getElementById('connectionStatus');
    const text = document.getElementById('connectionText');
    
    if (connected) {
        dot.className = 'status-dot connected';
        text.textContent = 'Connected';
    } else {
        dot.className = 'status-dot error';
        text.textContent = 'Disconnected';
    }
}

function updateLastUpdate() {
    const now = new Date();
    document.getElementById('lastUpdate').textContent = 
        `Updated ${now.toLocaleTimeString()}`;
}

// =============================================================================
// CONTAINER MANAGEMENT
// =============================================================================

async function loadContainerDetails() {
    const listEl = document.getElementById('containerDetailList');
    listEl.innerHTML = '<div class="loading">Loading containers...</div>';
    
    try {
        const containers = await fetchAPI('/api/containers');
        
        if (!containers || containers.length === 0) {
            listEl.innerHTML = '<div class="loading">No containers found</div>';
            return;
        }
        
        listEl.innerHTML = containers.map(c => `
            <div class="container-detail">
                <div class="container-status ${c.state}"></div>
                <div class="container-info">
                    <div class="container-name">${c.name}</div>
                    <div class="container-status-text">${c.status}</div>
                </div>
                <div class="container-actions">
                    ${c.state === 'running' ? `
                        <button class="btn btn-sm" onclick="containerAction('${c.name}', 'restart')">🔄 Restart</button>
                        <button class="btn btn-sm btn-danger" onclick="containerAction('${c.name}', 'stop')">⏹️ Stop</button>
                    ` : `
                        <button class="btn btn-sm btn-success" onclick="containerAction('${c.name}', 'start')">▶️ Start</button>
                    `}
                    <button class="btn btn-sm" onclick="viewContainerLogs('${c.name}')">📋 Logs</button>
                </div>
            </div>
        `).join('');
    } catch (error) {
        listEl.innerHTML = '<div class="loading">Failed to load containers</div>';
    }
}

async function containerAction(name, action) {
    showToast(`${action}ing ${name}...`, 'info');
    
    try {
        const result = await fetchAPI(`/api/container/${name}/${action}`, {
            method: 'POST'
        });
        
        if (result.success) {
            showToast(`${name} ${action}ed successfully`, 'success');
            setTimeout(() => {
                refreshData();
                if (currentPage === 'containers') {
                    loadContainerDetails();
                }
            }, 1000);
        } else {
            showToast(`Failed to ${action} ${name}: ${result.error}`, 'error');
        }
    } catch (error) {
        showToast(`Failed to ${action} ${name}`, 'error');
    }
}

async function viewContainerLogs(name) {
    openModal(`Logs: ${name}`, '<div class="loading">Loading logs...</div>');
    
    try {
        const result = await fetchAPI(`/api/container/${name}/logs?lines=100`);
        
        if (result.success) {
            document.getElementById('modalBody').innerHTML = 
                `<pre class="log-viewer">${escapeHtml(result.logs)}</pre>`;
        } else {
            document.getElementById('modalBody').innerHTML = 
                `<div class="text-danger">Failed to load logs: ${result.error}</div>`;
        }
    } catch (error) {
        document.getElementById('modalBody').innerHTML = 
            '<div class="text-danger">Failed to load logs</div>';
    }
}

// =============================================================================
// DOCKER COMPOSE ACTIONS
// =============================================================================

async function dockerAction(action) {
    const actionNames = {
        'up': 'Starting all containers',
        'down': 'Stopping all containers',
        'restart': 'Restarting all containers',
        'pull': 'Pulling latest images'
    };
    
    showToast(`${actionNames[action]}...`, 'info');
    
    try {
        const result = await fetchAPI(`/api/docker/${action}`, {
            method: 'POST'
        });
        
        if (result.success) {
            showToast(`${actionNames[action]} completed`, 'success');
            setTimeout(refreshData, 2000);
        } else {
            showToast(`Failed: ${result.error || result.output}`, 'error');
        }
    } catch (error) {
        showToast(`Operation failed`, 'error');
    }
}

// =============================================================================
// LOGS
// =============================================================================

async function loadShellderLogs() {
    const lines = document.getElementById('logLines')?.value || 100;
    const logEl = document.getElementById('logContent');
    
    try {
        const result = await fetchAPI(`/api/logs/shellder?lines=${lines}`);
        logEl.textContent = result.logs || 'No logs available';
        logEl.scrollTop = logEl.scrollHeight;
    } catch (error) {
        logEl.textContent = 'Failed to load logs';
    }
}

// =============================================================================
// SCRIPTS
// =============================================================================

function showScriptInfo(script) {
    const info = {
        'setup.sh': {
            name: 'Initial Setup',
            description: 'First-time configuration wizard. Sets up .env file, installs Docker, configures permissions.',
            command: 'sudo bash shellder.sh → Option 1'
        },
        'dbsetup.sh': {
            name: 'Database Manager',
            description: 'MariaDB setup and maintenance. Install database, create users, backup/restore, performance tuning.',
            command: 'sudo bash shellder.sh → Option 2'
        },
        'nginx-setup.sh': {
            name: 'Security Setup',
            description: 'Configure Nginx reverse proxy with SSL certificates. Secure your services with HTTPS.',
            command: 'sudo bash shellder.sh → Option 3'
        },
        'check.sh': {
            name: 'System Check',
            description: 'Verify your configuration. Check Docker, databases, file permissions, and service health.',
            command: 'sudo bash shellder.sh → Option 4'
        },
        'logs.sh': {
            name: 'Log Manager',
            description: 'View and analyze Docker container logs. Monitor Xilriws proxy stats, search for errors.',
            command: 'sudo bash shellder.sh → Option 5'
        },
        'files.sh': {
            name: 'File Manager',
            description: 'Git operations and file management. Pull updates, restore missing files, backup configs.',
            command: 'sudo bash shellder.sh → Option 8'
        },
        'poracle.sh': {
            name: 'Poracle Setup',
            description: 'Configure Poracle notification system for Discord and Telegram alerts.',
            command: 'sudo bash shellder.sh → Option 6'
        },
        'fletchling.sh': {
            name: 'Fletchling Setup',
            description: 'Configure Fletchling for quest scanning with Koji geofence integration.',
            command: 'sudo bash shellder.sh → Option 7'
        }
    };
    
    const s = info[script];
    if (!s) return;
    
    openModal(s.name, `
        <p style="margin-bottom: 16px; color: var(--text-secondary);">${s.description}</p>
        <div class="terminal-hint" style="margin: 0;">
            <div class="hint-icon">💡</div>
            <div class="hint-text">
                <strong>Run via terminal:</strong>
                <code>${s.command}</code>
            </div>
        </div>
    `);
}

// =============================================================================
// GIT / UPDATES
// =============================================================================

async function checkGitStatus() {
    const statusEl = document.getElementById('gitStatus');
    statusEl.innerHTML = '<div class="loading">Checking for updates...</div>';
    
    try {
        const result = await fetchAPI('/api/git/status');
        
        if (result.success) {
            let statusHtml = `<pre>${escapeHtml(result.status)}</pre>`;
            
            if (result.behind) {
                statusHtml += '<p class="text-warning" style="margin-top: 12px;">⚠️ Updates available! Click "Pull Updates" to update.</p>';
            } else {
                statusHtml += '<p class="text-success" style="margin-top: 12px;">✓ You are up to date</p>';
            }
            
            statusEl.innerHTML = statusHtml;
        } else {
            statusEl.innerHTML = `<div class="text-danger">Failed to check: ${result.error}</div>`;
        }
    } catch (error) {
        statusEl.innerHTML = '<div class="text-danger">Failed to check git status</div>';
    }
}

async function gitPull() {
    const outputEl = document.getElementById('updateOutput');
    outputEl.style.display = 'block';
    outputEl.querySelector('pre').textContent = 'Pulling updates...';
    
    try {
        const result = await fetchAPI('/api/git/pull', { method: 'POST' });
        
        outputEl.querySelector('pre').textContent = result.output || 'Complete';
        
        if (result.success) {
            showToast('Updates pulled successfully', 'success');
        } else {
            showToast('Pull completed with warnings', 'warning');
        }
        
        checkGitStatus();
    } catch (error) {
        outputEl.querySelector('pre').textContent = 'Failed to pull updates';
        showToast('Failed to pull updates', 'error');
    }
}

// =============================================================================
// MODAL
// =============================================================================

function openModal(title, content, footer = '') {
    document.getElementById('modalTitle').textContent = title;
    document.getElementById('modalBody').innerHTML = content;
    document.getElementById('modalFooter').innerHTML = footer;
    document.getElementById('modal').classList.add('active');
}

function closeModal() {
    document.getElementById('modal').classList.remove('active');
}

// Close modal on outside click
document.getElementById('modal')?.addEventListener('click', (e) => {
    if (e.target.id === 'modal') {
        closeModal();
    }
});

// Close modal on Escape key
document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
        closeModal();
    }
});

// =============================================================================
// TOAST NOTIFICATIONS
// =============================================================================

function showToast(message, type = 'info') {
    const container = document.getElementById('toastContainer');
    const toast = document.createElement('div');
    toast.className = `toast ${type}`;
    
    const icons = {
        'success': '✓',
        'error': '✗',
        'warning': '⚠',
        'info': 'ℹ'
    };
    
    toast.innerHTML = `
        <span class="toast-icon">${icons[type]}</span>
        <span class="toast-message">${escapeHtml(message)}</span>
    `;
    
    container.appendChild(toast);
    
    // Auto remove after 5 seconds
    setTimeout(() => {
        toast.style.animation = 'toastOut 0.3s ease forwards';
        setTimeout(() => toast.remove(), 300);
    }, 5000);
}

// =============================================================================
// UTILITIES
// =============================================================================

function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

