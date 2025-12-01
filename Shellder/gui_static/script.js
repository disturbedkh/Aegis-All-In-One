/**
 * Shellder GUI - JavaScript
 * Client-side functionality for the Aegis AIO control panel
 * With WebSocket support for real-time updates
 */

// =============================================================================
// STATE & CONFIG
// =============================================================================

const API_BASE = '';
let refreshInterval = null;
let currentPage = 'dashboard';
let socket = null;
let wsConnected = false;

// =============================================================================
// WEBSOCKET CONNECTION
// =============================================================================

function initWebSocket() {
    // Check if Socket.IO is available
    if (typeof io === 'undefined') {
        console.log('Socket.IO not available, using polling fallback');
        return;
    }
    
    try {
        socket = io({
            transports: ['websocket', 'polling'],
            reconnection: true,
            reconnectionDelay: 1000,
            reconnectionAttempts: 10
        });
        
        socket.on('connect', () => {
            console.log('WebSocket connected');
            wsConnected = true;
            updateConnectionStatus(true, 'live');
            
            // Subscribe to all stats
            socket.emit('subscribe', { channel: 'all' });
        });
        
        socket.on('disconnect', () => {
            console.log('WebSocket disconnected');
            wsConnected = false;
            updateConnectionStatus(false);
        });
        
        socket.on('connected', (data) => {
            console.log('Server acknowledged connection:', data);
        });
        
        // Real-time container stats
        socket.on('container_stats', (data) => {
            if (currentPage === 'dashboard' || currentPage === 'containers') {
                updateContainerStats(data);
            }
        });
        
        // Real-time system stats
        socket.on('system_stats', (data) => {
            if (currentPage === 'dashboard') {
                updateSystemStats(data);
            }
        });
        
        // Real-time Xilriws stats
        socket.on('xilriws_stats', (data) => {
            updateXilriwsStats(data);
        });
        
        // Port status updates
        socket.on('port_status', (data) => {
            updatePortStatus(data);
        });
        
        // Service status updates
        socket.on('service_status', (data) => {
            updateServiceStatus(data);
        });
        
        // Action results
        socket.on('action_result', (data) => {
            if (data.success) {
                showToast(data.message, 'success');
            } else {
                showToast(`Error: ${data.error}`, 'error');
            }
        });
        
    } catch (error) {
        console.error('WebSocket initialization failed:', error);
    }
}

// =============================================================================
// INITIALIZATION
// =============================================================================

document.addEventListener('DOMContentLoaded', () => {
    initNavigation();
    initWebSocket();
    refreshData();
    startAutoRefresh();
    
    // Load Socket.IO library if not present
    if (typeof io === 'undefined') {
        const script = document.createElement('script');
        script.src = 'https://cdn.socket.io/4.6.0/socket.io.min.js';
        script.onload = initWebSocket;
        document.head.appendChild(script);
    }
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
        updateConnectionStatus(true, wsConnected ? 'live' : 'polling');
        updateLastUpdate();
        
        // Also refresh Xilriws stats
        loadXilriwsStats();
    } catch (error) {
        updateConnectionStatus(false);
        showToast('Failed to fetch status', 'error');
    }
}

function startAutoRefresh() {
    if (refreshInterval) clearInterval(refreshInterval);
    // Use longer interval if WebSocket is connected
    const interval = wsConnected ? 30000 : 10000;
    refreshInterval = setInterval(refreshData, interval);
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
    
    // Update Xilriws if available
    if (data.xilriws) {
        updateXilriwsStats(data.xilriws);
    }
}

function updateContainerStats(containers) {
    // Update running/stopped counts
    let running = 0, stopped = 0;
    Object.values(containers).forEach(c => {
        if (c.status === 'running') running++;
        else stopped++;
    });
    
    document.getElementById('containersRunning').textContent = running;
    document.getElementById('containersStopped').textContent = stopped;
    
    // Update container list
    const list = Object.values(containers);
    updateContainerList(list);
    
    // Update detail list if on containers page
    if (currentPage === 'containers') {
        updateContainerDetailList(list);
    }
}

function updateSystemStats(data) {
    if (data.memory) {
        const memUsed = formatBytes(data.memory.used);
        const memTotal = formatBytes(data.memory.total);
        document.getElementById('memoryUsed').textContent = `${data.memory.percent}%`;
        document.getElementById('memoryInfo').textContent = `${memUsed} / ${memTotal}`;
    }
    
    if (data.disk) {
        const diskUsed = formatBytes(data.disk.used);
        const diskTotal = formatBytes(data.disk.total);
        document.getElementById('diskUsed').textContent = `${data.disk.percent}%`;
        document.getElementById('diskInfo').textContent = `${diskUsed} / ${diskTotal}`;
    }
}

function updateXilriwsStats(data) {
    // If we have an Xilriws stats section, update it
    const statsEl = document.getElementById('xilriwsStats');
    if (!statsEl) return;
    
    if (!data || Object.keys(data).length === 0) {
        statsEl.innerHTML = '<div class="xilriws-empty">Xilriws not running or no data yet</div>';
        return;
    }
    
    const successRate = data.success_rate || 0;
    const rateClass = successRate > 80 ? 'excellent' : successRate > 50 ? 'good' : successRate > 20 ? 'warning' : 'critical';
    
    statsEl.innerHTML = `
        <div class="xilriws-summary">
            <div class="xilriws-stat primary">
                <span class="stat-value ${rateClass}">${successRate.toFixed(1)}%</span>
                <span class="stat-label">Success Rate</span>
            </div>
            <div class="xilriws-stat">
                <span class="stat-value success">${data.successful || 0}</span>
                <span class="stat-label">Successful</span>
            </div>
            <div class="xilriws-stat">
                <span class="stat-value error">${data.failed || 0}</span>
                <span class="stat-label">Failed</span>
            </div>
            <div class="xilriws-stat">
                <span class="stat-value">${data.total_requests || 0}</span>
                <span class="stat-label">Total Requests</span>
            </div>
        </div>
        ${data.auth_banned > 0 || data.code_15 > 0 || data.rate_limited > 0 ? `
        <div class="xilriws-errors">
            <div class="error-title">Error Breakdown</div>
            <div class="error-grid">
                ${data.auth_banned > 0 ? `<div class="error-item"><span class="count">${data.auth_banned}</span> Auth Banned</div>` : ''}
                ${data.code_15 > 0 ? `<div class="error-item"><span class="count">${data.code_15}</span> Code 15</div>` : ''}
                ${data.rate_limited > 0 ? `<div class="error-item"><span class="count">${data.rate_limited}</span> Rate Limited</div>` : ''}
                ${data.invalid_credentials > 0 ? `<div class="error-item"><span class="count">${data.invalid_credentials}</span> Invalid Creds</div>` : ''}
                ${data.tunneling_errors > 0 ? `<div class="error-item"><span class="count">${data.tunneling_errors}</span> Tunnel Errors</div>` : ''}
                ${data.timeouts > 0 ? `<div class="error-item"><span class="count">${data.timeouts}</span> Timeouts</div>` : ''}
            </div>
        </div>
        ` : ''}
    `;
}

async function loadXilriwsStats() {
    try {
        const data = await fetchAPI('/api/xilriws/stats');
        updateXilriwsStats(data);
    } catch (error) {
        console.error('Failed to load Xilriws stats:', error);
    }
}

function updatePortStatus(ports) {
    const portsEl = document.getElementById('portStatus');
    if (!portsEl) return;
    
    portsEl.innerHTML = Object.values(ports).map(p => `
        <div class="port-item ${p.open ? 'open' : 'closed'}">
            <span class="port-number">${p.port}</span>
            <span class="port-name">${p.name}</span>
            <span class="port-state">${p.open ? '●' : '○'}</span>
        </div>
    `).join('');
}

function updateServiceStatus(services) {
    const servicesEl = document.getElementById('serviceStatus');
    if (!servicesEl) return;
    
    servicesEl.innerHTML = Object.entries(services).map(([name, active]) => `
        <div class="service-item ${active ? 'active' : 'inactive'}">
            <span class="service-name">${name}</span>
            <span class="service-state">${active ? '✓' : '✗'}</span>
        </div>
    `).join('');
}

function updateContainerList(containers) {
    const listEl = document.getElementById('containerList');
    
    if (!containers || containers.length === 0) {
        listEl.innerHTML = '<div class="loading">No containers found</div>';
        return;
    }
    
    listEl.innerHTML = containers.map(c => `
        <div class="container-item">
            <div class="container-status ${c.status || c.state}"></div>
            <div class="container-name">${c.name}</div>
            <div class="container-state">${c.status || c.state}</div>
            ${c.cpu_percent !== undefined ? `
                <div class="container-stats">
                    <span title="CPU">${c.cpu_percent}%</span>
                    <span title="Memory">${c.memory_percent || 0}%</span>
                </div>
            ` : ''}
        </div>
    `).join('');
}

function updateContainerDetailList(containers) {
    const listEl = document.getElementById('containerDetailList');
    if (!listEl) return;
    
    if (!containers || containers.length === 0) {
        listEl.innerHTML = '<div class="loading">No containers found</div>';
        return;
    }
    
    listEl.innerHTML = containers.map(c => `
        <div class="container-detail">
            <div class="container-status ${c.status || c.state}"></div>
            <div class="container-info">
                <div class="container-name">${c.name}</div>
                <div class="container-status-text">${c.status || c.state}</div>
                ${c.cpu_percent !== undefined ? `
                    <div class="container-metrics">
                        CPU: ${c.cpu_percent}% | Memory: ${c.memory_percent || 0}%
                    </div>
                ` : ''}
            </div>
            <div class="container-actions">
                ${(c.status || c.state) === 'running' ? `
                    <button class="btn btn-sm" onclick="containerAction('${c.name}', 'restart')">🔄</button>
                    <button class="btn btn-sm btn-danger" onclick="containerAction('${c.name}', 'stop')">⏹️</button>
                ` : `
                    <button class="btn btn-sm btn-success" onclick="containerAction('${c.name}', 'start')">▶️</button>
                `}
                <button class="btn btn-sm" onclick="viewContainerLogs('${c.name}')">📋</button>
            </div>
        </div>
    `).join('');
}

function updateConnectionStatus(connected, mode = '') {
    const dot = document.getElementById('connectionStatus');
    const text = document.getElementById('connectionText');
    
    if (connected) {
        dot.className = 'status-dot connected';
        if (mode === 'live') {
            text.textContent = 'Live';
            dot.classList.add('live');
        } else {
            text.textContent = 'Connected';
        }
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
        updateContainerDetailList(containers);
    } catch (error) {
        listEl.innerHTML = '<div class="loading">Failed to load containers</div>';
    }
}

async function containerAction(name, action) {
    showToast(`${action}ing ${name}...`, 'info');
    
    // Use WebSocket if available
    if (socket && wsConnected) {
        socket.emit('container_action', { name, action });
        return;
    }
    
    // Fall back to REST API
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
        const result = await fetchAPI(`/api/container/${name}/logs?lines=200`);
        
        if (result.success) {
            document.getElementById('modalBody').innerHTML = 
                `<pre class="log-viewer">${escapeHtml(result.logs)}</pre>`;
            
            // Scroll to bottom
            const logViewer = document.querySelector('.modal .log-viewer');
            if (logViewer) logViewer.scrollTop = logViewer.scrollHeight;
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

function formatBytes(bytes) {
    if (!bytes) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0;
    while (bytes >= 1024 && i < units.length - 1) {
        bytes /= 1024;
        i++;
    }
    return `${bytes.toFixed(1)} ${units[i]}`;
}

// =============================================================================
// XILRIWS PAGE FUNCTIONS
// =============================================================================

let xilriwsLiveStream = null;
let xilriwsAutoScroll = true;

function updateXilriwsPage(data) {
    if (!data) return;
    
    // Update stats
    const rate = data.success_rate || 0;
    document.getElementById('xilSuccessRate').textContent = rate.toFixed(1) + '%';
    document.getElementById('xilSuccessRate').className = 'stat-value ' + 
        (rate > 80 ? 'text-success' : rate > 50 ? 'text-warning' : 'text-danger');
    
    document.getElementById('xilSuccessful').textContent = data.successful || 0;
    document.getElementById('xilFailed').textContent = data.failed || 0;
    document.getElementById('xilTotal').textContent = data.total_requests || 0;
    
    // Update error breakdown
    document.getElementById('xilAuthBanned').textContent = data.auth_banned || 0;
    document.getElementById('xilCode15').textContent = data.code_15 || 0;
    document.getElementById('xilRateLimited').textContent = data.rate_limited || 0;
    document.getElementById('xilInvalidCreds').textContent = data.invalid_credentials || 0;
    document.getElementById('xilTunnelErrors').textContent = data.tunneling_errors || 0;
    document.getElementById('xilTimeouts').textContent = data.timeouts || 0;
    document.getElementById('xilConnRefused').textContent = data.connection_refused || 0;
}

async function loadProxyInfo() {
    const container = document.getElementById('proxyInfo');
    try {
        const data = await fetchAPI('/api/xilriws/proxies');
        
        if (!data.exists) {
            container.innerHTML = '<div class="text-warning">No proxy file found</div>';
            return;
        }
        
        container.innerHTML = `
            <div class="info-item">
                <span class="info-label">Proxies Configured</span>
                <span class="info-value">${data.count}</span>
            </div>
            <div class="info-item">
                <span class="info-label">File</span>
                <span class="info-value code">${data.file}</span>
            </div>
            <div class="proxy-sample">
                <div class="sample-label">Sample (first ${data.sample.length}):</div>
                ${data.sample.map(p => `<div class="proxy-line">${escapeHtml(p.replace(/:[^:]+@/, ':***@'))}</div>`).join('')}
            </div>
        `;
    } catch (error) {
        container.innerHTML = '<div class="text-danger">Failed to load proxy info</div>';
    }
}

async function loadXilriwsLogs() {
    const logEl = document.getElementById('xilriwsLogContent');
    try {
        const data = await fetchAPI('/api/container/xilriws/logs?lines=200');
        logEl.textContent = data.logs || 'No logs available';
        if (xilriwsAutoScroll) {
            logEl.scrollTop = logEl.scrollHeight;
        }
    } catch (error) {
        logEl.textContent = 'Failed to load Xilriws logs';
    }
}

function toggleXilriwsLive() {
    xilriwsAutoScroll = document.getElementById('xilLiveToggle').checked;
}

function startXilriwsLiveStream() {
    if (xilriwsLiveStream) {
        xilriwsLiveStream.close();
    }
    
    const logEl = document.getElementById('xilriwsLogContent');
    logEl.textContent = 'Connecting to live stream...';
    
    xilriwsLiveStream = new EventSource('/api/xilriws/live');
    
    xilriwsLiveStream.onmessage = (event) => {
        logEl.textContent += event.data;
        if (xilriwsAutoScroll) {
            logEl.scrollTop = logEl.scrollHeight;
        }
    };
    
    xilriwsLiveStream.onerror = () => {
        logEl.textContent += '\n[Stream disconnected, attempting to reconnect...]';
    };
}

function stopXilriwsLiveStream() {
    if (xilriwsLiveStream) {
        xilriwsLiveStream.close();
        xilriwsLiveStream = null;
    }
}

// =============================================================================
// STATISTICS PAGE FUNCTIONS
// =============================================================================

let statsChart = null;

async function loadHistoricalStats() {
    const days = document.getElementById('statsTimeRange')?.value || 7;
    
    // Load log summaries for chart
    try {
        const summaries = await fetchAPI(`/api/db/log-summaries?days=${days}`);
        updateStatsChart(summaries);
    } catch (error) {
        console.error('Failed to load log summaries:', error);
    }
    
    // Load proxy stats
    loadProxyStatsTable();
    
    // Load events
    loadSystemEvents();
    
    // Load container history
    loadContainerHistory();
}

function updateStatsChart(data) {
    const canvas = document.getElementById('statsChart');
    if (!canvas) return;
    
    const ctx = canvas.getContext('2d');
    
    // Simple chart without Chart.js dependency
    // Draw a basic bar chart
    const width = canvas.width = canvas.parentElement.clientWidth;
    const height = canvas.height = 200;
    
    ctx.clearRect(0, 0, width, height);
    
    if (!data || data.length === 0) {
        ctx.fillStyle = '#64748b';
        ctx.font = '14px Outfit';
        ctx.textAlign = 'center';
        ctx.fillText('No historical data available', width / 2, height / 2);
        return;
    }
    
    const maxErrors = Math.max(...data.map(d => d.error_count || 0), 1);
    const maxLines = Math.max(...data.map(d => d.line_count || 0), 1);
    
    const barWidth = (width - 60) / data.length - 4;
    const chartHeight = height - 40;
    
    data.forEach((d, i) => {
        const x = 30 + i * (barWidth + 4);
        
        // Lines bar (blue)
        const linesHeight = (d.line_count / maxLines) * chartHeight * 0.8;
        ctx.fillStyle = '#3b82f6';
        ctx.fillRect(x, height - 20 - linesHeight, barWidth / 2 - 1, linesHeight);
        
        // Errors bar (red)
        const errorsHeight = (d.error_count / maxErrors) * chartHeight * 0.8;
        ctx.fillStyle = '#ef4444';
        ctx.fillRect(x + barWidth / 2, height - 20 - errorsHeight, barWidth / 2 - 1, errorsHeight);
        
        // Date label
        ctx.fillStyle = '#64748b';
        ctx.font = '10px JetBrains Mono';
        ctx.textAlign = 'center';
        const dateLabel = d.log_date ? d.log_date.substring(5) : '';
        ctx.fillText(dateLabel, x + barWidth / 2, height - 5);
    });
    
    // Legend
    ctx.fillStyle = '#3b82f6';
    ctx.fillRect(width - 100, 10, 12, 12);
    ctx.fillStyle = '#f1f5f9';
    ctx.font = '11px Outfit';
    ctx.textAlign = 'left';
    ctx.fillText('Lines', width - 82, 20);
    
    ctx.fillStyle = '#ef4444';
    ctx.fillRect(width - 100, 28, 12, 12);
    ctx.fillText('Errors', width - 82, 38);
}

async function loadProxyStatsTable() {
    const tbody = document.getElementById('proxyStatsBody');
    if (!tbody) return;
    
    try {
        const stats = await fetchAPI('/api/db/proxy-stats?limit=20');
        
        if (!stats || stats.length === 0) {
            tbody.innerHTML = '<tr><td colspan="5" class="text-muted">No proxy stats recorded</td></tr>';
            return;
        }
        
        tbody.innerHTML = stats.map(s => {
            const rate = s.total > 0 ? ((s.success / s.total) * 100).toFixed(1) : 0;
            const rateClass = rate > 80 ? 'text-success' : rate > 50 ? 'text-warning' : 'text-danger';
            return `
                <tr>
                    <td class="code">${escapeHtml(s.proxy?.substring(0, 30) || 'Unknown')}...</td>
                    <td>${s.total || 0}</td>
                    <td class="text-success">${s.success || 0}</td>
                    <td class="text-danger">${s.failed || 0}</td>
                    <td class="${rateClass}">${rate}%</td>
                </tr>
            `;
        }).join('');
    } catch (error) {
        tbody.innerHTML = '<tr><td colspan="5" class="text-danger">Failed to load</td></tr>';
    }
}

async function loadSystemEvents() {
    const container = document.getElementById('systemEvents');
    if (!container) return;
    
    try {
        const events = await fetchAPI('/api/db/events?limit=20');
        
        if (!events || events.length === 0) {
            container.innerHTML = '<div class="text-muted">No events recorded</div>';
            return;
        }
        
        container.innerHTML = events.map(e => `
            <div class="event-item ${e.event_type?.toLowerCase() || ''}">
                <div class="event-time">${e.timestamp ? new Date(e.timestamp).toLocaleString() : ''}</div>
                <div class="event-type">${escapeHtml(e.event_type || '')}</div>
                <div class="event-desc">${escapeHtml(e.description || '')}</div>
            </div>
        `).join('');
    } catch (error) {
        container.innerHTML = '<div class="text-danger">Failed to load events</div>';
    }
}

async function loadContainerHistory() {
    const container = document.getElementById('containerHistory');
    if (!container) return;
    
    try {
        const stats = await fetchAPI('/api/db/container-stats');
        
        if (!stats || stats.length === 0) {
            container.innerHTML = '<div class="text-muted">No container history recorded</div>';
            return;
        }
        
        container.innerHTML = `
            <table class="stats-table">
                <thead>
                    <tr>
                        <th>Container</th>
                        <th>Starts</th>
                        <th>Restarts</th>
                        <th>Crashes</th>
                        <th>Uptime</th>
                        <th>Status</th>
                    </tr>
                </thead>
                <tbody>
                    ${stats.map(s => {
                        const uptime = s.uptime_seconds ? formatDuration(s.uptime_seconds) : '-';
                        return `
                            <tr>
                                <td class="code">${escapeHtml(s.name || '')}</td>
                                <td>${s.starts || 0}</td>
                                <td class="text-warning">${s.restarts || 0}</td>
                                <td class="text-danger">${s.crashes || 0}</td>
                                <td>${uptime}</td>
                                <td class="${s.status === 'running' ? 'text-success' : 'text-danger'}">${s.status || '-'}</td>
                            </tr>
                        `;
                    }).join('')}
                </tbody>
            </table>
        `;
    } catch (error) {
        container.innerHTML = '<div class="text-danger">Failed to load container history</div>';
    }
}

function formatDuration(seconds) {
    if (!seconds) return '-';
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const mins = Math.floor((seconds % 3600) / 60);
    
    if (days > 0) return `${days}d ${hours}h`;
    if (hours > 0) return `${hours}h ${mins}m`;
    return `${mins}m`;
}

// =============================================================================
// FILE BROWSER FUNCTIONS
// =============================================================================

let currentFilePath = '';

async function navigateToPath(path) {
    currentFilePath = path;
    document.getElementById('currentPath').textContent = '/' + path || '/';
    
    const container = document.getElementById('fileList');
    container.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        const data = await fetchAPI(`/api/files?path=${encodeURIComponent(path)}`);
        
        if (data.error) {
            container.innerHTML = `<div class="text-danger">${escapeHtml(data.error)}</div>`;
            return;
        }
        
        if (!data.files || data.files.length === 0) {
            container.innerHTML = '<div class="text-muted">Empty directory</div>';
            return;
        }
        
        container.innerHTML = data.files.map(f => {
            const icon = f.type === 'directory' ? '📁' : getFileIcon(f.name);
            const sizeStr = f.type === 'file' ? formatBytes(f.size) : '';
            const clickAction = f.type === 'directory' 
                ? `navigateToPath('${path ? path + '/' : ''}${f.name}')`
                : `viewFile('${path ? path + '/' : ''}${f.name}')`;
            
            return `
                <div class="file-item ${f.type}" onclick="${clickAction}">
                    <span class="file-icon">${icon}</span>
                    <span class="file-name">${escapeHtml(f.name)}</span>
                    <span class="file-size">${sizeStr}</span>
                </div>
            `;
        }).join('');
    } catch (error) {
        container.innerHTML = '<div class="text-danger">Failed to load files</div>';
    }
}

function navigateUp() {
    const parts = currentFilePath.split('/').filter(p => p);
    parts.pop();
    navigateToPath(parts.join('/'));
}

function getFileIcon(filename) {
    const ext = filename.split('.').pop().toLowerCase();
    const icons = {
        'sh': '📜', 'bash': '📜',
        'py': '🐍', 'python': '🐍',
        'js': '📒', 'ts': '📘',
        'json': '📋', 'yaml': '📋', 'yml': '📋', 'toml': '📋',
        'md': '📝', 'txt': '📄',
        'sql': '🗃️', 'db': '🗃️',
        'env': '🔐', 'cnf': '⚙️', 'conf': '⚙️', 'cfg': '⚙️',
        'log': '📊',
        'html': '🌐', 'css': '🎨',
        'png': '🖼️', 'jpg': '🖼️', 'jpeg': '🖼️', 'gif': '🖼️',
        'zip': '📦', 'tar': '📦', 'gz': '📦'
    };
    return icons[ext] || '📄';
}

async function viewFile(path) {
    const viewer = document.getElementById('fileViewer');
    const nameEl = document.getElementById('fileViewerName');
    const contentEl = document.getElementById('fileViewerContent');
    
    nameEl.textContent = path;
    contentEl.textContent = 'Loading...';
    viewer.style.display = 'block';
    
    try {
        const data = await fetchAPI(`/api/file?path=${encodeURIComponent(path)}`);
        
        if (data.error) {
            contentEl.textContent = `Error: ${data.error}`;
            return;
        }
        
        contentEl.textContent = data.content || '(empty file)';
    } catch (error) {
        contentEl.textContent = 'Failed to load file content';
    }
}

function closeFileViewer() {
    document.getElementById('fileViewer').style.display = 'none';
}

// =============================================================================
// CONTAINER LOG STREAMING
// =============================================================================

let containerLogStream = null;
let currentLogContainer = null;

function streamContainerLogs(containerName) {
    if (containerLogStream) {
        containerLogStream.close();
    }
    
    currentLogContainer = containerName;
    
    openModal(`${containerName} Logs (Live)`, `
        <div class="log-controls">
            <label class="toggle-label">
                <input type="checkbox" id="logAutoScroll" checked>
                <span>Auto-scroll</span>
            </label>
            <button class="btn btn-sm" onclick="stopContainerLogStream()">Stop</button>
        </div>
        <pre id="modalLogContent" class="log-viewer live-log">Connecting...</pre>
    `);
    
    const logEl = document.getElementById('modalLogContent');
    
    containerLogStream = new EventSource(`/api/container/${containerName}/logs/stream`);
    
    containerLogStream.onmessage = (event) => {
        logEl.textContent += event.data;
        if (document.getElementById('logAutoScroll')?.checked) {
            logEl.scrollTop = logEl.scrollHeight;
        }
    };
    
    containerLogStream.onerror = () => {
        logEl.textContent += '\n[Stream disconnected]';
        stopContainerLogStream();
    };
}

function stopContainerLogStream() {
    if (containerLogStream) {
        containerLogStream.close();
        containerLogStream = null;
    }
}

// =============================================================================
// PAGE INITIALIZATION HOOKS
// =============================================================================

// Override the existing showPage to add page-specific initialization
const originalShowPage = showPage;
showPage = function(page) {
    // Stop any streams when leaving a page
    stopXilriwsLiveStream();
    stopContainerLogStream();
    
    // Call original function
    originalShowPage(page);
    
    // Page-specific initialization
    switch(page) {
        case 'xilriws':
            loadXilriwsStats();
            loadProxyInfo();
            loadXilriwsLogs();
            // Also fetch current stats
            fetchAPI('/api/xilriws/stats').then(data => updateXilriwsPage(data));
            break;
        case 'stats':
            loadHistoricalStats();
            break;
        case 'files':
            navigateToPath('');
            break;
    }
};
