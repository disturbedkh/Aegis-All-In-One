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
let debugMode = false;

// =============================================================================
// REQUEST DEDUPLICATION & THROTTLING
// =============================================================================
const RequestManager = {
    inFlight: new Map(),     // Track in-flight requests
    lastCall: new Map(),     // Track last call time per endpoint
    throttleMs: {
        '/api/status': 5000,        // Max once per 5s
        '/api/metrics/sparklines': 10000,  // Max once per 10s
        '/api/xilriws/stats': 5000,  // Max once per 5s
        '/api/services': 10000,      // Max once per 10s (reduced from 30s)
        '/api/containers/updates': 60000,  // Max once per 60s (image updates are slow to check)
        '/api/sites/check': 15000    // Max once per 15s
    },
    callCounts: new Map(),   // Track call counts for logging
    
    // Check if request should be throttled
    shouldThrottle(endpoint) {
        const throttle = this.throttleMs[endpoint];
        if (!throttle) return false;
        
        const lastTime = this.lastCall.get(endpoint) || 0;
        const elapsed = Date.now() - lastTime;
        return elapsed < throttle;
    },
    
    // Check if request is already in-flight
    isInFlight(endpoint) {
        return this.inFlight.has(endpoint);
    },
    
    // Register request start
    start(endpoint, promise) {
        this.inFlight.set(endpoint, promise);
        this.lastCall.set(endpoint, Date.now());
        
        // Track call counts
        const count = (this.callCounts.get(endpoint) || 0) + 1;
        this.callCounts.set(endpoint, count);
        
        // Clean up when done
        promise.finally(() => this.inFlight.delete(endpoint));
    },
    
    // Get existing in-flight request
    getInFlight(endpoint) {
        return this.inFlight.get(endpoint);
    },
    
    // Get call count for an endpoint
    getCallCount(endpoint) {
        return this.callCounts.get(endpoint) || 0;
    }
};

// =============================================================================
// COMPREHENSIVE DEBUG LOGGING SYSTEM (AI-FRIENDLY)
// =============================================================================

const SHELLDER_DEBUG = {
    enabled: true,
    logs: [],
    maxLogs: 5000,
    startTime: Date.now(),
    
    // Log levels
    LEVEL: { TRACE: 0, DEBUG: 1, INFO: 2, WARN: 3, ERROR: 4, FATAL: 5 },
    levelNames: ['TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'],
    
    // Core logging function
    log(level, category, message, data = null) {
        if (!this.enabled) return;
        
        const entry = {
            ts: Date.now(),
            elapsed: Date.now() - this.startTime,
            level: this.levelNames[level] || 'UNKNOWN',
            cat: category,
            msg: message,
            data: data,
            stack: level >= this.LEVEL.ERROR ? new Error().stack : null,
            url: window.location.href,
            page: currentPage,
            wsConnected: wsConnected
        };
        
        this.logs.push(entry);
        if (this.logs.length > this.maxLogs) this.logs.shift();
        
        // Also console log with color
        const colors = { TRACE: 'gray', DEBUG: 'blue', INFO: 'green', WARN: 'orange', ERROR: 'red', FATAL: 'darkred' };
        console.log(
            `%c[${entry.level}] %c[${category}] %c${message}`,
            `color: ${colors[entry.level]}; font-weight: bold`,
            'color: purple',
            'color: inherit',
            data || ''
        );
        
        return entry;
    },
    
    // Convenience methods
    trace(cat, msg, data) { return this.log(this.LEVEL.TRACE, cat, msg, data); },
    debug(cat, msg, data) { return this.log(this.LEVEL.DEBUG, cat, msg, data); },
    info(cat, msg, data) { return this.log(this.LEVEL.INFO, cat, msg, data); },
    warn(cat, msg, data) { return this.log(this.LEVEL.WARN, cat, msg, data); },
    error(cat, msg, data) { return this.log(this.LEVEL.ERROR, cat, msg, data); },
    fatal(cat, msg, data) { return this.log(this.LEVEL.FATAL, cat, msg, data); },
    
    // Function call tracer
    fn(name, args = {}) {
        const startTime = performance.now();
        this.trace('FN_CALL', `→ ${name}()`, { args, startTime });
        return {
            end: (result = null) => {
                const duration = performance.now() - startTime;
                this.trace('FN_RETURN', `← ${name}() [${duration.toFixed(2)}ms]`, { result, duration });
                return result;
            },
            error: (err) => {
                const duration = performance.now() - startTime;
                this.error('FN_ERROR', `✗ ${name}() failed [${duration.toFixed(2)}ms]`, { error: err.message, stack: err.stack, duration });
                throw err;
            }
        };
    },
    
    // Event logger
    event(type, target, details = {}) {
        this.debug('EVENT', `${type} on ${target}`, {
            type, target, details,
            timestamp: Date.now()
        });
    },
    
    // State change logger
    state(name, oldVal, newVal) {
        this.info('STATE', `${name}: ${JSON.stringify(oldVal)} → ${JSON.stringify(newVal)}`, {
            name, oldVal, newVal, timestamp: Date.now()
        });
    },
    
    // API call logger
    api(method, endpoint, status, duration, response = null, error = null) {
        const level = error ? this.LEVEL.ERROR : (status >= 400 ? this.LEVEL.WARN : this.LEVEL.DEBUG);
        this.log(level, 'API', `${method} ${endpoint} → ${status} [${duration}ms]`, {
            method, endpoint, status, duration, response, error
        });
    },
    
    // DOM state snapshot
    domSnapshot() {
        return {
            navItems: Array.from(document.querySelectorAll('.nav-item')).map(el => ({
                page: el.dataset.page,
                active: el.classList.contains('active'),
                visible: el.offsetParent !== null,
                onclick: el.onclick ? 'set' : 'null',
                listeners: el._listeners || 'unknown'
            })),
            pages: Array.from(document.querySelectorAll('.page')).map(el => ({
                id: el.id,
                active: el.classList.contains('active'),
                visible: el.offsetParent !== null
            })),
            modals: Array.from(document.querySelectorAll('.modal')).map(el => ({
                id: el.id,
                active: el.classList.contains('active'),
                display: getComputedStyle(el).display
            })),
            body: {
                overflow: document.body.style.overflow,
                pointerEvents: getComputedStyle(document.body).pointerEvents
            }
        };
    },
    
    // Full system state dump
    getState() {
        return {
            timestamp: Date.now(),
            elapsed: Date.now() - this.startTime,
            config: {
                apiBase: API_BASE,
                currentPage,
                wsConnected,
                debugMode,
                refreshInterval: refreshInterval ? 'active' : 'inactive'
            },
            browser: {
                userAgent: navigator.userAgent,
                url: window.location.href,
                viewport: { w: window.innerWidth, h: window.innerHeight },
                online: navigator.onLine
            },
            dom: this.domSnapshot(),
            logs: this.logs.slice(-100), // Last 100 logs
            errors: this.logs.filter(l => l.level === 'ERROR' || l.level === 'FATAL')
        };
    },
    
    // Export all logs as JSON
    export() {
        const data = {
            exportTime: new Date().toISOString(),
            totalLogs: this.logs.length,
            state: this.getState(),
            allLogs: this.logs
        };
        return JSON.stringify(data, null, 2);
    },
    
    // Copy to clipboard
    copyToClipboard() {
        const json = this.export();
        navigator.clipboard.writeText(json).then(() => {
            this.info('EXPORT', 'Logs copied to clipboard', { size: json.length });
            alert('Debug logs copied to clipboard!');
        });
    },
    
    // Download as file
    download() {
        const json = this.export();
        const blob = new Blob([json], { type: 'application/json' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `shellder-debug-${Date.now()}.json`;
        a.click();
        URL.revokeObjectURL(url);
        this.info('EXPORT', 'Logs downloaded', { size: json.length });
    },
    
    // Send to server
    async sendToServer() {
        try {
            const response = await fetch('/api/debug/client-logs', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: this.export()
            });
            if (response.ok) {
                this.info('EXPORT', 'Logs sent to server');
                return true;
            }
        } catch (e) {
            // Silent fail - server might not be ready
            console.warn('Failed to send logs to server:', e.message);
        }
        return false;
    },
    
    // Auto-sync to server (5 minutes during development)
    startAutoSync(intervalMs = 300000) {
        if (this._autoSyncInterval) return;
        
        this._autoSyncInterval = setInterval(() => {
            // Only sync if there are new logs since last sync
            if (this.logs.length > 0 && this._lastSyncCount !== this.logs.length) {
                this._lastSyncCount = this.logs.length;
                this.sendToServer();
            }
        }, intervalMs);
        
        this._lastSyncCount = 0;
        
        // Only send on page unload if there are unsent logs
        window.addEventListener('beforeunload', () => {
            if (this.logs.length > this._lastSyncCount) {
                // Compact export for beacon (limit size)
                const compactData = JSON.stringify({
                    t: new Date().toISOString(),
                    errors: this.logs.filter(l => l.level === 'ERROR' || l.level === 'FATAL').slice(-20),
                    recent: this.logs.slice(-50)
                });
                navigator.sendBeacon('/api/debug/client-logs', compactData);
            }
        });
        
        this.info('SYNC', 'Auto-sync started', { intervalMs, note: 'Only syncs errors/unload for efficiency' });
    }
};

// Auto-start sync after 10 seconds (don't rush)
setTimeout(() => SHELLDER_DEBUG.startAutoSync(), 10000);

// Expose globally for console access
window.SHELLDER_DEBUG = SHELLDER_DEBUG;
window.SD = SHELLDER_DEBUG; // Short alias

// Track meaningful click events only (buttons, links, nav items)
document.addEventListener('click', (e) => {
    const target = e.target;
    
    // Only log clicks on interactive elements to reduce noise
    const isInteractive = target.closest('button, a, .nav-item, .btn, [onclick], [data-action]');
    if (!isInteractive) return;
    
    const path = [];
    let el = target;
    while (el && el !== document.body && path.length < 3) {
        let selector = el.tagName.toLowerCase();
        if (el.id) selector += `#${el.id}`;
        else if (el.className && typeof el.className === 'string') {
            const classes = el.className.split(' ').filter(c => c && !c.startsWith('_')).slice(0, 2);
            if (classes.length) selector += `.${classes.join('.')}`;
        }
        path.push(selector);
        el = el.parentElement;
    }
    
    // Compact logging
    SHELLDER_DEBUG.debug('CLICK', path.reverse().join(' > '), {
        id: target.id || undefined,
        action: target.dataset?.action || target.dataset?.page || undefined
    });
}, true);

// Track errors
window.addEventListener('error', (e) => {
    SHELLDER_DEBUG.fatal('JS_ERROR', e.message, {
        filename: e.filename,
        lineno: e.lineno,
        colno: e.colno,
        error: e.error?.stack
    });
});

window.addEventListener('unhandledrejection', (e) => {
    SHELLDER_DEBUG.fatal('PROMISE_REJECT', 'Unhandled promise rejection', {
        reason: e.reason?.message || e.reason,
        stack: e.reason?.stack
    });
});

// Debug helper (existing)
function updateDebug(key, value, isError = false) {
    const el = document.getElementById(`debug${key}`);
    if (el) {
        el.textContent = value;
        el.style.color = isError ? '#ef4444' : '#22c55e';
    }
}

function toggleDebugPanel() {
    const panel = document.getElementById('debugPanel');
    if (panel) {
        debugMode = !debugMode;
        panel.style.display = debugMode ? 'block' : 'none';
        if (debugMode) {
            updateDebug('JS', 'loaded ✓');
            updateDebug('API', wsConnected ? 'connected ✓' : 'polling...');
            updateDebug('WS', wsConnected ? 'live ✓' : 'not connected');
            updateDebug('LogCount', SHELLDER_DEBUG.logs.length);
        }
    }
    SHELLDER_DEBUG.state('debugMode', !debugMode, debugMode);
}

// Download the server-side unified debug log
async function downloadServerDebugLog() {
    SHELLDER_DEBUG.info('DEBUG', 'Downloading server debug log');
    window.location.href = '/api/debug/debuglog/download';
}

// View the server debug log in a modal
async function viewDebugLog() {
    SHELLDER_DEBUG.info('DEBUG', 'Viewing server debug log');
    openModal('🔧 Server Debug Log (debuglog.txt)', '<div class="loading">Loading debug log...</div>');
    
    try {
        const response = await fetch('/api/debug/debuglog?lines=300&format=json');
        const data = await response.json();
        
        if (data.error) {
            document.getElementById('modalBody').innerHTML = `<div class="text-danger">Error: ${data.error}</div>`;
            return;
        }
        
        document.getElementById('modalBody').innerHTML = `
            <div style="margin-bottom: 10px; font-size: 12px; color: var(--text-muted);">
                File: ${data.path}<br>
                Total lines: ${data.total_lines} | Showing: ${data.returned_lines} | Size: ${(data.size_bytes/1024).toFixed(1)}KB
            </div>
            <div style="display: flex; gap: 8px; margin-bottom: 10px;">
                <button class="btn btn-sm" onclick="downloadServerDebugLog()">📥 Download Full</button>
                <button class="btn btn-sm" onclick="viewDebugLog()">🔄 Refresh</button>
                <button class="btn btn-sm" onclick="clearServerDebugLog()">🗑️ Clear</button>
            </div>
            <pre class="log-viewer" style="max-height: 400px; overflow: auto; font-size: 11px; white-space: pre-wrap; word-break: break-all;">${escapeHtml(data.lines.join('\n'))}</pre>
        `;
    } catch (e) {
        document.getElementById('modalBody').innerHTML = `<div class="text-danger">Failed to load debug log: ${e.message}</div>`;
        SHELLDER_DEBUG.error('DEBUG', 'Failed to load debug log', { error: e.message });
    }
}

// Clear server debug log
async function clearServerDebugLog() {
    if (!confirm('Clear the server debug log?')) return;
    
    try {
        await fetch('/api/debug/clear', { method: 'POST' });
        viewDebugLog(); // Refresh
        SHELLDER_DEBUG.info('DEBUG', 'Server debug log cleared');
    } catch (e) {
        alert('Failed to clear: ' + e.message);
    }
}

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
    const trace = SHELLDER_DEBUG.fn('DOMContentLoaded');
    SHELLDER_DEBUG.info('INIT', 'DOM loaded, starting initialization', {
        readyState: document.readyState,
        url: window.location.href
    });
    
    // Log initial DOM state
    SHELLDER_DEBUG.debug('INIT', 'Initial DOM snapshot', SHELLDER_DEBUG.domSnapshot());
    
    try {
        initNavigation();
        SHELLDER_DEBUG.info('INIT', 'Navigation initialized successfully');
    } catch (e) {
        SHELLDER_DEBUG.fatal('INIT', 'Navigation init FAILED', { error: e.message, stack: e.stack });
    }
    
    try {
        initWebSocket();
        SHELLDER_DEBUG.info('INIT', 'WebSocket initialized');
    } catch (e) {
        SHELLDER_DEBUG.error('INIT', 'WebSocket init failed (non-fatal)', { error: e.message });
    }
    
    // Wrap API calls in try-catch so they don't break navigation
    try {
        refreshData();
        SHELLDER_DEBUG.info('INIT', 'Initial data refresh started');
    } catch (e) {
        SHELLDER_DEBUG.error('INIT', 'Initial refresh failed', { error: e.message });
        updateConnectionStatus(false);
    }
    
    try {
        startAutoRefresh();
        SHELLDER_DEBUG.info('INIT', 'Auto-refresh started');
    } catch (e) {
        SHELLDER_DEBUG.error('INIT', 'Auto-refresh setup failed', { error: e.message });
    }
    
    // Load Socket.IO library if not present
    if (typeof io === 'undefined') {
        SHELLDER_DEBUG.debug('INIT', 'Socket.IO not loaded, fetching from CDN');
        const script = document.createElement('script');
        script.src = 'https://cdn.socket.io/4.6.0/socket.io.min.js';
        script.onload = () => {
            SHELLDER_DEBUG.info('INIT', 'Socket.IO loaded from CDN');
            initWebSocket();
        };
        script.onerror = () => SHELLDER_DEBUG.warn('INIT', 'Socket.IO CDN not reachable');
        document.head.appendChild(script);
    }
    
    // Final DOM state
    SHELLDER_DEBUG.debug('INIT', 'Post-init DOM snapshot', SHELLDER_DEBUG.domSnapshot());
    SHELLDER_DEBUG.info('INIT', '=== GUI INITIALIZATION COMPLETE ===');
    trace.end();
});

function initNavigation() {
    const trace = SHELLDER_DEBUG.fn('initNavigation');
    
    const navItems = document.querySelectorAll('.nav-item');
    SHELLDER_DEBUG.debug('NAV', `Found ${navItems.length} nav items`, {
        items: Array.from(navItems).map(el => ({
            page: el.dataset.page,
            text: el.textContent.trim(),
            hasOnclick: !!el.onclick
        }))
    });
    
    let listenersAttached = 0;
    navItems.forEach((item, index) => {
        // Track that we're adding listener
        item._listeners = item._listeners || [];
        
        const handler = (e) => {
            SHELLDER_DEBUG.debug('NAV', `Click handler fired for nav item #${index}`, {
                page: item.dataset.page,
                eventType: e.type,
                eventTarget: e.target.tagName,
                prevented: e.defaultPrevented
            });
            e.preventDefault();
            const page = item.dataset.page;
            navigateTo(page);
        };
        
        item.addEventListener('click', handler);
        item._listeners.push('click');
        listenersAttached++;
        
        SHELLDER_DEBUG.trace('NAV', `Attached click listener to nav item #${index}`, { page: item.dataset.page });
    });
    
    SHELLDER_DEBUG.info('NAV', `Attached ${listenersAttached} click listeners`);
    
    // Also add global click handler as backup
    document.addEventListener('click', (e) => {
        const navItem = e.target.closest('.nav-item');
        if (navItem && navItem.dataset.page) {
            SHELLDER_DEBUG.debug('NAV', 'Global click handler caught nav click', { page: navItem.dataset.page });
            e.preventDefault();
            navigateTo(navItem.dataset.page);
        }
    });
    
    SHELLDER_DEBUG.debug('NAV', 'Global backup click handler attached');
    trace.end();
}

function navigateTo(page) {
    const trace = SHELLDER_DEBUG.fn('navigateTo', { page });
    const oldPage = currentPage;
    
    SHELLDER_DEBUG.info('NAV', `Navigating: ${oldPage} → ${page}`);
    
    // Update nav
    document.querySelectorAll('.nav-item').forEach(item => {
        const isActive = item.dataset.page === page;
        item.classList.toggle('active', isActive);
        SHELLDER_DEBUG.trace('NAV', `Nav item ${item.dataset.page}: active=${isActive}`);
    });
    
    // Update pages
    document.querySelectorAll('.page').forEach(p => {
        const isActive = p.id === `page-${page}`;
        p.classList.toggle('active', isActive);
        SHELLDER_DEBUG.trace('NAV', `Page ${p.id}: active=${isActive}`);
    });
    
    // Update title
    const titles = {
        'dashboard': 'Dashboard',
        'containers': 'Containers',
        'devices': 'Devices',
        'stack': 'Stack Data',
        'xilriws': 'Xilriws Auth Proxy',
        'stats': 'Statistics',
        'files': 'File Manager',
        'scripts': 'Scripts',
        'logs': 'Logs',
        'updates': 'Updates'
    };
    document.getElementById('pageTitle').textContent = titles[page] || page;
    
    SHELLDER_DEBUG.state('currentPage', oldPage, page);
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
    const startTime = performance.now();
    const method = options.method || 'GET';
    const cacheKey = `${method}:${endpoint}`;
    
    // For GET requests, check deduplication and throttling
    if (method === 'GET') {
        // If already in-flight, return existing promise
        const existing = RequestManager.getInFlight(cacheKey);
        if (existing) {
            SHELLDER_DEBUG.trace('API', `⏳ Reusing in-flight: ${endpoint}`);
            return existing;
        }
        
        // Check throttle (skip if this is a forced refresh)
        if (!options.force && RequestManager.shouldThrottle(endpoint)) {
            SHELLDER_DEBUG.trace('API', `⏸ Throttled: ${endpoint}`);
            return Promise.resolve({ _throttled: true });
        }
    }
    
    // Only log first few calls, then every 10th call to reduce spam
    const callCount = RequestManager.getCallCount(cacheKey);
    const shouldLog = callCount < 3 || callCount % 10 === 0;
    
    if (shouldLog) {
        SHELLDER_DEBUG.debug('API', `→ ${method} ${endpoint} (#${callCount + 1})`, 
            { options: Object.keys(options).length ? options : undefined });
    }
    
    const promise = (async () => {
        try {
            const response = await fetch(`${API_BASE}${endpoint}`, {
                ...options,
                headers: {
                    'Content-Type': 'application/json',
                    ...options.headers
                }
            });
            
            const duration = Math.round(performance.now() - startTime);
            const data = await response.json();
            
            // Only log errors or slow requests, not every success
            if (!response.ok || duration > 1000) {
                SHELLDER_DEBUG.api(method, endpoint, response.status, duration, 
                    response.ok ? { keys: Object.keys(data) } : data);
            }
            
            return data;
        } catch (error) {
            const duration = Math.round(performance.now() - startTime);
            SHELLDER_DEBUG.api(method, endpoint, 0, duration, null, error.message);
            throw error;
        }
    })();
    
    // Track in-flight GET requests
    if (method === 'GET') {
        RequestManager.start(cacheKey, promise);
    }
    
    return promise;
}

async function refreshData() {
    try {
        const data = await fetchAPI('/api/status');
        
        // Skip if throttled (no new data)
        if (data._throttled) return;
        
        updateDashboard(data);
        updateConnectionStatus(true, wsConnected ? 'live' : 'polling');
        updateLastUpdate();
        
        // Xilriws stats are already in /api/status response, no separate call needed
        // loadXilriwsStats(); // REMOVED - causes duplicate API calls
    } catch (error) {
        updateConnectionStatus(false);
        // Only show toast on first failure, not repeated failures
        if (!this._lastFailure || Date.now() - this._lastFailure > 30000) {
            showToast('Failed to fetch status', 'error');
            this._lastFailure = Date.now();
        }
    }
}

function startAutoRefresh() {
    // Always clear existing interval first
    if (refreshInterval) {
        clearInterval(refreshInterval);
        refreshInterval = null;
    }
    
    // Use longer interval if WebSocket is connected (less polling needed)
    // Minimum 10s to prevent API spam
    const interval = wsConnected ? 30000 : 15000;
    
    SHELLDER_DEBUG.info('REFRESH', `Auto-refresh started: ${interval / 1000}s interval`, {
        wsConnected, interval
    });
    
    refreshInterval = setInterval(refreshData, interval);
}

// =============================================================================
// DASHBOARD UPDATES
// =============================================================================

function updateDashboard(data) {
    SHELLDER_DEBUG.info('DASHBOARD', 'updateDashboard called', { hasData: !!data });
    
    try {
        // Check for local/demo mode and show notification
        if (data.local_mode && data.message) {
            showLocalModeNotice(data.message);
        }
        
        // Stats - use helper function to safely set text content
        const setElementText = (id, text) => {
            const el = document.getElementById(id);
            if (el) el.textContent = text;
            else SHELLDER_DEBUG.warn('DASHBOARD', `Element not found: ${id}`);
        };
        
        setElementText('containersRunning', data.containers?.running ?? '-');
        setElementText('containersStopped', data.containers?.stopped ?? '-');

        // CPU
        if (data.system?.cpu_percent !== undefined) {
            setElementText('cpuUsed', `${data.system.cpu_percent}%`);
        }

        if (data.system?.memory) {
            setElementText('memoryUsed', data.system.memory.percent || data.system.memory.used);
            setElementText('memoryInfo', `${data.system.memory.used} / ${data.system.memory.total}`);
        }

        if (data.system?.disk) {
            setElementText('diskUsed', data.system.disk.percent);
            setElementText('diskInfo', `${data.system.disk.used} / ${data.system.disk.total} (${data.system.disk.percent})`);
        }

        setElementText('systemUptime', data.system?.uptime || 'N/A');
        setElementText('envStatus', data.env_configured ? '✓ Configured' : '✗ Not configured');

        SHELLDER_DEBUG.info('DASHBOARD', 'setElementText calls complete, calling updateContainerList');

        // Container list
        try {
            updateContainerList(data.containers?.list || []);
        } catch (e) {
            SHELLDER_DEBUG.error('DASHBOARD', `updateContainerList failed: ${e.message}`);
        }

        SHELLDER_DEBUG.info('DASHBOARD', 'Container list done, checking xilriws');

        // Update Xilriws if available
        if (data.xilriws) {
            try {
                updateXilriwsStats(data.xilriws);
            } catch (e) {
                SHELLDER_DEBUG.error('DASHBOARD', `updateXilriwsStats failed: ${e.message}`);
            }
        }

        SHELLDER_DEBUG.info('DASHBOARD', 'About to call loadSparklines');

        // Load sparklines (will be throttled automatically by RequestManager)
        try {
            loadSparklines();
        } catch (e) {
            SHELLDER_DEBUG.error('DASHBOARD', `loadSparklines failed: ${e.message}`);
        }

        SHELLDER_DEBUG.info('DASHBOARD', 'About to call loadSystemServices');

        // Load system services status
        try {
            loadSystemServices();
        } catch (e) {
            SHELLDER_DEBUG.error('DASHBOARD', `loadSystemServices failed: ${e.message}`);
        }

        SHELLDER_DEBUG.info('DASHBOARD', 'About to call checkSiteAvailability');

        // Load site availability check
        try {
            checkSiteAvailability();
        } catch (e) {
            SHELLDER_DEBUG.error('DASHBOARD', `checkSiteAvailability failed: ${e.message}`);
        }

        SHELLDER_DEBUG.info('DASHBOARD', 'About to call loadContainerUpdates');

        // Check for container image updates (throttled - runs every 60s max)
        try {
            loadContainerUpdates();
        } catch (e) {
            SHELLDER_DEBUG.error('DASHBOARD', `loadContainerUpdates failed: ${e.message}`);
        }

        SHELLDER_DEBUG.info('DASHBOARD', 'About to check debugLogOutput');

        // Load debug panel if visible
        if (document.getElementById('debugLogOutput')) {
            try {
                loadDebugPanel();
            } catch (e) {
                SHELLDER_DEBUG.error('DASHBOARD', `loadDebugPanel failed: ${e.message}`);
            }
        }
        
        SHELLDER_DEBUG.info('DASHBOARD', 'updateDashboard complete');
    } catch (e) {
        SHELLDER_DEBUG.error('DASHBOARD', `Error in updateDashboard: ${e.message}`, { stack: e.stack });
        console.error('[DASHBOARD ERROR]', e);
    }
}

// =============================================================================
// SYSTEM SERVICES
// =============================================================================

async function loadSystemServices() {
    SHELLDER_DEBUG.info('SERVICES', 'loadSystemServices called');
    const container = document.getElementById('servicesList');
    const badge = document.getElementById('servicesStatus');
    if (!container) {
        SHELLDER_DEBUG.error('SERVICES', 'servicesList element not found!');
        return;
    }
    SHELLDER_DEBUG.debug('SERVICES', 'Container found, fetching /api/services...');
    
    try {
        // Always force on first few calls to ensure data loads
        const data = await fetchAPI('/api/services', { force: true });
        SHELLDER_DEBUG.info('SERVICES', 'Response received', { keys: data ? Object.keys(data) : 'null' });
        
        // Skip if throttled
        if (data._throttled) {
            console.log('[SERVICES] Request throttled, skipping');
            return;
        }
        
        // Check for error response
        if (data.error) {
            console.error('[SERVICES] API error:', data.error);
            container.innerHTML = `<div class="text-danger">Error: ${data.error}</div>`;
            if (badge) {
                badge.textContent = 'Error';
                badge.className = 'badge badge-danger';
            }
            return;
        }
        
        // Update badge
        if (badge && data.summary) {
            const { running, total, healthy } = data.summary;
            badge.textContent = `${running}/${total} Running`;
            badge.className = `badge ${healthy ? 'badge-success' : 'badge-warning'}`;
        }
        
        // Build services grid
        const services = data.services || {};
        const serviceOrder = ['docker', 'compose', 'mariadb', 'python', 'git', 'sqlite', 'nginx', 'nodejs', 'shellder'];
        
        let html = '';
        for (const key of serviceOrder) {
            const svc = services[key];
            if (!svc) continue;
            
            const statusClass = svc.status;
            const version = svc.version ? `<span class="service-version">v${svc.version}</span>` : '';
            
            html += `
                <div class="service-item" title="${svc.description}: ${svc.status}">
                    <span class="service-icon">${svc.icon}</span>
                    <div class="service-info">
                        <div class="service-name">${svc.name}</div>
                        <div class="service-desc">${svc.description} ${version}</div>
                    </div>
                    <span class="service-status ${statusClass}" title="${svc.status}"></span>
                </div>
            `;
        }
        
        container.innerHTML = html || '<div class="text-muted">No services detected</div>';
        console.log('[SERVICES] Rendered', Object.keys(services).length, 'services');
    } catch (error) {
        console.error('[SERVICES] Exception:', error);
        container.innerHTML = `<div class="text-danger">Failed to check services: ${error.message}</div>`;
        if (badge) {
            badge.textContent = 'Error';
            badge.className = 'badge badge-danger';
        }
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

// =============================================================================
// SPARKLINES & METRICS HISTORY
// =============================================================================

async function loadSparklines() {
    try {
        const data = await fetchAPI('/api/metrics/sparklines');
        
        // Skip if throttled (no new data)
        if (data._throttled) return;
        
        renderSparkline('cpuSparkline', data.cpu || []);
        renderSparkline('memorySparkline', data.memory || []);
        renderSparkline('diskSparkline', data.disk || []);
    } catch (e) {
        // Sparklines are optional, don't show errors
    }
}

function renderSparkline(elementId, values) {
    const el = document.getElementById(elementId);
    if (!el || !values.length) return;
    
    // For percentage metrics, always use 100 as max for proper scaling
    const max = 100;
    const bars = values.map(v => {
        const height = Math.max(2, (v / max) * 100);
        let colorClass = '';
        if (v < 50) colorClass = 'low';
        else if (v < 80) colorClass = 'medium';
        else colorClass = 'high';
        return `<div class="bar ${colorClass}" style="height: ${height}%" title="${v.toFixed(1)}%"></div>`;
    }).join('');
    
    el.innerHTML = bars;
}

async function showMetricDetail(metric) {
    const titles = {
        cpu: '⚡ CPU Usage History',
        memory: '🧠 RAM Usage History',
        disk: '💽 Disk Usage History'
    };
    
    openModal(titles[metric] || 'Metric History', `
        <div class="metric-detail-modal">
            <div class="metric-time-controls">
                <button class="btn btn-sm ${metric === 'cpu' ? 'active' : ''}" onclick="loadMetricHistory('${metric}', 1)">1h</button>
                <button class="btn btn-sm" onclick="loadMetricHistory('${metric}', 6)">6h</button>
                <button class="btn btn-sm" onclick="loadMetricHistory('${metric}', 24)">24h</button>
                <button class="btn btn-sm" onclick="loadMetricHistory('${metric}', 168)">7d</button>
            </div>
            <div class="metric-chart" id="metricChart">
                <div class="loading">Loading history...</div>
            </div>
            <div class="metric-stats" id="metricStats"></div>
        </div>
    `);
    
    loadMetricHistory(metric, 1);
}

async function loadMetricHistory(metric, hours) {
    const chartEl = document.getElementById('metricChart');
    const statsEl = document.getElementById('metricStats');
    
    try {
        const metricName = metric === 'cpu' ? 'cpu_percent' : 
                         metric === 'memory' ? 'memory_percent' : 'disk_percent';
        
        const data = await fetchAPI(`/api/metrics/history/${metricName}?hours=${hours}`);
        
        if (data.error) {
            chartEl.innerHTML = `<div class="no-data">${data.error}<br><small>Metrics are recorded every 30 seconds.</small></div>`;
            statsEl.innerHTML = '';
            return;
        }
        
        if (!data.data || data.data.length === 0) {
            chartEl.innerHTML = '<div class="no-data">No data available yet. Metrics are recorded every 30 seconds.</div>';
            statsEl.innerHTML = '';
            return;
        }
        
        // Calculate stats
        const values = data.data.map(d => d.value);
        const avg = values.reduce((a, b) => a + b, 0) / values.length;
        const max = Math.max(...values);
        const min = Math.min(...values);
        const current = values[values.length - 1];
        
        // Render chart as bar graph
        const chartMax = Math.max(max, 100);
        const chartHtml = data.data.map((d, i) => {
            const height = Math.max(2, (d.value / chartMax) * 100);
            let colorClass = d.value < 50 ? 'low' : d.value < 80 ? 'medium' : 'high';
            const time = new Date(d.time).toLocaleTimeString();
            return `<div class="chart-bar ${colorClass}" style="height: ${height}%" 
                        title="${d.value.toFixed(1)}% at ${time}"></div>`;
        }).join('');
        
        chartEl.innerHTML = `
            <div class="chart-container">
                <div class="chart-bars">${chartHtml}</div>
                <div class="chart-axis">
                    <span>0%</span>
                    <span>50%</span>
                    <span>100%</span>
                </div>
            </div>
        `;
        
        // Render stats
        statsEl.innerHTML = `
            <div class="metric-stat-grid">
                <div class="metric-stat">
                    <div class="metric-stat-value">${current.toFixed(1)}%</div>
                    <div class="metric-stat-label">Current</div>
                </div>
                <div class="metric-stat">
                    <div class="metric-stat-value">${avg.toFixed(1)}%</div>
                    <div class="metric-stat-label">Average</div>
                </div>
                <div class="metric-stat">
                    <div class="metric-stat-value">${min.toFixed(1)}%</div>
                    <div class="metric-stat-label">Min</div>
                </div>
                <div class="metric-stat">
                    <div class="metric-stat-value">${max.toFixed(1)}%</div>
                    <div class="metric-stat-label">Max</div>
                </div>
            </div>
            <div class="metric-stat-info">
                <small>${data.data.length} data points over ${hours} hour(s)</small>
            </div>
        `;
        
        // Update active button - find by hours
        document.querySelectorAll('.metric-time-controls .btn').forEach(b => {
            b.classList.remove('active');
            // Match button by its label
            const hoursMap = {'1h': 1, '6h': 6, '24h': 24, '7d': 168};
            if (hoursMap[b.textContent] === hours) {
                b.classList.add('active');
            }
        });
        
    } catch (e) {
        SHELLDER_DEBUG.error('METRICS', `Failed to load history for ${metric}: ${e.message}`);
        chartEl.innerHTML = `<div class="text-danger">Failed to load history<br><small>Metrics are collected every 30 seconds. If you just started the server, please wait.</small></div>`;
        statsEl.innerHTML = '';
    }
}

function updateSystemStats(data) {
    // Update CPU
    if (data.cpu_percent !== undefined) {
        document.getElementById('cpuUsed').textContent = `${data.cpu_percent}%`;
    }
    
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
        if (data._throttled) return;
        updateXilriwsStats(data);
    } catch (error) {
        // Silent fail - Xilriws may not be configured
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

// Store container update info globally
let containerUpdates = {};

function updateContainerList(containers) {
    const listEl = document.getElementById('containerList');
    
    if (!containers || containers.length === 0) {
        listEl.innerHTML = '<div class="loading">No containers found</div>';
        return;
    }
    
    listEl.innerHTML = containers.map(c => {
        const updateInfo = containerUpdates[c.name];
        const hasUpdate = updateInfo?.update_available || updateInfo?.may_have_update;
        const updateBadge = hasUpdate ? 
            `<span class="update-badge" title="${updateInfo?.note || 'Update may be available'}">⬆️</span>` : '';
        
        return `
            <div class="container-item ${hasUpdate ? 'has-update' : ''}">
                <div class="container-status ${c.status || c.state}"></div>
                <div class="container-name">${c.name} ${updateBadge}</div>
                <div class="container-state">${c.status || c.state}</div>
                ${c.cpu_percent !== undefined ? `
                    <div class="container-stats">
                        <span class="stat-label">CPU:</span><span>${c.cpu_percent}%</span>
                        <span class="stat-label">MEM:</span><span>${c.memory_percent || 0}%</span>
                    </div>
                ` : ''}
            </div>
        `;
    }).join('');
}

async function loadContainerUpdates() {
    try {
        const data = await fetchAPI('/api/containers/updates');
        if (data._throttled || data.error) return;
        
        containerUpdates = data.updates || {};
        
        // Update the badge on the Docker Containers header
        const available = data.available || 0;
        const headerEl = document.querySelector('#page-dashboard .card-header h2');
        if (headerEl && headerEl.textContent.includes('Docker')) {
            // Remove old badge if exists
            const oldBadge = headerEl.querySelector('.update-count');
            if (oldBadge) oldBadge.remove();
            
            if (available > 0) {
                const badge = document.createElement('span');
                badge.className = 'update-count';
                badge.title = `${available} container(s) may have updates available`;
                badge.textContent = `${available} ⬆️`;
                headerEl.appendChild(badge);
            }
        }
        
        // Re-render container list with update info
        const statusData = await fetchAPI('/api/status', { force: true });
        if (statusData && statusData.containers) {
            updateContainerList(statusData.containers.list);
        }
    } catch (e) {
        // Updates check is optional, don't show errors
    }
}

function updateContainerDetailList(containers) {
    const listEl = document.getElementById('containerDetailList');
    if (!listEl) return;
    
    if (!containers || containers.length === 0) {
        listEl.innerHTML = '<div class="loading">No containers found</div>';
        return;
    }
    
    listEl.innerHTML = containers.map(c => {
        const updateInfo = containerUpdates[c.name];
        const hasUpdate = updateInfo?.update_available || updateInfo?.may_have_update;
        const imageInfo = c.image ? `<span class="container-image" title="${c.image}">${c.image.split(':')[0].split('/').pop()}</span>` : '';
        const updateBadge = hasUpdate ? 
            `<span class="update-available" title="${updateInfo?.note || 'Update may be available'}">⬆️ Update</span>` : '';
        
        return `
            <div class="container-detail ${hasUpdate ? 'has-update' : ''}">
                <div class="container-status ${c.status || c.state}"></div>
                <div class="container-info">
                    <div class="container-name">${c.name} ${updateBadge}</div>
                    <div class="container-status-text">${c.status || c.state} ${imageInfo}</div>
                    ${c.cpu_percent !== undefined ? `
                        <div class="container-metrics">
                            CPU: ${c.cpu_percent}% | Memory: ${c.memory_percent || 0}%
                        </div>
                    ` : ''}
                </div>
                <div class="container-actions">
                    ${(c.status || c.state) === 'running' ? `
                        <button class="btn btn-sm" onclick="containerAction('${c.name}', 'restart')" title="Restart">🔄</button>
                        <button class="btn btn-sm btn-danger" onclick="containerAction('${c.name}', 'stop')" title="Stop">⏹️</button>
                    ` : `
                        <button class="btn btn-sm btn-success" onclick="containerAction('${c.name}', 'start')" title="Start">▶️</button>
                    `}
                    <button class="btn btn-sm" onclick="viewContainerLogs('${c.name}')" title="View Logs">📋</button>
                    <button class="btn btn-sm" onclick="checkContainerUpdate('${c.name}')" title="Check for Updates">⬆️</button>
                </div>
            </div>
        `;
    }).join('');
}

async function checkContainerUpdate(name) {
    showToast(`Checking for updates: ${name}...`, 'info');
    
    try {
        const result = await fetchAPI(`/api/containers/check-update/${name}`, { 
            method: 'POST',
            force: true 
        });
        
        if (result.success) {
            if (result.update_available) {
                showToast(`✨ New image available for ${name}! Restart container to apply.`, 'success');
            } else {
                showToast(`✓ ${name} is up to date`, 'success');
            }
            // Refresh update info
            await loadContainerUpdates();
        } else {
            showToast(`Failed to check: ${result.error}`, 'error');
        }
    } catch (e) {
        showToast(`Error checking updates: ${e.message}`, 'error');
    }
}

function updateConnectionStatus(connected, mode = '') {
    const dot = document.getElementById('connectionStatus');
    const text = document.getElementById('connectionText');
    
    if (connected) {
        dot.className = 'status-dot connected';
        if (mode === 'live') {
            text.textContent = 'Live';
            dot.classList.add('live');
        } else if (mode === 'demo') {
            text.textContent = 'Demo Mode';
            dot.classList.add('warning');
        } else {
            text.textContent = 'Connected';
        }
    } else {
        dot.className = 'status-dot error';
        text.textContent = 'Disconnected';
    }
}

let localModeNoticeShown = false;
function showLocalModeNotice(message) {
    // Only show once per session
    if (localModeNoticeShown) return;
    localModeNoticeShown = true;
    
    // Update connection status to show demo mode
    updateConnectionStatus(true, 'demo');
    
    // Create notice banner
    const notice = document.createElement('div');
    notice.id = 'localModeBanner';
    notice.style.cssText = `
        position: fixed;
        top: 0;
        left: 0;
        right: 0;
        background: linear-gradient(135deg, #f59e0b 0%, #d97706 100%);
        color: #1a1a2e;
        padding: 10px 20px;
        text-align: center;
        font-weight: 600;
        z-index: 9999;
        display: flex;
        align-items: center;
        justify-content: center;
        gap: 10px;
    `;
    notice.innerHTML = `
        <span>${message}</span>
        <button onclick="this.parentElement.remove()" style="
            background: rgba(0,0,0,0.2);
            border: none;
            color: inherit;
            padding: 4px 12px;
            border-radius: 4px;
            cursor: pointer;
            font-weight: 500;
        ">Dismiss</button>
    `;
    document.body.prepend(notice);
    
    // Adjust main content to account for banner
    document.querySelector('.main-content').style.marginTop = '50px';
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
    
    // Update stats with null checks
    const rate = data.success_rate || 0;
    const rateEl = document.getElementById('xilSuccessRate');
    if (rateEl) {
        rateEl.textContent = rate.toFixed(1) + '%';
        rateEl.className = 'stat-value ' + 
            (rate > 80 ? 'text-success' : rate > 50 ? 'text-warning' : 'text-danger');
    }
    
    setElementText('xilSuccessful', data.successful || 0);
    setElementText('xilFailed', data.failed || 0);
    setElementText('xilTotal', data.total_requests || 0);
    
    // Update error breakdown
    setElementText('xilAuthBanned', data.auth_banned || 0);
    setElementText('xilCode15', data.code_15 || 0);
    setElementText('xilRateLimited', data.rate_limited || 0);
    setElementText('xilInvalidCreds', data.invalid_credentials || 0);
    setElementText('xilTunnelErrors', data.tunneling_errors || 0);
    setElementText('xilTimeouts', data.timeouts || 0);
    setElementText('xilConnRefused', data.connection_refused || 0);
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

// Store original navigateTo and extend it with page-specific initialization
const originalNavigateTo = navigateTo;
navigateTo = function(page) {
    // Stop any streams when leaving a page
    stopXilriwsLiveStream();
    stopContainerLogStream();
    
    // Call original function
    originalNavigateTo(page);
    
    // Page-specific initialization
    switch(page) {
        case 'xilriws':
            loadXilriwsStats();
            loadProxyInfo();
            loadXilriwsLogs();
            updateXilriwsContainerStatus();
            loadProxyFile();
            // Also fetch current stats
            fetchAPI('/api/xilriws/stats').then(data => updateXilriwsPage(data));
            break;
        case 'nginx':
            loadNginxStatus();
            loadNginxSites();
            loadNginxLogs();
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
// Note: currentLogContainer is declared above in CONTAINER LOG STREAMING section
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
// LIVE ACTIVITY MONITOR
// =============================================================================

let monitorActive = false;

async function toggleMonitor() {
    const btn = document.getElementById('monitorToggle');
    const status = document.getElementById('monitorStatus');
    
    if (monitorActive) {
        // Stop monitor
        await fetchAPI('/api/monitor/stop', { method: 'POST' });
        monitorActive = false;
        btn.innerHTML = '▶️ Start';
        status.innerHTML = '<span class="status-dot offline"></span><span>Stopped</span>';
    } else {
        // Start monitor
        await fetchAPI('/api/monitor/start', { method: 'POST' });
        monitorActive = true;
        btn.innerHTML = '⏹️ Stop';
        status.innerHTML = '<span class="status-dot online"></span><span>Live</span>';
        
        // Start receiving updates
        startActivityStream();
    }
}

function startActivityStream() {
    // Subscribe to device_activity events via WebSocket
    if (socket) {
        socket.on('device_activity', (event) => {
            if (currentPage === 'devices') {
                addActivityEvent(event);
                updateContainerHealth(event);
            }
        });
    }
    
    // Also poll for activity feed
    loadActivityFeed();
    loadContainerHealth();
}

async function loadActivityFeed() {
    if (!monitorActive) return;
    
    try {
        const events = await fetchAPI('/api/monitor/activity?limit=30');
        renderActivityFeed(events);
    } catch (e) {
        console.error('Error loading activity:', e);
    }
}

function renderActivityFeed(events) {
    const el = document.getElementById('activityStream');
    if (!el || !events || events.length === 0) {
        if (el && monitorActive) {
            el.innerHTML = '<div class="stream-hint">Waiting for events...</div>';
        }
        return;
    }
    
    el.innerHTML = events.map(e => `
        <div class="activity-event ${e.severity || 'info'}">
            <div class="event-header">
                <span class="event-icon">${getEventIcon(e)}</span>
                <span class="event-type">${e.type}</span>
                <span class="event-container">${e.container}</span>
                <span class="event-time">${formatEventTime(e.created_at)}</span>
            </div>
            ${e.device ? `<div class="event-device">📱 ${e.device}</div>` : ''}
            ${e.raw ? `<div class="event-message">${truncate(e.raw, 120)}</div>` : ''}
        </div>
    `).join('');
}

function addActivityEvent(event) {
    const el = document.getElementById('activityStream');
    if (!el) return;
    
    // Remove hint if present
    const hint = el.querySelector('.stream-hint');
    if (hint) hint.remove();
    
    // Create event element
    const eventEl = document.createElement('div');
    eventEl.className = `activity-event ${event.severity || 'info'} new`;
    eventEl.innerHTML = `
        <div class="event-header">
            <span class="event-icon">${getEventIcon(event)}</span>
            <span class="event-type">${event.type}</span>
            <span class="event-container">${event.container}</span>
            <span class="event-time">${formatEventTime(event.created_at)}</span>
        </div>
        ${event.device ? `<div class="event-device">📱 ${event.device}</div>` : ''}
        ${event.raw ? `<div class="event-message">${truncate(event.raw, 120)}</div>` : ''}
    `;
    
    // Add at top
    el.insertBefore(eventEl, el.firstChild);
    
    // Remove animation class after animation
    setTimeout(() => eventEl.classList.remove('new'), 500);
    
    // Limit to 50 events
    while (el.children.length > 50) {
        el.removeChild(el.lastChild);
    }
    
    // Update counters if this is an error/disconnect
    if (event.type.includes('disconnect') || event.severity === 'error') {
        loadDeviceSummary();
    }
}

function getEventIcon(event) {
    const icons = {
        'device_connect': '🟢',
        'device_disconnect': '🔴',
        'worker_disconnect': '👷',
        'connection_rejected': '🚫',
        'device_id': '📋',
        'memory': '💾',
        'error': '❌',
        'timeout': '⏰',
        'task_assigned': '📝',
        'task_complete': '✅',
        'device_error': '⚠️',
        'account_issue': '🔒',
        'api_check': '🔌',
        'db_error': '🗄️',
        'fatal': '💀',
        'container_restart': '🔄',
        'container_status_change': '🐳',
        'container_unhealthy': '🏥',
        'high_memory': '📊',
        'container_down': '⬇️',
        'container_error': '🔥',
        // Database events
        'ready': '✅',
        'aborted_connection': '🔌',
        'startup': '🚀',
        'warning': '⚠️',
        'innodb': '💿',
        'socket_listen': '📡',
        // Koji events
        'scanner_type': '🔍',
        'slow_db_acquire': '🐢',
        'migration': '📦',
        'http_request': '🌐',
        'stream_error': '🤖',
        'geofence': '📍'
    };
    return icons[event.type] || '📌';
}

function formatEventTime(timestamp) {
    if (!timestamp) return '';
    try {
        const d = new Date(timestamp);
        return d.toLocaleTimeString();
    } catch {
        return '';
    }
}

async function loadContainerHealth() {
    try {
        const containers = await fetchAPI('/api/monitor/containers');
        renderContainerHealth(containers);
    } catch (e) {
        console.error('Error loading container health:', e);
    }
}

function renderContainerHealth(containers) {
    const el = document.getElementById('healthGrid');
    if (!el) return;
    
    if (!containers || Object.keys(containers).length === 0) {
        el.innerHTML = '<div class="no-data">No container data</div>';
        return;
    }
    
    el.innerHTML = Object.entries(containers).map(([name, state]) => `
        <div class="health-item ${state.status === 'running' ? 'healthy' : 'unhealthy'}">
            <span class="health-name">${name}</span>
            <span class="health-status">${state.status === 'running' ? '🟢' : '🔴'}</span>
            ${state.memory_percent ? `
                <span class="health-mem ${state.memory_percent > 80 ? 'high' : ''}">${state.memory_percent.toFixed(0)}%</span>
            ` : ''}
            ${state.restart_count > 0 ? `
                <span class="health-restarts">↻${state.restart_count}</span>
            ` : ''}
        </div>
    `).join('');
}

function updateContainerHealth(event) {
    if (event.type.startsWith('container_')) {
        loadContainerHealth();
    }
}

function filterActivity() {
    const severity = document.getElementById('activityFilter').value;
    const events = document.querySelectorAll('.activity-event');
    
    events.forEach(el => {
        if (!severity) {
            el.style.display = '';
        } else {
            el.style.display = el.classList.contains(severity) ? '' : 'none';
        }
    });
}

// Check monitor status on page load
async function checkMonitorStatus() {
    try {
        const status = await fetchAPI('/api/monitor/status');
        if (status.running) {
            monitorActive = true;
            document.getElementById('monitorToggle').innerHTML = '⏹️ Stop';
            document.getElementById('monitorStatus').innerHTML = 
                '<span class="status-dot online"></span><span>Live</span>';
            startActivityStream();
        }
    } catch (e) {
        console.log('Monitor not available');
    }
}

// Override loadDevicesPage to include monitor check
const originalLoadDevicesPage = loadDevicesPage;
loadDevicesPage = async function() {
    await originalLoadDevicesPage();
    await checkMonitorStatus();
    await loadContainerHealth();
};

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

// =============================================================================
// XILRIWS CONTAINER CONTROL
// =============================================================================

async function xilriwsAction(action) {
    showToast(`${action}ing Xilriws...`, 'info');
    
    try {
        const result = await fetchAPI(`/api/xilriws/container/${action}`, { 
            method: 'POST',
            force: true 
        });
        
        if (result.success) {
            showToast(`Xilriws ${action}ed successfully`, 'success');
            updateXilriwsContainerStatus();
        } else {
            showToast(`Failed: ${result.error}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function updateXilriwsContainerStatus() {
    const badge = document.getElementById('xilriwsContainerStatus');
    if (!badge) return;
    
    try {
        const data = await fetchAPI('/api/xilriws/status', { force: true });
        const dot = badge.querySelector('.status-dot');
        const text = badge.querySelector('.status-text');
        
        if (data.running) {
            dot.className = 'status-dot running';
            text.textContent = 'Running';
            badge.className = 'container-status-badge running';
        } else {
            dot.className = 'status-dot stopped';
            text.textContent = data.status || 'Stopped';
            badge.className = 'container-status-badge stopped';
        }
    } catch (e) {
        const text = badge.querySelector('.status-text');
        if (text) text.textContent = 'Error';
    }
}

// =============================================================================
// PROXY MANAGER
// =============================================================================

async function loadProxyFile() {
    const editor = document.getElementById('proxyEditor');
    const countEl = document.getElementById('proxyCount');
    const pathEl = document.getElementById('proxyFilePath');
    
    if (!editor) return;
    
    try {
        const data = await fetchAPI('/api/xilriws/proxies', { force: true });
        
        if (data.exists) {
            editor.value = data.content || '';
            if (countEl) countEl.textContent = data.count;
            if (pathEl) pathEl.textContent = data.file;
        } else {
            editor.value = '# Add proxies here, one per line\n# Format: host:port or user:pass@host:port\n';
            if (countEl) countEl.textContent = '0';
        }
    } catch (e) {
        editor.value = '# Error loading proxies: ' + e.message;
    }
}

async function saveProxies() {
    const editor = document.getElementById('proxyEditor');
    const content = editor.value;
    
    try {
        const result = await fetchAPI('/api/xilriws/proxies', {
            method: 'POST',
            body: JSON.stringify({ content }),
            force: true
        });
        
        if (result.success) {
            showToast(`Saved ${result.count} proxies`, 'success');
            document.getElementById('proxyCount').textContent = result.count;
        } else {
            showToast(`Save failed: ${result.error}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function saveAndRestartXilriws() {
    await saveProxies();
    await xilriwsAction('restart');
}

function validateProxies() {
    const editor = document.getElementById('proxyEditor');
    const lines = editor.value.split('\n');
    const proxyRegex = /^(?:[\w.-]+:[\w.-]+@)?[\w.-]+:\d+$/;
    
    let valid = 0, invalid = 0;
    const invalidLines = [];
    
    lines.forEach((line, i) => {
        line = line.trim();
        if (!line || line.startsWith('#')) return;
        
        if (proxyRegex.test(line)) {
            valid++;
        } else {
            invalid++;
            invalidLines.push(i + 1);
        }
    });
    
    if (invalid === 0) {
        showToast(`✓ All ${valid} proxies have valid format`, 'success');
    } else {
        showToast(`⚠ ${invalid} invalid proxies on lines: ${invalidLines.slice(0, 5).join(', ')}${invalidLines.length > 5 ? '...' : ''}`, 'warning');
    }
}

function clearProxies() {
    if (confirm('Clear all proxies? This cannot be undone.')) {
        document.getElementById('proxyEditor').value = '';
        showToast('Proxies cleared (remember to save)', 'info');
    }
}

// =============================================================================
// NGINX MANAGEMENT
// =============================================================================

async function loadNginxStatus() {
    const badge = document.getElementById('nginxStatus');
    if (!badge) return;
    
    try {
        const data = await fetchAPI('/api/nginx/status');
        const dot = badge.querySelector('.status-dot');
        const text = badge.querySelector('.status-text');
        
        if (data.running) {
            dot.className = 'status-dot running';
            text.textContent = 'Running';
            badge.className = 'container-status-badge running';
        } else {
            dot.className = 'status-dot stopped';
            text.textContent = data.status || 'Stopped';
            badge.className = 'container-status-badge stopped';
        }
    } catch (e) {
        console.log('Nginx status check failed:', e);
    }
}

async function nginxAction(action) {
    showToast(`${action}ing Nginx...`, 'info');
    
    try {
        const result = await fetchAPI(`/api/nginx/${action}`, { 
            method: 'POST',
            force: true 
        });
        
        if (result.success) {
            showToast(`Nginx ${action} successful`, 'success');
            if (result.output) {
                console.log('Nginx output:', result.output);
            }
            loadNginxStatus();
        } else {
            showToast(`Failed: ${result.error || result.output}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function loadNginxSites() {
    const enabledEl = document.getElementById('sitesEnabledList');
    const availableEl = document.getElementById('sitesAvailableList');
    const selectorEl = document.getElementById('siteSelector');
    
    try {
        const data = await fetchAPI('/api/nginx/sites');
        
        // Update counts
        document.getElementById('sitesEnabled').textContent = data.enabled_count || 0;
        document.getElementById('sitesAvailable').textContent = data.available_count || 0;
        document.getElementById('sslCerts').textContent = data.ssl_certs || 0;
        
        // Render enabled sites
        if (enabledEl) {
            if (data.enabled && data.enabled.length > 0) {
                enabledEl.innerHTML = data.enabled.map(site => `
                    <div class="site-item enabled">
                        <span class="site-icon">🌐</span>
                        <span class="site-name">${site.name}</span>
                        <div class="site-actions">
                            <button class="btn btn-sm" onclick="loadSiteConfig('${site.name}')" title="Edit">📝</button>
                            <button class="btn btn-sm btn-warning" onclick="disableSite('${site.name}')" title="Disable">⏸️</button>
                        </div>
                    </div>
                `).join('');
            } else {
                enabledEl.innerHTML = '<div class="no-data">No sites enabled</div>';
            }
        }
        
        // Render available (disabled) sites
        if (availableEl) {
            const disabled = data.available?.filter(s => !s.enabled) || [];
            if (disabled.length > 0) {
                availableEl.innerHTML = disabled.map(site => `
                    <div class="site-item disabled">
                        <span class="site-icon">📁</span>
                        <span class="site-name">${site.name}</span>
                        <div class="site-actions">
                            <button class="btn btn-sm" onclick="loadSiteConfig('${site.name}')" title="Edit">📝</button>
                            <button class="btn btn-sm btn-success" onclick="enableSite('${site.name}')" title="Enable">▶️</button>
                        </div>
                    </div>
                `).join('');
            } else {
                availableEl.innerHTML = '<div class="no-data">All sites are enabled</div>';
            }
        }
        
        // Populate selector
        if (selectorEl) {
            const allSites = [...(data.enabled || []), ...(data.available || [])];
            const uniqueSites = [...new Set(allSites.map(s => s.name))];
            selectorEl.innerHTML = '<option value="">Select a site to edit...</option>' +
                uniqueSites.map(name => `<option value="${name}">${name}</option>`).join('');
        }
        
    } catch (e) {
        if (enabledEl) enabledEl.innerHTML = '<div class="error-msg">Failed to load sites</div>';
    }
}

async function loadSiteConfig(name) {
    if (!name) return;
    
    const editor = document.getElementById('siteConfigEditor');
    const selector = document.getElementById('siteSelector');
    
    if (selector) selector.value = name;
    if (editor) editor.value = 'Loading...';
    
    try {
        const data = await fetchAPI(`/api/nginx/site/${name}`);
        
        if (data.content) {
            editor.value = data.content;
        } else {
            editor.value = `# Error: ${data.error || 'Could not load configuration'}`;
        }
    } catch (e) {
        editor.value = `# Error: ${e.message}`;
    }
}

async function saveSiteConfig() {
    const selector = document.getElementById('siteSelector');
    const editor = document.getElementById('siteConfigEditor');
    const name = selector.value;
    
    if (!name) {
        showToast('Select a site first', 'warning');
        return;
    }
    
    try {
        const result = await fetchAPI(`/api/nginx/site/${name}`, {
            method: 'POST',
            body: JSON.stringify({ content: editor.value }),
            force: true
        });
        
        if (result.success) {
            showToast('Configuration saved', 'success');
            // Test config
            const testResult = await fetchAPI('/api/nginx/test', { method: 'POST', force: true });
            if (testResult.success) {
                showToast('Config test passed - reload nginx to apply', 'info');
            } else {
                showToast('Warning: Config test failed', 'warning');
            }
        } else {
            showToast(`Save failed: ${result.error}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function enableSite(name) {
    try {
        const result = await fetchAPI(`/api/nginx/site/${name}/enable`, { method: 'POST', force: true });
        if (result.success) {
            showToast(`${name} enabled`, 'success');
            loadNginxSites();
        } else {
            showToast(`Failed: ${result.error}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function disableSite(name) {
    if (!confirm(`Disable site ${name}? It will be moved to sites-available.`)) return;
    
    try {
        const result = await fetchAPI(`/api/nginx/site/${name}/disable`, { method: 'POST', force: true });
        if (result.success) {
            showToast(`${name} disabled`, 'success');
            loadNginxSites();
        } else {
            showToast(`Failed: ${result.error}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function loadNginxLogs() {
    const logEl = document.getElementById('nginxLogContent');
    if (!logEl) return;
    
    try {
        const data = await fetchAPI('/api/nginx/logs?lines=100');
        logEl.textContent = data.logs || 'No logs available';
    } catch (e) {
        logEl.textContent = 'Failed to load logs: ' + e.message;
    }
}

async function runNginxSetup() {
    const domain = document.getElementById('setupDomain').value.trim();
    const email = document.getElementById('setupEmail').value.trim();
    const service = document.getElementById('setupService').value;
    const customPort = document.getElementById('setupCustomPort').value;
    
    if (!domain) {
        showToast('Domain is required', 'warning');
        return;
    }
    
    const outputEl = document.getElementById('nginxSetupOutput');
    const preEl = outputEl.querySelector('pre');
    outputEl.style.display = 'block';
    preEl.textContent = 'Setting up site...';
    
    try {
        const result = await fetchAPI('/api/nginx/setup', {
            method: 'POST',
            body: JSON.stringify({ domain, email, service, custom_port: customPort }),
            force: true
        });
        
        if (result.success) {
            preEl.textContent = `✓ Site ${domain} configured successfully!\n\n`;
            if (result.ssl_output) {
                preEl.textContent += `SSL Output:\n${result.ssl_output}`;
            }
            showToast('Site configured successfully!', 'success');
            loadNginxSites();
        } else {
            preEl.textContent = `✗ Setup failed: ${result.error}\n\n`;
            if (result.ssl_output) {
                preEl.textContent += result.ssl_output;
            }
        }
    } catch (e) {
        preEl.textContent = `Error: ${e.message}`;
    }
}

function generateConfigPreview() {
    const domain = document.getElementById('setupDomain').value.trim();
    const service = document.getElementById('setupService').value;
    const customPort = document.getElementById('setupCustomPort').value;
    
    const port = service === 'custom' ? customPort : service.split(':')[1];
    
    const config = `server {
    listen 80;
    server_name ${domain || 'example.com'};
    
    location / {
        proxy_pass http://localhost:${port || '6001'};
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}`;
    
    document.getElementById('siteConfigEditor').value = config;
    showToast('Preview generated - edit and save as needed', 'info');
}

// Handle custom port visibility
document.getElementById('setupService')?.addEventListener('change', function() {
    const customGroup = document.getElementById('customPortGroup');
    if (customGroup) {
        customGroup.style.display = this.value === 'custom' ? 'block' : 'none';
    }
});

// =============================================================================
// SITE AVAILABILITY CHECK
// =============================================================================

async function checkSiteAvailability() {
    SHELLDER_DEBUG.info('SITES', 'checkSiteAvailability called');
    const container = document.getElementById('siteAvailability');
    if (!container) {
        SHELLDER_DEBUG.error('SITES', 'siteAvailability element not found!');
        return;
    }
    
    container.innerHTML = '<div class="loading">Checking sites...</div>';
    
    try {
        SHELLDER_DEBUG.debug('SITES', 'Fetching /api/sites/check...');
        const data = await fetchAPI('/api/sites/check', { force: true });
        SHELLDER_DEBUG.info('SITES', 'Response received', { healthy: data?.healthy, total: data?.total });
        
        // Check for errors
        if (data.error) {
            console.error('[SITES] API error:', data.error);
            container.innerHTML = `<div class="error-msg">Error: ${data.error}</div>`;
            return;
        }
        
        // Update dashboard card
        const healthEl = document.getElementById('siteHealth');
        const iconEl = document.getElementById('siteHealthIcon');
        if (healthEl) healthEl.textContent = data.summary || 'N/A';
        if (iconEl) iconEl.textContent = data.healthy === data.total ? '✅' : '⚠️';
        
        // Render site list
        if (data.sites && data.sites.length > 0) {
            container.innerHTML = data.sites.map(site => `
                <div class="site-check-item ${site.healthy ? 'healthy' : 'unhealthy'}">
                    <span class="site-check-icon">${site.healthy ? '✅' : '❌'}</span>
                    <span class="site-check-name">${site.name}</span>
                    <span class="site-check-status">${site.status || 'N/A'}</span>
                    ${site.error ? `<span class="site-check-error">${site.error}</span>` : ''}
                </div>
            `).join('');
            console.log('[SITES] Rendered', data.sites.length, 'sites');
        } else {
            container.innerHTML = '<div class="no-data">No sites configured in Nginx</div>';
            console.log('[SITES] No sites to display');
        }
    } catch (e) {
        console.error('[SITES] Exception:', e);
        container.innerHTML = `<div class="error-msg">Failed to check sites: ${e.message}</div>`;
    }
}

// Note: Page-specific initialization is handled in the navigateTo override above

// =============================================================================
// AI DEBUG PANEL
// =============================================================================

let debugRefreshInterval = null;

async function loadDebugPanel() {
    try {
        const data = await fetchAPI('/api/debug/live?count=100');
        
        // Update version info
        const versionEl = document.getElementById('debugVersion');
        const commitEl = document.getElementById('debugCommit');
        const uptimeEl = document.getElementById('debugUptime');
        const pidEl = document.getElementById('debugPid');
        
        if (versionEl) versionEl.textContent = `v${data.version || '--'}`;
        if (commitEl) commitEl.textContent = data.git?.commit || '--';
        if (uptimeEl) {
            const secs = Math.floor(data.uptime_seconds || 0);
            const mins = Math.floor(secs / 60);
            const hours = Math.floor(mins / 60);
            uptimeEl.textContent = hours > 0 ? `${hours}h ${mins % 60}m` : `${mins}m ${secs % 60}s`;
        }
        if (pidEl) pidEl.textContent = data.pid || '--';
        
        // Render logs
        const logOutput = document.getElementById('debugLogOutput');
        if (logOutput && data.logs) {
            const html = data.logs.map(log => {
                const levelClass = log.level.toLowerCase();
                return `<div class="debug-log-line ${levelClass}">${escapeHtml(log.raw)}</div>`;
            }).join('');
            logOutput.innerHTML = html || '<div class="no-data">No logs yet</div>';
            
            // Auto-scroll to bottom
            logOutput.scrollTop = logOutput.scrollHeight;
        }
    } catch (e) {
        console.error('Failed to load debug panel:', e);
    }
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

async function refreshDebugLogs() {
    await loadDebugPanel();
    showToast('Debug logs refreshed', 'success');
}

async function debugGitPull() {
    showToast('Pulling from GitHub...', 'info');
    
    try {
        const data = await fetchAPI('/api/debug/git-pull', { method: 'POST' });
        
        if (data.success) {
            showToast(`✅ Pulled successfully! Commit: ${data.new_commit}`, 'success');
            if (data.needs_restart) {
                showToast('⚠️ Service files changed - restart recommended', 'warning');
            }
            await loadDebugPanel();
        } else {
            showToast(`❌ Pull failed: ${data.error || data.output}`, 'error');
        }
    } catch (e) {
        showToast(`❌ Pull failed: ${e.message}`, 'error');
    }
}

async function debugRestart() {
    showToast('🔄 Restarting service...', 'info');
    
    try {
        await fetchAPI('/api/debug/restart', { method: 'POST' });
        showToast('Service restarting... Page will reload in 5 seconds', 'warning');
        
        // Wait and reload
        setTimeout(() => {
            window.location.reload();
        }, 5000);
    } catch (e) {
        showToast(`Restart may have succeeded - refresh page. Error: ${e.message}`, 'warning');
        setTimeout(() => window.location.reload(), 3000);
    }
}

async function debugPullAndRestart() {
    showToast('🚀 Pulling from GitHub and restarting...', 'info');
    
    try {
        const data = await fetchAPI('/api/debug/pull-and-restart', { method: 'POST' });
        
        if (data.success) {
            showToast(`✅ Pulled commit ${data.new_commit}. Restarting...`, 'success');
            setTimeout(() => window.location.reload(), 5000);
        } else {
            showToast(`❌ Failed: ${data.error}`, 'error');
        }
    } catch (e) {
        showToast('May have succeeded - refreshing...', 'warning');
        setTimeout(() => window.location.reload(), 3000);
    }
}

// Start debug panel auto-refresh when on dashboard
function startDebugAutoRefresh() {
    if (debugRefreshInterval) clearInterval(debugRefreshInterval);
    
    const checkbox = document.getElementById('debugAutoRefresh');
    if (checkbox && checkbox.checked) {
        debugRefreshInterval = setInterval(loadDebugPanel, 5000);
    }
}

// Toggle auto-refresh
document.getElementById('debugAutoRefresh')?.addEventListener('change', function() {
    if (this.checked) {
        startDebugAutoRefresh();
    } else if (debugRefreshInterval) {
        clearInterval(debugRefreshInterval);
        debugRefreshInterval = null;
    }
});

// Load debug panel on dashboard
if (document.getElementById('debugLogOutput')) {
    loadDebugPanel();
    startDebugAutoRefresh();
}
