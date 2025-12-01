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
        'xilriws': 'Xilriws Auth Proxy',
        'stats': 'Statistics',
        'files': 'File Manager',
        'scripts': 'Scripts',
        'logs': 'Logs',
        'updates': 'Updates'
    };
    document.getElementById('pageTitle').textContent = titles[page] || page;
    
    currentPage = page;
    
    // Load page-specific data
    if (page === 'xilriws') {
        loadXilriwsStats();
        loadXilriwsLogs();
    } else if (page === 'logs') {
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
    /**
     * Update Xilriws statistics on both dashboard and Xilriws page
     * Handles the new detailed stats format from the improved log parser
     */
    
    // Update dashboard summary if present
    const dashboardEl = document.getElementById('xilriwsStats');
    if (dashboardEl) {
        if (!data || Object.keys(data).length === 0) {
            dashboardEl.innerHTML = '<div class="xilriws-empty">Xilriws not running or no data yet</div>';
        } else {
            const successRate = data.success_rate || 0;
            const rateClass = successRate > 80 ? 'excellent' : successRate > 50 ? 'good' : successRate > 20 ? 'warning' : 'critical';
            
            dashboardEl.innerHTML = `
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
                        <span class="stat-label">Total</span>
                    </div>
                </div>
            `;
        }
    }
    
    // Update Xilriws page elements if present
    updateXilriwsPage(data);
}

function updateXilriwsPage(data) {
    /**
     * Update the dedicated Xilriws page with detailed statistics
     */
    if (!data) return;
    
    // Main stats
    const successRate = data.success_rate || 0;
    const rateEl = document.getElementById('xilSuccessRate');
    if (rateEl) {
        rateEl.textContent = `${successRate.toFixed(1)}%`;
        rateEl.parentElement?.classList.remove('excellent', 'good', 'warning', 'critical');
        const rateClass = successRate > 80 ? 'excellent' : successRate > 50 ? 'good' : successRate > 20 ? 'warning' : 'critical';
        rateEl.parentElement?.classList.add(rateClass);
    }
    
    setElementText('xilSuccessful', data.successful || data.auth_success || 0);
    setElementText('xilFailed', data.failed || 0);
    setElementText('xilTotal', data.total_requests || 0);
    
    // Cookie storage
    const cookieCurrent = data.cookie_current ?? 0;
    const cookieMax = data.cookie_max ?? 2;
    setElementText('xilCookieStatus', `${cookieCurrent}/${cookieMax}`);
    
    // Critical events
    setElementText('xilCritical', data.critical_failures || 0);
    const criticalIcon = document.getElementById('criticalIcon');
    if (criticalIcon) {
        criticalIcon.textContent = data.critical_failures > 0 ? '🔥' : '⚠️';
        criticalIcon.parentElement?.classList.toggle('danger', data.critical_failures > 0);
    }
    
    // Error breakdown - Account Status
    setElementText('xilAuthBanned', data.auth_banned || 0);
    setElementText('xilMaxRetries', data.auth_max_retries || 0);
    setElementText('xilInternalError', data.auth_internal_error || 0);
    
    // Error breakdown - Browser Issues
    setElementText('xilCode15', data.browser_bot_protection || 0);
    setElementText('xilBrowserTimeout', data.browser_timeout || 0);
    setElementText('xilBrowserUnreachable', data.browser_unreachable || 0);
    setElementText('xilJSTimeout', data.browser_js_timeout || 0);
    
    // Error breakdown - Connection Issues
    setElementText('xilTunnelFailed', data.ptc_tunnel_failed || 0);
    setElementText('xilConnTimeout', data.ptc_connection_timeout || 0);
    setElementText('xilCaptcha', data.ptc_captcha || 0);
    
    // Current proxy badge
    const proxyBadge = document.getElementById('currentProxyBadge');
    if (proxyBadge) {
        proxyBadge.textContent = data.current_proxy ? `Current: ${data.current_proxy}` : 'Current: --';
    }
    
    // Update proxy stats
    updateProxyStats(data.proxy_stats || {});
    
    // Update recent errors
    updateRecentErrors(data.recent_errors || []);
    
    // Update error count badge
    const errorCountEl = document.getElementById('errorCount');
    if (errorCountEl) {
        const errorCount = (data.recent_errors || []).length;
        errorCountEl.textContent = `${errorCount} error${errorCount !== 1 ? 's' : ''}`;
    }
}

function setElementText(id, value) {
    const el = document.getElementById(id);
    if (el) el.textContent = value;
}

function updateProxyStats(proxyStats) {
    /**
     * Update the proxy performance table
     */
    const container = document.getElementById('proxyStats');
    if (!container) return;
    
    const proxies = Object.entries(proxyStats);
    
    if (proxies.length === 0) {
        container.innerHTML = '<div class="no-data">No proxy data available</div>';
        return;
    }
    
    // Sort by requests (most active first)
    proxies.sort((a, b) => (b[1].requests || 0) - (a[1].requests || 0));
    
    let html = `
        <table class="proxy-table">
            <thead>
                <tr>
                    <th>Proxy</th>
                    <th>Success</th>
                    <th>Fail</th>
                    <th>Rate</th>
                    <th>Issues</th>
                </tr>
            </thead>
            <tbody>
    `;
    
    for (const [proxy, stats] of proxies) {
        const successRate = stats.success_rate || 0;
        const rateClass = successRate > 80 ? 'rate-good' : successRate > 50 ? 'rate-ok' : 'rate-bad';
        
        // Build issues summary
        const issues = [];
        if (stats.timeout > 0) issues.push(`⏱${stats.timeout}`);
        if (stats.unreachable > 0) issues.push(`🌐${stats.unreachable}`);
        if (stats.bot_blocked > 0) issues.push(`🛡${stats.bot_blocked}`);
        
        // Highlight consistently failing proxies
        const rowClass = stats.unreachable > 3 ? 'proxy-problematic' : '';
        
        html += `
            <tr class="${rowClass}">
                <td class="proxy-addr" title="${proxy}">${truncateProxy(proxy)}</td>
                <td class="success">${stats.success || 0}</td>
                <td class="fail">${stats.fail || 0}</td>
                <td class="${rateClass}">${successRate.toFixed(0)}%</td>
                <td class="issues">${issues.join(' ') || '-'}</td>
            </tr>
        `;
    }
    
    html += '</tbody></table>';
    container.innerHTML = html;
}

function truncateProxy(proxy) {
    // Show IP or hostname briefly
    if (proxy.length > 20) {
        const parts = proxy.split(':');
        const host = parts[0];
        const port = parts[1];
        if (host.includes('.') && host.length > 15) {
            // IP address - show last octet and port
            const ip = host.split('.');
            return `...${ip[ip.length - 1]}:${port}`;
        }
        return proxy.substring(0, 17) + '...';
    }
    return proxy;
}

function updateRecentErrors(errors) {
    /**
     * Update the recent errors list
     */
    const container = document.getElementById('recentErrors');
    if (!container) return;
    
    if (errors.length === 0) {
        container.innerHTML = '<div class="no-data">No recent errors</div>';
        return;
    }
    
    // Show last 15 errors (newest first)
    const recentErrors = errors.slice(-15).reverse();
    
    let html = '';
    for (const error of recentErrors) {
        const typeIcon = getErrorIcon(error.type);
        const proxyInfo = error.proxy ? `<span class="error-proxy">${truncateProxy(error.proxy)}</span>` : '';
        
        html += `
            <div class="error-entry ${error.type === 'CRITICAL' ? 'critical' : ''}">
                <span class="error-time">${error.time || '--:--'}</span>
                <span class="error-icon">${typeIcon}</span>
                <span class="error-message">${escapeHtml(error.message || 'Unknown error')}</span>
                ${proxyInfo}
            </div>
        `;
    }
    
    container.innerHTML = html;
}

function getErrorIcon(type) {
    const icons = {
        'browser': '🌐',
        'ptc': '🔐',
        'xilriws': '⚡',
        'captcha': '🔐',
        'CRITICAL': '🔥'
    };
    return icons[type] || '⚠️';
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

async function loadXilriwsStats() {
    try {
        const data = await fetchAPI('/api/xilriws/stats');
        updateXilriwsStats(data);
    } catch (error) {
        console.error('Failed to load Xilriws stats:', error);
    }
}

function filterXilriwsLogs() {
    /**
     * Filter displayed logs based on selection
     */
    const filter = document.getElementById('logFilter')?.value || 'all';
    const logContent = document.getElementById('xilriwsLogContent');
    if (!logContent) return;
    
    // Get all lines
    const lines = logContent.textContent.split('\n');
    const filtered = lines.filter(line => {
        if (filter === 'all') return true;
        const lineLower = line.toLowerCase();
        switch (filter) {
            case 'success': return line.includes('| S |') || lineLower.includes('200 ok');
            case 'error': return line.includes('| E |') || line.includes('| C |');
            case 'warning': return line.includes('| W |');
            case 'proxy': return lineLower.includes('proxy') || lineLower.includes('switching');
            default: return true;
        }
    });
    
    logContent.textContent = filtered.join('\n');
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
        case 'stack':
            loadStackData();
            break;
        case 'devices':
            loadDevicesPage();
            break;
    }
};

// =============================================================================
// DEVICE MANAGEMENT FUNCTIONS (Cross-Reference Rotom/Dragonite)
// =============================================================================

let currentCrashId = null;
let currentLogContainer = null;
let currentLogLine = null;

async function loadDevicesPage() {
    await Promise.all([
        loadDeviceSummary(),
        loadDevicesList(),
        loadCrashList()
    ]);
}

async function refreshDevices() {
    await loadDevicesPage();
    showToast('Device data refreshed', 'success');
}

async function loadDeviceSummary() {
    try {
        const data = await fetchAPI('/api/devices/summary');
        
        document.getElementById('devicesOnline').textContent = data.online_devices || 0;
        document.getElementById('devicesOffline').textContent = data.offline_devices || 0;
        document.getElementById('devicesCrashes24h').textContent = data.crashes_24h || 0;
        
        // Format average uptime
        const avgSeconds = data.avg_uptime_seconds || 0;
        document.getElementById('devicesAvgUptime').textContent = formatDuration(avgSeconds);
        
    } catch (e) {
        console.error('Error loading device summary:', e);
    }
}

async function loadDevicesList() {
    const el = document.getElementById('devicesList');
    if (!el) return;
    
    try {
        const devices = await fetchAPI('/api/devices');
        
        if (!devices || devices.length === 0) {
            el.innerHTML = '<div class="no-data">No devices found</div>';
            return;
        }
        
        // Also populate the crash filter dropdown
        const filterEl = document.getElementById('crashDeviceFilter');
        if (filterEl) {
            filterEl.innerHTML = '<option value="">All Devices</option>' +
                devices.map(d => `<option value="${d.uuid}">${d.uuid}</option>`).join('');
        }
        
        el.innerHTML = `
            <table class="devices-table">
                <thead>
                    <tr>
                        <th>Status</th>
                        <th>Device</th>
                        <th>Instance</th>
                        <th>Account</th>
                        <th>Crashes</th>
                        <th>Uptime %</th>
                        <th>Last Seen</th>
                        <th>Actions</th>
                    </tr>
                </thead>
                <tbody>
                    ${devices.map(d => `
                        <tr class="${d.online ? 'online' : 'offline'}">
                            <td>
                                <span class="status-indicator ${d.online ? 'online' : 'offline'}">
                                    ${d.online ? '🟢' : '🔴'}
                                </span>
                            </td>
                            <td class="device-name" onclick="showDeviceDetail('${d.uuid}')">
                                ${d.uuid || 'Unknown'}
                                ${d.origin ? `<small class="device-origin">${d.origin}</small>` : ''}
                            </td>
                            <td>${d.instance || '-'}</td>
                            <td>${d.account || '-'}</td>
                            <td class="crash-count ${(d.total_crashes || 0) > 5 ? 'danger' : ''}">
                                ${d.total_crashes || 0}
                            </td>
                            <td class="uptime ${(d.uptime_percent || 0) < 50 ? 'danger' : (d.uptime_percent || 0) < 80 ? 'warning' : 'success'}">
                                ${(d.uptime_percent || 0).toFixed(1)}%
                            </td>
                            <td>${formatTimeAgo(d.last_seen || d.last_seen_shellder)}</td>
                            <td>
                                <button class="btn btn-sm btn-icon" onclick="showDeviceDetail('${d.uuid}')" title="Details">📊</button>
                                <button class="btn btn-sm btn-icon" onclick="showDeviceCrashes('${d.uuid}')" title="Crashes">💥</button>
                                <button class="btn btn-sm btn-icon" onclick="searchDeviceLogs('${d.uuid}')" title="Search Logs">🔍</button>
                            </td>
                        </tr>
                    `).join('')}
                </tbody>
            </table>
        `;
        
        // Setup search
        const searchEl = document.getElementById('deviceSearch');
        if (searchEl) {
            searchEl.addEventListener('input', (e) => {
                const term = e.target.value.toLowerCase();
                el.querySelectorAll('tbody tr').forEach(tr => {
                    const text = tr.textContent.toLowerCase();
                    tr.style.display = text.includes(term) ? '' : 'none';
                });
            });
        }
        
    } catch (e) {
        el.innerHTML = `<div class="error-msg">Failed to load devices: ${e.message}</div>`;
    }
}

async function loadCrashList(deviceName = null) {
    const el = document.getElementById('crashList');
    if (!el) return;
    
    try {
        const url = deviceName 
            ? `/api/devices/${deviceName}/crashes?limit=50`
            : '/api/devices/crashes?limit=50';
        const crashes = await fetchAPI(url);
        
        if (!crashes || crashes.length === 0) {
            el.innerHTML = '<div class="no-data">No crashes recorded</div>';
            return;
        }
        
        el.innerHTML = crashes.map(c => `
            <div class="crash-item ${c.resolved ? 'resolved' : ''}" onclick="showCrashContext(${c.id})">
                <div class="crash-header">
                    <span class="crash-type ${c.type}">${getCrashIcon(c.type)} ${c.type}</span>
                    <span class="crash-time">${formatTimeAgo(c.time)}</span>
                </div>
                <div class="crash-device">${c.device}</div>
                <div class="crash-message">${truncate(c.message, 100)}</div>
                <div class="crash-source">
                    <span class="log-source">${c.log_source}</span>
                    ${c.line_start ? `<span class="log-line">Line ${c.line_start}</span>` : ''}
                    ${c.is_startup ? '<span class="startup-badge">STARTUP</span>' : ''}
                </div>
            </div>
        `).join('');
        
    } catch (e) {
        el.innerHTML = `<div class="error-msg">Failed to load crashes: ${e.message}</div>`;
    }
}

function getCrashIcon(type) {
    const icons = {
        'disconnect': '🔌',
        'worker_disconnect': '👷',
        'error': '❌',
        'crash': '💥',
        'timeout': '⏰',
        'failed': '⚠️',
        'account_banned': '🚫',
        'no_account': '👤',
        'task_failed': '📋',
        'connection_refused': '🔒'
    };
    return icons[type] || '❓';
}

function filterCrashes() {
    const device = document.getElementById('crashDeviceFilter').value;
    loadCrashList(device || null);
}

async function showCrashContext(crashId) {
    currentCrashId = crashId;
    
    try {
        const data = await fetchAPI(`/api/devices/crashes/${crashId}/context?lines=50`);
        
        if (data.error) {
            showToast(`Error: ${data.error}`, 'error');
            return;
        }
        
        // Update modal info
        document.getElementById('logContextDevice').textContent = `Device: ${data.device}`;
        document.getElementById('logContextType').textContent = `Type: ${data.type}`;
        document.getElementById('logContextTime').textContent = `Time: ${formatTimeAgo(data.time)}`;
        
        if (data.context_range) {
            document.getElementById('logContextRange').textContent = 
                `Lines ${data.context_range.start} - ${data.context_range.end}`;
            currentLogLine = data.context_range.crash_line;
        }
        
        currentLogContainer = data.log_source;
        
        // Display log content with highlighted crash line
        const logEl = document.getElementById('logContextContent');
        const context = data.live_context || data.stored_context || 'No log context available';
        logEl.innerHTML = highlightCrashLine(context, data.message);
        
        // Show modal
        document.getElementById('logContextModal').style.display = 'flex';
        
    } catch (e) {
        showToast(`Failed to load crash context: ${e.message}`, 'error');
    }
}

function highlightCrashLine(logContent, crashMessage) {
    if (!crashMessage) return escapeHtml(logContent);
    
    const lines = logContent.split('\n');
    return lines.map(line => {
        if (line.includes(crashMessage.substring(0, 50))) {
            return `<span class="crash-highlight">${escapeHtml(line)}</span>`;
        }
        return escapeHtml(line);
    }).join('\n');
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

async function loadMoreContext(delta) {
    if (!currentLogContainer || currentLogLine === null) return;
    
    const newLine = currentLogLine + delta;
    if (newLine < 0) return;
    
    try {
        const data = await fetchAPI(
            `/api/devices/log-context/${currentLogContainer}/${newLine}?lines=50`
        );
        
        if (data.error) {
            showToast(data.error, 'error');
            return;
        }
        
        document.getElementById('logContextRange').textContent = 
            `Lines ${data.range.start} - ${data.range.end}`;
        document.getElementById('logContextContent').textContent = data.context;
        currentLogLine = newLine;
        
    } catch (e) {
        showToast(`Failed to load context: ${e.message}`, 'error');
    }
}

function closeLogModal() {
    document.getElementById('logContextModal').style.display = 'none';
    currentCrashId = null;
}

async function showDeviceDetail(deviceName) {
    const modal = document.getElementById('deviceDetailModal');
    const content = document.getElementById('deviceDetailContent');
    
    modal.style.display = 'flex';
    content.innerHTML = '<div class="loading">Loading device details...</div>';
    
    try {
        const device = await fetchAPI(`/api/devices/${deviceName}`);
        
        if (device.error) {
            content.innerHTML = `<div class="error-msg">${device.error}</div>`;
            return;
        }
        
        content.innerHTML = `
            <div class="device-detail">
                <div class="device-detail-header">
                    <span class="status-indicator ${device.online ? 'online' : 'offline'}">
                        ${device.online ? '🟢 Online' : '🔴 Offline'}
                    </span>
                    <h2>${device.uuid}</h2>
                </div>
                
                <div class="device-detail-grid">
                    <div class="detail-section">
                        <h4>Current Session</h4>
                        <div class="detail-row">
                            <span>Instance:</span>
                            <span>${device.instance || '-'}</span>
                        </div>
                        <div class="detail-row">
                            <span>Account:</span>
                            <span>${device.account || '-'}</span>
                        </div>
                        <div class="detail-row">
                            <span>Worker ID:</span>
                            <span>${device.worker_id || '-'}</span>
                        </div>
                        <div class="detail-row">
                            <span>Origin:</span>
                            <span>${device.origin || '-'}</span>
                        </div>
                        <div class="detail-row">
                            <span>Version:</span>
                            <span>${device.version || '-'}</span>
                        </div>
                    </div>
                    
                    <div class="detail-section">
                        <h4>Statistics</h4>
                        <div class="detail-row">
                            <span>Total Connections:</span>
                            <span>${device.total_connections || 0}</span>
                        </div>
                        <div class="detail-row">
                            <span>Disconnections:</span>
                            <span>${device.total_disconnections || 0}</span>
                        </div>
                        <div class="detail-row">
                            <span>Crashes:</span>
                            <span class="${(device.total_crashes || 0) > 5 ? 'text-danger' : ''}">${device.total_crashes || 0}</span>
                        </div>
                        <div class="detail-row">
                            <span>Uptime:</span>
                            <span>${formatDuration(device.total_uptime_seconds || 0)}</span>
                        </div>
                        <div class="detail-row">
                            <span>Uptime %:</span>
                            <span class="${(device.uptime_percent || 0) < 50 ? 'text-danger' : ''}">${(device.uptime_percent || 0).toFixed(1)}%</span>
                        </div>
                        <div class="detail-row">
                            <span>Crash Rate:</span>
                            <span>${device.crash_rate || 0}/hour</span>
                        </div>
                    </div>
                    
                    <div class="detail-section">
                        <h4>Timeline</h4>
                        <div class="detail-row">
                            <span>First Seen:</span>
                            <span>${formatTimeAgo(device.first_seen)}</span>
                        </div>
                        <div class="detail-row">
                            <span>Last Seen:</span>
                            <span>${formatTimeAgo(device.last_seen || device.last_seen_shellder)}</span>
                        </div>
                        <div class="detail-row">
                            <span>Last Connect:</span>
                            <span>${formatTimeAgo(device.last_connect)}</span>
                        </div>
                        <div class="detail-row">
                            <span>Last Disconnect:</span>
                            <span>${formatTimeAgo(device.last_disconnect)}</span>
                        </div>
                    </div>
                </div>
                
                ${device.recent_crashes && device.recent_crashes.length > 0 ? `
                <div class="detail-section full-width">
                    <h4>Recent Crashes</h4>
                    <div class="recent-crashes-list">
                        ${device.recent_crashes.map(c => `
                            <div class="crash-mini" onclick="showCrashContext(${c.id})">
                                <span class="crash-type">${getCrashIcon(c.type)} ${c.type}</span>
                                <span class="crash-message">${truncate(c.message, 60)}</span>
                                <span class="crash-time">${formatTimeAgo(c.time)}</span>
                            </div>
                        `).join('')}
                    </div>
                </div>
                ` : ''}
            </div>
        `;
        
    } catch (e) {
        content.innerHTML = `<div class="error-msg">Failed to load device: ${e.message}</div>`;
    }
}

function closeDeviceModal() {
    document.getElementById('deviceDetailModal').style.display = 'none';
}

async function showDeviceCrashes(deviceName) {
    document.getElementById('crashDeviceFilter').value = deviceName;
    await loadCrashList(deviceName);
    
    // Scroll to crash list
    document.querySelector('.crashes-card').scrollIntoView({ behavior: 'smooth' });
}

async function searchDeviceLogs(deviceName) {
    const term = prompt(`Search logs for device: ${deviceName}\n\nEnter additional search term (optional):`, '');
    
    if (term === null) return; // Cancelled
    
    try {
        const results = await fetchAPI(
            `/api/devices/search-logs?device=${encodeURIComponent(deviceName)}&keyword=${encodeURIComponent(term)}`
        );
        
        if (results.total === 0) {
            showToast('No matching log entries found', 'info');
            return;
        }
        
        // Show results in a modal-like display
        const content = document.getElementById('logContextContent');
        const formattedResults = results.results.map(r => 
            `[${r.container}:${r.line}] ${r.content}`
        ).join('\n\n');
        
        document.getElementById('logContextDevice').textContent = `Search: ${deviceName}`;
        document.getElementById('logContextType').textContent = `Term: ${term || '(none)'}`;
        document.getElementById('logContextTime').textContent = `Found: ${results.total} results`;
        document.getElementById('logContextRange').textContent = '';
        content.textContent = formattedResults;
        
        document.getElementById('logContextModal').style.display = 'flex';
        
    } catch (e) {
        showToast(`Search failed: ${e.message}`, 'error');
    }
}

function formatDuration(seconds) {
    if (!seconds || seconds < 0) return '-';
    
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    
    if (hours > 24) {
        const days = Math.floor(hours / 24);
        return `${days}d ${hours % 24}h`;
    }
    if (hours > 0) {
        return `${hours}h ${minutes}m`;
    }
    return `${minutes}m`;
}

function formatTimeAgo(timestamp) {
    if (!timestamp) return '-';
    
    try {
        const d = new Date(timestamp);
        const now = new Date();
        const diff = (now - d) / 1000;
        
        if (diff < 60) return 'Just now';
        if (diff < 3600) return `${Math.floor(diff/60)}m ago`;
        if (diff < 86400) return `${Math.floor(diff/3600)}h ago`;
        if (diff < 604800) return `${Math.floor(diff/86400)}d ago`;
        return d.toLocaleDateString();
    } catch {
        return timestamp;
    }
}

function truncate(str, len) {
    if (!str) return '';
    return str.length > len ? str.substring(0, len) + '...' : str;
}

// =============================================================================
// STACK DATABASE FUNCTIONS (Cross-Reference with MariaDB)
// =============================================================================

async function loadStackData() {
    await Promise.all([
        loadStackConnection(),
        loadStackSummary(),
        loadStackDevices()
    ]);
}

async function refreshStackData() {
    await loadStackData();
    showToast('Stack data refreshed', 'success');
}

async function loadStackConnection() {
    const el = document.getElementById('stackConnection');
    if (!el) return;
    
    try {
        const data = await fetchAPI('/api/stack/test');
        if (data.connected) {
            el.innerHTML = `
                <div class="connection-success">
                    <span class="status-dot online"></span>
                    <span>Connected to MariaDB ${data.version || ''}</span>
                </div>
            `;
            el.classList.add('connected');
        } else {
            el.innerHTML = `
                <div class="connection-error">
                    <span class="status-dot offline"></span>
                    <span>Cannot connect to stack database: ${data.error || 'Unknown error'}</span>
                    <small>Make sure database container is running and .env is configured</small>
                </div>
            `;
        }
    } catch (e) {
        el.innerHTML = `
            <div class="connection-error">
                <span class="status-dot offline"></span>
                <span>API Error: ${e.message}</span>
            </div>
        `;
    }
}

async function loadStackSummary() {
    try {
        const [golbat, dragonite, koji, efficiency] = await Promise.all([
            fetchAPI('/api/stack/golbat'),
            fetchAPI('/api/stack/dragonite'),
            fetchAPI('/api/stack/koji'),
            fetchAPI('/api/stack/efficiency')
        ]);
        
        // Update header stats
        if (!golbat.error) {
            document.getElementById('stackPokemon').textContent = 
                formatNumber(golbat.active_pokemon || golbat.pokemon_count || 0);
        }
        if (!dragonite.error) {
            document.getElementById('stackAccounts').textContent = 
                formatNumber(dragonite.active_accounts || 0);
            document.getElementById('stackDevices').textContent = 
                formatNumber(dragonite.online_devices || 0);
        }
        if (!efficiency.error) {
            document.getElementById('stackEfficiency').textContent = 
                formatNumber(efficiency.pokemon_per_hour || 0);
        }
        
        // Update Scanner Stats panel
        updateScannerStats(dragonite);
        
        // Update Account Stats panel
        updateAccountStats(dragonite);
        
        // Update Golbat Stats panel
        updateGolbatStats(golbat);
        
        // Update Koji Stats panel
        updateKojiStats(koji);
        
    } catch (e) {
        console.error('Failed to load stack summary:', e);
    }
}

function updateScannerStats(data) {
    const el = document.getElementById('scannerStats');
    if (!el) return;
    
    if (data.error) {
        el.innerHTML = `<div class="error-msg">${data.error}</div>`;
        return;
    }
    
    el.innerHTML = `
        <div class="stat-list">
            <div class="stat-row">
                <span class="stat-name">📱 Total Devices</span>
                <span class="stat-val">${formatNumber(data.total_devices || 0)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">🟢 Online Devices</span>
                <span class="stat-val success">${formatNumber(data.online_devices || 0)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">📋 Total Instances</span>
                <span class="stat-val">${formatNumber(data.total_instances || 0)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">🔄 Active Last Hour</span>
                <span class="stat-val">${formatNumber(data.active_last_hour || 0)}</span>
            </div>
        </div>
        ${data.instances && data.instances.length > 0 ? `
        <div class="instances-list">
            <h4>Active Instances</h4>
            ${data.instances.map(i => `
                <div class="instance-row">
                    <span class="instance-name">${i.name}</span>
                    <span class="instance-type">${i.type}</span>
                </div>
            `).join('')}
        </div>
        ` : ''}
    `;
}

function updateAccountStats(data) {
    const el = document.getElementById('accountStats');
    if (!el) return;
    
    if (data.error) {
        el.innerHTML = `<div class="error-msg">${data.error}</div>`;
        return;
    }
    
    const total = data.total_accounts || 0;
    const active = data.active_accounts || 0;
    const banned = data.banned_accounts || 0;
    const authBanned = data.auth_banned_accounts || 0;
    const warned = data.warned_accounts || 0;
    
    el.innerHTML = `
        <div class="stat-list">
            <div class="stat-row">
                <span class="stat-name">📊 Total Accounts</span>
                <span class="stat-val">${formatNumber(total)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">✅ Active/Usable</span>
                <span class="stat-val success">${formatNumber(active)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">🔑 With Refresh Token</span>
                <span class="stat-val">${formatNumber(data.with_refresh_token || 0)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">⚠️ Warned</span>
                <span class="stat-val warning">${formatNumber(warned)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">🚫 Banned</span>
                <span class="stat-val danger">${formatNumber(banned)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">🔒 Auth Banned</span>
                <span class="stat-val danger">${formatNumber(authBanned)}</span>
            </div>
        </div>
        ${data.by_provider ? `
        <div class="provider-breakdown">
            <h4>By Provider</h4>
            ${Object.entries(data.by_provider).map(([prov, cnt]) => `
                <div class="provider-row">
                    <span>${prov}</span>
                    <span>${formatNumber(cnt)}</span>
                </div>
            `).join('')}
        </div>
        ` : ''}
    `;
}

function updateGolbatStats(data) {
    const el = document.getElementById('golbatStats');
    if (!el) return;
    
    if (data.error) {
        el.innerHTML = `<div class="error-msg">${data.error}</div>`;
        return;
    }
    
    el.innerHTML = `
        <div class="stat-list">
            <div class="stat-row">
                <span class="stat-name">📍 Active Pokemon</span>
                <span class="stat-val success">${formatNumber(data.active_pokemon || 0)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">📦 Total Pokemon (DB)</span>
                <span class="stat-val">${formatNumber(data.pokemon_count || 0)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">🏪 Pokestops</span>
                <span class="stat-val">${formatNumber(data.pokestop_count || 0)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">🏟️ Gyms</span>
                <span class="stat-val">${formatNumber(data.gym_count || 0)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">⚔️ Active Raids</span>
                <span class="stat-val">${formatNumber(data.active_raids || 0)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">📡 Spawnpoints</span>
                <span class="stat-val">${formatNumber(data.spawnpoint_count || 0)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">⏱️ Last Hour</span>
                <span class="stat-val">${formatNumber(data.pokemon_last_hour || 0)}</span>
            </div>
        </div>
        ${data.gyms_by_team ? `
        <div class="gym-teams">
            <h4>Gyms by Team</h4>
            ${Object.entries(data.gyms_by_team).map(([team, cnt]) => `
                <div class="team-row ${team.toLowerCase()}">
                    <span>${team}</span>
                    <span>${formatNumber(cnt)}</span>
                </div>
            `).join('')}
        </div>
        ` : ''}
    `;
}

function updateKojiStats(data) {
    const el = document.getElementById('kojiStats');
    if (!el) return;
    
    if (data.error) {
        el.innerHTML = `<div class="error-msg">${data.error}</div>`;
        return;
    }
    
    el.innerHTML = `
        <div class="stat-list">
            <div class="stat-row">
                <span class="stat-name">📐 Total Geofences</span>
                <span class="stat-val">${formatNumber(data.total_geofences || 0)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">🛤️ Total Routes</span>
                <span class="stat-val">${formatNumber(data.total_routes || 0)}</span>
            </div>
            <div class="stat-row">
                <span class="stat-name">📁 Projects</span>
                <span class="stat-val">${formatNumber(data.total_projects || 0)}</span>
            </div>
        </div>
        ${data.geofences_by_mode ? `
        <div class="mode-breakdown">
            <h4>Geofences by Mode</h4>
            ${Object.entries(data.geofences_by_mode).map(([mode, cnt]) => `
                <div class="mode-row">
                    <span>${mode}</span>
                    <span>${formatNumber(cnt)}</span>
                </div>
            `).join('')}
        </div>
        ` : ''}
    `;
}

async function loadStackDevices() {
    const el = document.getElementById('deviceList');
    const countEl = document.getElementById('deviceCount');
    if (!el) return;
    
    try {
        const devices = await fetchAPI('/api/stack/devices');
        
        if (!Array.isArray(devices) || devices.length === 0) {
            el.innerHTML = '<div class="no-data">No devices found in database</div>';
            if (countEl) countEl.textContent = '0 devices';
            return;
        }
        
        if (countEl) countEl.textContent = `${devices.length} device${devices.length !== 1 ? 's' : ''}`;
        
        el.innerHTML = `
            <div class="device-grid">
                ${devices.map(d => `
                    <div class="device-card ${d.online ? 'online' : 'offline'}">
                        <div class="device-header">
                            <span class="device-status ${d.online ? 'online' : 'offline'}">●</span>
                            <span class="device-uuid">${d.uuid || 'Unknown'}</span>
                        </div>
                        <div class="device-info">
                            <div class="device-row">
                                <span>Instance:</span>
                                <span>${d.instance || '-'}</span>
                            </div>
                            <div class="device-row">
                                <span>Account:</span>
                                <span>${d.account || '-'}</span>
                            </div>
                            <div class="device-row">
                                <span>Host:</span>
                                <span>${d.host || '-'}</span>
                            </div>
                            <div class="device-row">
                                <span>Last Seen:</span>
                                <span>${d.last_seen ? formatTime(d.last_seen) : '-'}</span>
                            </div>
                        </div>
                    </div>
                `).join('')}
            </div>
        `;
    } catch (e) {
        el.innerHTML = `<div class="error-msg">Failed to load devices: ${e.message}</div>`;
    }
}

function formatNumber(num) {
    if (num === null || num === undefined || num === 'N/A') return '-';
    const n = parseInt(num);
    if (isNaN(n)) return num;
    return n.toLocaleString();
}

function formatTime(isoString) {
    if (!isoString) return '-';
    const d = new Date(isoString);
    const now = new Date();
    const diff = (now - d) / 1000;
    
    if (diff < 60) return 'Just now';
    if (diff < 3600) return `${Math.floor(diff/60)}m ago`;
    if (diff < 86400) return `${Math.floor(diff/3600)}h ago`;
    return d.toLocaleDateString();
}
