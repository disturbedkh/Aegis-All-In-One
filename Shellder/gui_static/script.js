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
    // Legacy function - now redirects to debug page
    navigateTo('debug');
}

// Download the server-side unified debug log
async function downloadServerDebugLog() {
    SHELLDER_DEBUG.info('DEBUG', 'Downloading server debug log');
    window.location.href = '/api/debug/debuglog/download';
}

// Load debug page content
async function loadDebugPage() {
    // Update status indicators
    const jsEl = document.getElementById('debugStatusJS');
    const apiEl = document.getElementById('debugStatusAPI');
    const wsEl = document.getElementById('debugStatusWS');
    const logCountEl = document.getElementById('debugStatusLogCount');
    
    if (jsEl) {
        jsEl.textContent = 'loaded ✓';
        jsEl.className = 'debug-value success';
    }
    if (apiEl) {
        apiEl.textContent = wsConnected ? 'connected ✓' : 'polling...';
        apiEl.className = wsConnected ? 'debug-value success' : 'debug-value warning';
    }
    if (wsEl) {
        wsEl.textContent = wsConnected ? 'live ✓' : 'not connected';
        wsEl.className = wsConnected ? 'debug-value success' : 'debug-value warning';
    }
    if (logCountEl) {
        logCountEl.textContent = SHELLDER_DEBUG.logs.length;
    }
    
    // Load client logs
    loadDebugClientLogs();
    
    // Load server logs
    loadDebugServerLog();
    
    // Update stream commands with correct host/port
    updateStreamCommands();
    
    // Load AI debug configuration
    loadAIDebugConfig();
    
    // Check MCP status
    checkMCPStatus();
    
    // Generate dynamic AI instructions with auto-detected URL
    generateAIInstructions();
}

// Generate AI instructions with auto-detected URL
function generateAIInstructions() {
    const baseUrl = `http://${window.location.hostname}:${window.location.port || 5000}`;
    const port = window.location.port || '5000';
    
    // Update AI instructions block
    const instructionsBlock = document.getElementById('aiInstructionsBlock');
    if (instructionsBlock) {
        instructionsBlock.textContent = `## Shellder Developer Mode API

Shellder API URL: ${baseUrl}

Use the fetch MCP tool to access these endpoints:

### System Diagnostics
GET ${baseUrl}/api/ai-debug/diagnose

### Read Files  
GET ${baseUrl}/api/ai-debug/file?path=.env
GET ${baseUrl}/api/ai-debug/file?path=docker-compose.yaml

### Execute Commands
POST ${baseUrl}/api/ai-debug/exec
Body: {"cmd": "docker ps"}

### Docker Operations
GET ${baseUrl}/api/ai-debug/docker?cmd=ps
GET ${baseUrl}/api/ai-debug/docker?cmd=logs&container=dragonite&lines=50

### Database Queries
POST ${baseUrl}/api/ai-debug/sql
Body: {"database": "golbat", "query": "SHOW TABLES"}

### Get Logs
GET ${baseUrl}/api/ai-debug/logs?type=shellder&lines=100

### System Info
GET ${baseUrl}/api/ai-debug/system`;
    }
    
    // Update firewall port
    const firewallPort = document.getElementById('firewallPort');
    if (firewallPort) firewallPort.textContent = port;
    
    // Update SSH tunnel command
    const sshCmd = document.getElementById('sshTunnelCmd');
    if (sshCmd) sshCmd.textContent = `ssh -L ${port}:localhost:${port} user@your-server-ip`;
    
    // Update detected URL
    const detectedUrl = document.getElementById('detectedApiUrl');
    if (detectedUrl) detectedUrl.textContent = baseUrl;
}

function loadDebugClientLogs() {
    const container = document.getElementById('debugClientLogs');
    if (!container) return;
    
    const logs = SHELLDER_DEBUG.logs.slice(-100); // Last 100 entries
    if (logs.length === 0) {
        container.innerHTML = '<pre style="color: var(--text-muted);">No client logs yet...</pre>';
        return;
    }
    
    const logText = logs.map(log => {
        const time = log.ts ? new Date(log.ts).toLocaleTimeString() : '??:??:??';
        const level = log.level || 'INFO';
        const cat = log.cat || 'UNKNOWN';
        const msg = log.msg || JSON.stringify(log);
        return `[${time}] [${level}] ${cat}: ${msg}`;
    }).join('\n');
    
    container.innerHTML = `<pre>${escapeHtml(logText)}</pre>`;
}

async function loadDebugServerLog() {
    const container = document.getElementById('debugServerLogs');
    const infoEl = document.getElementById('debugLogInfo');
    if (!container) return;
    
    try {
        const response = await fetch('/api/debug/debuglog?lines=200&format=json');
        const data = await response.json();
        
        if (data.error) {
            container.innerHTML = `<pre style="color: var(--danger);">Error: ${data.error}</pre>`;
            return;
        }
        
        if (infoEl) {
            infoEl.innerHTML = `
                <span>Lines: ${data.total_lines}</span>
                <span>Size: ${(data.size_bytes/1024).toFixed(1)}KB</span>
                <span>Showing: last ${data.returned_lines}</span>
            `;
        }
        
        container.innerHTML = `<pre>${escapeHtml(data.lines.join('\n'))}</pre>`;
    } catch (e) {
        container.innerHTML = `<pre style="color: var(--danger);">Failed to load: ${e.message}</pre>`;
    }
}

// Live stream controls
let browserStreamActive = false;
let browserStreamInterval = null;
let browserStreamEventSource = null;
let streamLinesReceived = 0;
let streamStartTime = null;

function copyStreamCommand(type) {
    let cmd = '';
    const port = window.location.port || '5050';
    const host = window.location.hostname;
    
    switch(type) {
        case 'tail':
            cmd = `curl -N http://${host}:${port}/api/debug/tail`;
            break;
        case 'stream':
            cmd = `curl -N http://${host}:${port}/api/debug/stream`;
            break;
        case 'file':
            cmd = `tail -f ~/Desktop/Aegis-All-In-One/Shellder/logs/debuglog.txt`;
            break;
    }
    
    navigator.clipboard.writeText(cmd).then(() => {
        showToast('Command copied to clipboard!', 'success');
    }).catch(() => {
        prompt('Copy this command:', cmd);
    });
}

// Browser live stream controls
function startBrowserStream() {
    if (browserStreamActive) return;
    
    browserStreamActive = true;
    streamLinesReceived = 0;
    streamStartTime = Date.now();
    
    // Update UI
    document.getElementById('streamStartBtn').style.display = 'none';
    document.getElementById('streamStopBtn').style.display = 'inline-flex';
    document.getElementById('browserStreamViewer').style.display = 'block';
    
    updateStreamStatus('running', 'Connecting...');
    
    const content = document.getElementById('browserStreamContent');
    content.textContent = '';
    
    // Try SSE first
    try {
        const port = window.location.port || '5050';
        const host = window.location.hostname;
        browserStreamEventSource = new EventSource(`http://${host}:${port}/api/debug/stream`);
        
        browserStreamEventSource.onopen = () => {
            updateStreamStatus('running', 'Connected');
        };
        
        browserStreamEventSource.onmessage = (event) => {
            try {
                const data = JSON.parse(event.data);
                if (data.type === 'log' && data.line) {
                    appendStreamLine(data.line);
                } else if (data.type === 'heartbeat') {
                    updateStreamStats();
                } else if (data.type === 'connected' || data.type === 'ready') {
                    appendStreamLine(`=== ${data.message || 'Stream connected'} ===`);
                }
            } catch (e) {
                appendStreamLine(event.data);
            }
        };
        
        browserStreamEventSource.onerror = () => {
            // Fall back to polling
            if (browserStreamActive) {
                browserStreamEventSource.close();
                browserStreamEventSource = null;
                startPollingStream();
            }
        };
    } catch (e) {
        startPollingStream();
    }
}

function startPollingStream() {
    updateStreamStatus('running', 'Polling...');
    
    // Initial fetch
    fetchStreamLogs();
    
    // Poll every second
    browserStreamInterval = setInterval(fetchStreamLogs, 1000);
}

async function fetchStreamLogs() {
    if (!browserStreamActive) return;
    
    try {
        const response = await fetch('/api/debug/debuglog?lines=50&format=json');
        const data = await response.json();
        
        if (data.lines) {
            const content = document.getElementById('browserStreamContent');
            content.textContent = data.lines.join('\n');
            streamLinesReceived = data.total_lines || 0;
            
            // Auto-scroll
            const viewer = document.getElementById('browserStreamViewer');
            viewer.scrollTop = viewer.scrollHeight;
        }
        
        updateStreamStats();
    } catch (e) {
        updateStreamStatus('error', `Error: ${e.message}`);
    }
}

function stopBrowserStream() {
    browserStreamActive = false;
    
    // Stop SSE
    if (browserStreamEventSource) {
        browserStreamEventSource.close();
        browserStreamEventSource = null;
    }
    
    // Stop polling
    if (browserStreamInterval) {
        clearInterval(browserStreamInterval);
        browserStreamInterval = null;
    }
    
    // Update UI
    document.getElementById('streamStartBtn').style.display = 'inline-flex';
    document.getElementById('streamStopBtn').style.display = 'none';
    
    updateStreamStatus('stopped', 'Stopped');
    
    const duration = streamStartTime ? Math.round((Date.now() - streamStartTime) / 1000) : 0;
    document.getElementById('streamStats').textContent = `Duration: ${duration}s | Lines: ${streamLinesReceived}`;
}

function appendStreamLine(line) {
    const content = document.getElementById('browserStreamContent');
    content.textContent += line + '\n';
    streamLinesReceived++;
    
    // Keep only last 500 lines to prevent memory issues
    const lines = content.textContent.split('\n');
    if (lines.length > 500) {
        content.textContent = lines.slice(-500).join('\n');
    }
    
    // Auto-scroll
    const viewer = document.getElementById('browserStreamViewer');
    viewer.scrollTop = viewer.scrollHeight;
    
    updateStreamStats();
}

function updateStreamStatus(state, text) {
    const statusBar = document.getElementById('browserStreamStatus');
    const dot = statusBar.querySelector('.status-dot');
    const textEl = statusBar.querySelector('.status-text');
    
    dot.className = 'status-dot ' + state;
    textEl.textContent = text;
}

function updateStreamStats() {
    const stats = document.getElementById('streamStats');
    const duration = streamStartTime ? Math.round((Date.now() - streamStartTime) / 1000) : 0;
    stats.textContent = `${duration}s | ${streamLinesReceived} lines`;
}

// Update stream commands with correct host/port on page load
function updateStreamCommands() {
    const port = window.location.port || '5050';
    const host = window.location.hostname;
    
    const tailCmd = document.getElementById('streamTailCmd');
    const sseCmd = document.getElementById('streamSSECmd');
    
    if (tailCmd) tailCmd.textContent = `curl -N http://${host}:${port}/api/debug/tail`;
    if (sseCmd) sseCmd.textContent = `curl -N http://${host}:${port}/api/debug/stream`;
}

// =============================================================================
// AI DEBUG ACCESS CONTROLS
// =============================================================================

let aiDebugConfig = {};

async function loadAIDebugConfig() {
    try {
        const response = await fetch('/api/ai-debug/config');
        const data = await response.json();
        aiDebugConfig = data.config || {};
        
        // Update port displays
        const port = data.port || '5050';
        document.getElementById('aiDebugPort').textContent = port;
        document.querySelectorAll('.ai-port').forEach(el => el.textContent = port);
        
        // Update toggle states
        for (const [key, value] of Object.entries(aiDebugConfig)) {
            const toggle = document.getElementById(`aiToggle_${key}`);
            if (toggle) toggle.checked = value;
        }
        
        // Update AI instructions
        updateAIInstructions(data);
        
    } catch (e) {
        console.error('Failed to load AI debug config:', e);
    }
}

async function updateAIDebugConfig() {
    const config = {};
    
    // Collect all toggle states
    const toggles = document.querySelectorAll('[id^="aiToggle_"]');
    toggles.forEach(toggle => {
        const key = toggle.id.replace('aiToggle_', '');
        config[key] = toggle.checked;
    });
    
    try {
        await fetch('/api/ai-debug/config', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(config)
        });
        
        aiDebugConfig = config;
        showToast('AI debug settings updated', 'success');
        
        // Refresh instructions
        loadAIDebugConfig();
    } catch (e) {
        showToast('Failed to update settings: ' + e.message, 'error');
    }
}

function updateAIInstructions(data) {
    const port = data.port || window.location.port || '5050';
    const host = window.location.hostname;
    
    const instructions = `# Shellder AI Debug Access

## Connection Info
- **Host**: ${host}
- **Port**: ${port}
- **Base URL**: http://${host}:${port}

## Quick Start
\`\`\`bash
# Get help and all available endpoints
curl http://${host}:${port}/api/ai-debug/help

# Run system diagnostics
curl http://${host}:${port}/api/ai-debug/diagnose

# Stream live logs (keep running)
curl -N http://${host}:${port}/api/debug/tail
\`\`\`

## Available Endpoints

### Read Files
\`\`\`bash
curl "http://${host}:${port}/api/ai-debug/file?path=.env"
curl "http://${host}:${port}/api/ai-debug/file?path=docker-compose.yaml"
\`\`\`

### Execute Commands
\`\`\`bash
curl -X POST -H "Content-Type: application/json" \\
  -d '{"cmd": "docker ps"}' \\
  http://${host}:${port}/api/ai-debug/exec
\`\`\`

### Docker Operations
\`\`\`bash
curl "http://${host}:${port}/api/ai-debug/docker?cmd=ps"
curl "http://${host}:${port}/api/ai-debug/docker?cmd=logs&container=rotom"
\`\`\`

### Database Queries
\`\`\`bash
curl -X POST -H "Content-Type: application/json" \\
  -d '{"database": "golbat", "query": "SHOW TABLES"}' \\
  http://${host}:${port}/api/ai-debug/sql
\`\`\`

### Get Logs
\`\`\`bash
curl "http://${host}:${port}/api/ai-debug/logs?type=shellder&lines=100"
curl "http://${host}:${port}/api/ai-debug/logs?type=container&container=dragonite"
\`\`\`

## WebSocket Access
Connect to: ws://${host}:${port}/socket.io/

Events to emit:
- \`ai_debug_exec\` - Execute commands
- \`ai_debug_file\` - Read/write files
- \`ai_debug_docker\` - Docker operations
- \`ai_debug_diagnose\` - Run diagnostics

Listen for: \`ai_debug_result\`

## Tips
1. Start with \`/api/ai-debug/diagnose\` to understand system state
2. Use \`/api/debug/tail\` for live log streaming
3. All file paths are relative to Aegis root
4. SQL queries are read-only for safety`;

    document.getElementById('aiInstructions').textContent = instructions;
}

function copyAIInstructions() {
    const instructions = document.getElementById('aiInstructions').textContent;
    navigator.clipboard.writeText(instructions).then(() => {
        showToast('Instructions copied! Paste to your AI assistant.', 'success');
    }).catch(() => {
        // Fallback
        const textarea = document.createElement('textarea');
        textarea.value = instructions;
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand('copy');
        document.body.removeChild(textarea);
        showToast('Instructions copied!', 'success');
    });
}

function copyTestCommand(type) {
    const port = window.location.port || '5050';
    const host = window.location.hostname;
    const cmd = `curl http://${host}:${port}/api/ai-debug/${type}`;
    
    navigator.clipboard.writeText(cmd).then(() => {
        showToast('Command copied!', 'success');
    });
}

async function runTestCommand(type) {
    const container = document.getElementById('testResultContainer');
    const result = document.getElementById('testResult');
    
    container.style.display = 'block';
    result.textContent = 'Running...';
    
    try {
        const response = await fetch(`/api/ai-debug/${type}`);
        const data = await response.json();
        result.textContent = JSON.stringify(data, null, 2);
    } catch (e) {
        result.textContent = 'Error: ' + e.message;
    }
}

// =============================================================================
// MCP SERVER CONTROLS
// =============================================================================

async function checkMCPStatus() {
    const dot = document.getElementById('mcpStatusDot');
    const text = document.getElementById('mcpStatusText');
    
    dot.className = 'status-dot checking';
    text.textContent = 'Checking API availability...';
    
    try {
        const response = await fetch('/api/ai-debug/config');
        const data = await response.json();
        
        if (data.config && data.config.api_enabled) {
            dot.className = 'status-dot running';
            text.textContent = `API Ready on port ${data.port} - MCP can connect`;
            
            // Update config with correct port
            updateMCPConfig(data.port);
        } else {
            dot.className = 'status-dot warning';
            text.textContent = 'API disabled - enable in settings above';
        }
    } catch (e) {
        dot.className = 'status-dot stopped';
        text.textContent = 'Cannot connect to Shellder API';
    }
}

function updateMCPConfig(port) {
    updateSSHCommand();
}

function updateMCPConfigWithIP() {
    updateSSHCommand();
}

function updateSSHCommand() {
    const ip = document.getElementById('linuxIPInput')?.value || 'YOUR_LINUX_IP';
    const sshCmd = document.getElementById('sshTunnelCmd');
    if (sshCmd) {
        sshCmd.textContent = 'ssh -L 5050:localhost:5050 pokemap@' + ip;
    }
}

function copySSHTunnel() {
    const sshCmd = document.getElementById('sshTunnelCmd');
    if (sshCmd) {
        navigator.clipboard.writeText(sshCmd.textContent).then(() => {
            showToast('SSH tunnel command copied!', 'success');
        });
    }
}

function copyAIInstructionsBlock() {
    const block = document.getElementById('aiInstructionsBlock');
    if (block) {
        navigator.clipboard.writeText(block.textContent).then(() => {
            showToast('AI instructions copied! Paste to your AI assistant.', 'success');
        }).catch(() => {
            const textarea = document.createElement('textarea');
            textarea.value = block.textContent;
            document.body.appendChild(textarea);
            textarea.select();
            document.execCommand('copy');
            document.body.removeChild(textarea);
            showToast('AI instructions copied!', 'success');
        });
    }
}

async function detectLinuxIP() {
    try {
        const response = await fetch('/api/ai-debug/system');
        const data = await response.json();
        
        // Try to get IP from various sources
        let ip = null;
        
        // The server knows its own hostname, we can use the current connection
        ip = window.location.hostname;
        
        if (ip && ip !== 'localhost' && ip !== '127.0.0.1') {
            document.getElementById('linuxIPInput').value = ip;
            updateMCPConfigWithIP();
            showToast(`Detected IP: ${ip}`, 'success');
        } else {
            // Try to get from exec
            const execResult = await fetch('/api/ai-debug/exec', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ cmd: "hostname -I | awk '{print $1}'" })
            });
            const execData = await execResult.json();
            if (execData.stdout) {
                ip = execData.stdout.trim();
                document.getElementById('linuxIPInput').value = ip;
                updateMCPConfigWithIP();
                showToast(`Detected IP: ${ip}`, 'success');
            } else {
                showToast('Could not detect IP. Enter manually.', 'warning');
            }
        }
    } catch (e) {
        showToast('Could not detect IP: ' + e.message, 'error');
    }
}


function copyMCPCommand(type) {
    let cmd = '';
    switch (type) {
        case 'install':
            cmd = 'cd ~/Desktop/Aegis-All-In-One/Shellder/mcp-server && npm install';
            break;
    }
    
    navigator.clipboard.writeText(cmd).then(() => {
        showToast('Command copied!', 'success');
    });
}

function copyMCPConfig() {
    const configEl = document.getElementById('mcpConfigJson');
    const config = configEl ? configEl.textContent : '';
    
    navigator.clipboard.writeText(config).then(() => {
        showToast('MCP configuration copied! Paste into Cursor MCP settings.', 'success');
    }).catch(() => {
        // Fallback
        const textarea = document.createElement('textarea');
        textarea.value = config;
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand('copy');
        document.body.removeChild(textarea);
        showToast('MCP configuration copied!', 'success');
    });
}

async function testMCPEndpoint(endpoint) {
    const container = document.getElementById('mcpTestResult');
    const output = document.getElementById('mcpTestOutput');
    
    container.style.display = 'block';
    output.textContent = `Testing /api/ai-debug/${endpoint}...`;
    
    try {
        let url = `/api/ai-debug/${endpoint}`;
        if (endpoint === 'docker') {
            url += '?cmd=ps';
        }
        
        const response = await fetch(url);
        const data = await response.json();
        
        output.textContent = JSON.stringify(data, null, 2);
        showToast(`${endpoint} endpoint working!`, 'success');
    } catch (e) {
        output.textContent = `Error: ${e.message}\n\nMake sure Shellder is running and AI Debug is enabled.`;
        showToast('Endpoint test failed', 'error');
    }
}

// View the server debug log (legacy, opens debug page)
async function viewDebugLog() {
    navigateTo('debug');
}

// Clear server debug log
async function clearServerDebugLog() {
    if (!confirm('Clear the server debug log?')) return;
    
    try {
        await fetch('/api/debug/clear', { method: 'POST' });
        loadDebugServerLog(); // Refresh the page view
        SHELLDER_DEBUG.info('DEBUG', 'Server debug log cleared');
        showToast('Debug log cleared', 'success');
    } catch (e) {
        showToast('Failed to clear: ' + e.message, 'error');
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
        
        // Disk auto-cleanup notification
        socket.on('disk_cleanup', (data) => {
            showToast(`🧹 Auto-cleanup freed ${data.freed}! (${data.reason})`, 'success');
            // Refresh disk health panel
            if (typeof loadDiskHealth === 'function') {
                loadDiskHealth();
            }
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
    
    // Fetch server timezone for log timestamp conversion
    try {
        fetchServerTimezone();
        SHELLDER_DEBUG.info('INIT', 'Server timezone fetch initiated');
    } catch (e) {
        SHELLDER_DEBUG.warn('INIT', 'Server timezone fetch failed (non-fatal)', { error: e.message });
    }
    
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
        'shellder-config': 'Shellder Configuration',
        'setup': 'Setup & Config',
        'devices': 'Devices',
        'stack': 'Stack Data',
        'xilriws': 'Xilriws Auth Proxy',
        'stats': 'Statistics',
        'nginx': 'Nginx & Security',
        'files': 'File Manager',
        'scripts': 'Scripts',
        'logs': 'Logs',
        'fletchling': 'Fletchling - Nest Detection',
        'poracle': 'Poracle - Discord & Telegram Alerts',
        'updates': 'Updates',
        'debug': 'Debug & Diagnostics'
    };
    document.getElementById('pageTitle').textContent = titles[page] || page;
    
    SHELLDER_DEBUG.state('currentPage', oldPage, page);
    currentPage = page;
    
    // Load page-specific data
    if (page === 'xilriws') {
        loadXilriwsStats();
        loadXilriwsLogs();
    } else if (page === 'logs') {
        currentLogSource = 'all';  // Reset to all stack logs
        loadStackLogs();
    } else if (page === 'updates') {
        checkGitStatus();
    } else if (page === 'containers') {
        loadContainerDetails();
    } else if (page === 'fletchling') {
        loadFletchlingStatus();
        loadNestStats();
        loadNestList();
    } else if (page === 'files') {
        navigateToPath(''); // Start at Aegis root
        loadCurrentUser(); // Show current user in toolbar
    } else if (page === 'debug') {
        loadDebugPage();
    } else if (page === 'shellder-config') {
        // Load shellder config when navigating to the page
        if (typeof loadShellderConfig === 'function') loadShellderConfig();
        if (typeof loadRawShellderConfig === 'function') loadRawShellderConfig();
    } else if (page === 'poracle') {
        // Load Poracle status when navigating to the page
        if (typeof loadPoracleStatus === 'function') loadPoracleStatus();
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
                <button class="btn btn-sm active" onclick="loadMetricHistory('${metric}', 0.167)">10m</button>
                <button class="btn btn-sm" onclick="loadMetricHistory('${metric}', 1)">1h</button>
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
    
    // Default to 10 minutes for quick feedback
    loadMetricHistory(metric, 0.167);
}

// Track active metric history request for cancellation
let activeMetricHistoryController = null;

async function loadMetricHistory(metric, hours) {
    const chartEl = document.getElementById('metricChart');
    const statsEl = document.getElementById('metricStats');
    
    // Cancel any pending request when switching time periods
    if (activeMetricHistoryController) {
        activeMetricHistoryController.abort();
    }
    activeMetricHistoryController = new AbortController();
    
    // Update button states to show which is active
    const hoursToLabel = {0.167: '10m', 1: '1h', 6: '6h', 24: '24h', 168: '7d'};
    const targetLabel = hoursToLabel[hours] || '';
    document.querySelectorAll('.metric-time-controls .btn').forEach(btn => {
        btn.classList.toggle('active', btn.textContent.trim() === targetLabel);
    });
    
    chartEl.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        const metricName = metric === 'cpu' ? 'cpu_percent' : 
                         metric === 'memory' ? 'memory_percent' : 'disk_percent';
        
        const response = await fetch(`/api/metrics/history/${metricName}?hours=${hours}`, {
            signal: activeMetricHistoryController.signal
        });
        const data = await response.json();
        
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
        
        // For chart scaling - use dynamic scale based on data range
        // This makes small variations visible while keeping perspective
        // Scale max is the larger of: actual max rounded up, or 100% for percentage metrics
        const isPercentMetric = metricName.includes('percent');
        let scaleMax, scaleMin;
        
        if (isPercentMetric) {
            // For percentages, use 0-100 scale but auto-zoom if all values are low
            if (max < 30) {
                // Zoom in for low utilization - makes variations visible
                scaleMax = Math.ceil(max * 1.5 / 10) * 10; // Round up to nearest 10
                scaleMax = Math.max(scaleMax, 10); // At least 10%
            } else {
                scaleMax = 100;
            }
            scaleMin = 0;
        } else {
            // For other metrics, auto-scale to data range with padding
            scaleMax = max * 1.1;
            scaleMin = Math.max(0, min * 0.9);
        }
        
        // Generate time labels for X-axis (show ~5 labels evenly spaced)
        const dataLen = data.data.length;
        const timeLabels = [];
        const labelCount = Math.min(5, dataLen);
        for (let i = 0; i < labelCount; i++) {
            const idx = Math.floor(i * (dataLen - 1) / (labelCount - 1 || 1));
            const time = new Date(data.data[idx].time);
            // Format based on time range
            const label = hours < 1 ? time.toLocaleTimeString([], {hour: '2-digit', minute: '2-digit', second: '2-digit'}) :
                         hours <= 24 ? time.toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'}) :
                         time.toLocaleDateString([], {month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'});
            timeLabels.push(label);
        }
        
        // Render chart bars - use flex:1 so bars fill available space evenly
        const chartBars = data.data.map((d, i) => {
            // Calculate height based on dynamic scale, not fixed 0-100%
            const normalizedValue = (d.value - scaleMin) / (scaleMax - scaleMin);
            const height = Math.max(2, normalizedValue * 100);
            
            // Color based on percentage of scale max, not absolute value
            let colorClass;
            if (isPercentMetric) {
                colorClass = d.value < 50 ? 'low' : d.value < 80 ? 'medium' : 'high';
            } else {
                const pctOfMax = d.value / max;
                colorClass = pctOfMax < 0.5 ? 'low' : pctOfMax < 0.8 ? 'medium' : 'high';
            }
            
            const time = new Date(d.time).toLocaleTimeString();
            const valueStr = isPercentMetric ? `${d.value.toFixed(1)}%` : d.value.toFixed(1);
            return `<div class="chart-bar ${colorClass}" style="height: ${height}%;" 
                        title="${valueStr} at ${time}"></div>`;
        }).join('');
        
        // Format time period for display
        const periodLabel = hours < 1 ? `${Math.round(hours * 60)} minutes` : 
                          hours < 24 ? `${hours} hour(s)` : 
                          `${Math.round(hours / 24)} day(s)`;
        
        // Generate Y-axis labels based on scale
        const yAxisLabels = isPercentMetric ? [
            `${scaleMax.toFixed(0)}%`,
            `${(scaleMax * 0.75).toFixed(0)}%`,
            `${(scaleMax * 0.5).toFixed(0)}%`,
            `${(scaleMax * 0.25).toFixed(0)}%`,
            `${scaleMin.toFixed(0)}%`
        ] : [
            scaleMax.toFixed(1),
            (scaleMax * 0.75 + scaleMin * 0.25).toFixed(1),
            ((scaleMax + scaleMin) / 2).toFixed(1),
            (scaleMax * 0.25 + scaleMin * 0.75).toFixed(1),
            scaleMin.toFixed(1)
        ];
        
        chartEl.innerHTML = `
            <div class="chart-wrapper">
                <div class="chart-y-axis">
                    ${yAxisLabels.map(l => `<span>${l}</span>`).join('')}
                </div>
                <div class="chart-main">
                    <div class="chart-bars">${chartBars}</div>
                    <div class="chart-x-axis">
                        ${timeLabels.map(l => `<span>${l}</span>`).join('')}
                    </div>
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
                <small>${data.data.length} data points over ${periodLabel}</small>
            </div>
        `;
        
    } catch (e) {
        // Ignore AbortError - this happens when user switches time periods quickly
        if (e.name === 'AbortError') {
            return;
        }
        SHELLDER_DEBUG.error('METRICS', `Failed to load history for ${metric}: ${e.message}`);
        chartEl.innerHTML = `<div class="text-danger">Failed to load history<br><small>Metrics are collected every 30 seconds. If you just started the server, please wait.</small></div>`;
        statsEl.innerHTML = '';
    } finally {
        // Clear controller if this was the active request
        activeMetricHistoryController = null;
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
        
        // Escape proxy for use in onclick attribute (replace single quotes)
        const escapedProxy = proxy.replace(/'/g, "\\'");
        html += `
            <tr class="${rowClass} clickable-row" onclick="showProxyDetails('${escapedProxy}')" style="cursor: pointer;" title="Click to view detailed stats">
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

// Show detailed proxy stats modal
async function showProxyDetails(proxyAddress) {
    const modal = document.getElementById('proxyDetailsModal');
    const content = document.getElementById('proxyDetailsContent');
    
    if (!modal || !content) {
        console.error('Proxy details modal not found');
        return;
    }
    
    // Use classList.add('active') - CSS uses !important so style.display won't work
    modal.classList.add('active');
    content.innerHTML = '<div class="loading">Loading proxy details...</div>';
    
    try {
        // URL encode the proxy address for the API call
        const encodedProxy = encodeURIComponent(proxyAddress);
        const data = await fetchAPI(`/api/xilriws/proxy/${encodedProxy}/stats`);
        
        if (data.error) {
            content.innerHTML = `<div class="error-msg">Error: ${data.error}</div>`;
            return;
        }
        
        const allTime = data.all_time || {};
        const session = data.current_session || {};
        
        // Calculate percentages
        const allTimeTotal = allTime.total_requests || 0;
        const allTimeSuccessRate = allTimeTotal > 0 
            ? ((allTime.successful || 0) / allTimeTotal * 100).toFixed(1) 
            : '0.0';
        const sessionTotal = session.requests || 0;
        const sessionSuccessRate = sessionTotal > 0 
            ? ((session.success || 0) / sessionTotal * 100).toFixed(1) 
            : '0.0';
        
        content.innerHTML = `
            <div class="proxy-details">
                <div class="proxy-details-header">
                    <h3>${escapeHtml(proxyAddress)}</h3>
                    <div class="proxy-meta">
                        ${data.first_seen ? `<div><strong>First Seen:</strong> ${formatTime(data.first_seen)}</div>` : ''}
                        ${data.last_seen ? `<div><strong>Last Seen:</strong> ${formatTime(data.last_seen)}</div>` : ''}
                    </div>
                </div>
                
                <div class="proxy-stats-sections">
                    <div class="proxy-stats-section">
                        <h4>📈 All-Time Statistics</h4>
                        <div class="stats-grid-detailed">
                            <div class="stat-item">
                                <span class="stat-label">Total Requests</span>
                                <span class="stat-value">${allTimeTotal.toLocaleString()}</span>
                            </div>
                            <div class="stat-item">
                                <span class="stat-label">Successful</span>
                                <span class="stat-value success">${(allTime.successful || 0).toLocaleString()}</span>
                            </div>
                            <div class="stat-item">
                                <span class="stat-label">Failed</span>
                                <span class="stat-value danger">${(allTime.failed || 0).toLocaleString()}</span>
                            </div>
                            <div class="stat-item">
                                <span class="stat-label">Success Rate</span>
                                <span class="stat-value ${allTimeSuccessRate > 80 ? 'success' : allTimeSuccessRate > 50 ? 'warning' : 'danger'}">${allTimeSuccessRate}%</span>
                            </div>
                            <div class="stat-item">
                                <span class="stat-label">Timeouts</span>
                                <span class="stat-value">${(allTime.timeouts || 0).toLocaleString()}</span>
                            </div>
                            <div class="stat-item">
                                <span class="stat-label">Unreachable</span>
                                <span class="stat-value">${(allTime.unreachable || 0).toLocaleString()}</span>
                            </div>
                            <div class="stat-item">
                                <span class="stat-label">Bot Blocked</span>
                                <span class="stat-value">${(allTime.bot_blocked || 0).toLocaleString()}</span>
                            </div>
                        </div>
                    </div>
                    
                    <div class="proxy-stats-section">
                        <h4>🔄 Current Session</h4>
                        <div class="stats-grid-detailed">
                            <div class="stat-item">
                                <span class="stat-label">Requests</span>
                                <span class="stat-value">${sessionTotal.toLocaleString()}</span>
                            </div>
                            <div class="stat-item">
                                <span class="stat-label">Successful</span>
                                <span class="stat-value success">${(session.success || 0).toLocaleString()}</span>
                            </div>
                            <div class="stat-item">
                                <span class="stat-label">Failed</span>
                                <span class="stat-value danger">${(session.fail || 0).toLocaleString()}</span>
                            </div>
                            <div class="stat-item">
                                <span class="stat-label">Success Rate</span>
                                <span class="stat-value ${sessionSuccessRate > 80 ? 'success' : sessionSuccessRate > 50 ? 'warning' : 'danger'}">${sessionSuccessRate}%</span>
                            </div>
                            <div class="stat-item">
                                <span class="stat-label">Timeouts</span>
                                <span class="stat-value">${(session.timeout || 0).toLocaleString()}</span>
                            </div>
                            <div class="stat-item">
                                <span class="stat-label">Unreachable</span>
                                <span class="stat-value">${(session.unreachable || 0).toLocaleString()}</span>
                            </div>
                            <div class="stat-item">
                                <span class="stat-label">Bot Blocked</span>
                                <span class="stat-value">${(session.bot_blocked || 0).toLocaleString()}</span>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        `;
    } catch (e) {
        content.innerHTML = `<div class="error-msg">Failed to load proxy details: ${e.message}</div>`;
    }
}

function closeProxyDetails() {
    const modal = document.getElementById('proxyDetailsModal');
    if (modal) {
        modal.classList.remove('active');
    }
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
// DOCKER UPDATE ALL & FORCE REBUILD
// =============================================================================

async function dockerUpdateAll() {
    // Show confirmation dialog
    const confirmed = await showConfirmDialog(
        '⬆️ Update All Containers',
        `<p>This will:</p>
        <ol style="margin: 10px 0 10px 20px; color: var(--text-secondary);">
            <li>Pull the latest images for all containers</li>
            <li>Stop all running containers</li>
            <li>Recreate containers with new images</li>
            <li>Start all containers</li>
        </ol>
        <p class="text-warning" style="margin-top: 10px;">⚠️ This may cause brief service interruption.</p>
        <p style="margin-top: 10px;">Continue?</p>`,
        'Update All',
        'btn-primary'
    );
    
    if (!confirmed) return;
    
    showDockerProgress('Updating all containers... This may take a few minutes.');
    
    try {
        const result = await fetchAPI('/api/docker/update-all', {
            method: 'POST'
        });
        
        hideDockerProgress();
        
        if (result.success) {
            showToast('✅ All containers updated successfully!', 'success');
            // Show detailed results in modal
            showDockerOperationResult('Update All Results', result);
        } else {
            showToast(`❌ Update failed: ${result.error || 'Unknown error'}`, 'error');
            if (result.output) {
                showDockerOperationResult('Update Error Details', result);
            }
        }
        
        // Refresh data after update
        setTimeout(() => {
            refreshData();
            if (currentPage === 'containers') {
                loadContainerDetails();
                loadDockerHealth();
            }
        }, 2000);
        
    } catch (error) {
        hideDockerProgress();
        showToast(`❌ Update operation failed: ${error.message}`, 'error');
    }
}

async function dockerForceRebuild() {
    // Show confirmation dialog with warning
    const confirmed = await showConfirmDialog(
        '🔨 Force Rebuild All Containers',
        `<p><strong style="color: var(--warning);">⚠️ This is an advanced operation!</strong></p>
        <p style="margin: 10px 0;">This will:</p>
        <ol style="margin: 10px 0 10px 20px; color: var(--text-secondary);">
            <li>Stop all running containers</li>
            <li>Remove all containers</li>
            <li>Pull fresh images (no cache)</li>
            <li>Rebuild and start all containers from scratch</li>
        </ol>
        <p class="text-danger" style="margin-top: 10px;">🚨 This will cause extended downtime and may take several minutes.</p>
        <p style="margin-top: 10px;">Are you sure you want to force rebuild?</p>`,
        'Force Rebuild',
        'btn-warning'
    );
    
    if (!confirmed) return;
    
    showDockerProgress('Force rebuilding all containers... This may take several minutes.');
    
    try {
        const result = await fetchAPI('/api/docker/rebuild', {
            method: 'POST'
        });
        
        hideDockerProgress();
        
        if (result.success) {
            showToast('✅ All containers rebuilt successfully!', 'success');
            showDockerOperationResult('Force Rebuild Results', result);
        } else {
            showToast(`❌ Rebuild failed: ${result.error || 'Unknown error'}`, 'error');
            if (result.output) {
                showDockerOperationResult('Rebuild Error Details', result);
            }
        }
        
        // Refresh data after rebuild
        setTimeout(() => {
            refreshData();
            if (currentPage === 'containers') {
                loadContainerDetails();
                loadDockerHealth();
            }
        }, 3000);
        
    } catch (error) {
        hideDockerProgress();
        showToast(`❌ Rebuild operation failed: ${error.message}`, 'error');
    }
}

async function dockerPrune() {
    const confirmed = await showConfirmDialog(
        '🧹 Docker Prune',
        `<p>This will remove:</p>
        <ul style="margin: 10px 0 10px 20px; color: var(--text-secondary);">
            <li>Stopped containers</li>
            <li>Unused networks</li>
            <li>Dangling images</li>
            <li>Build cache</li>
        </ul>
        <p style="margin-top: 10px;">This can free up significant disk space. Continue?</p>`,
        'Prune',
        'btn-warning'
    );
    
    if (!confirmed) return;
    
    showToast('🧹 Cleaning up unused Docker resources...', 'info');
    
    try {
        const result = await fetchAPI('/api/docker/prune', {
            method: 'POST'
        });
        
        if (result.success) {
            const freed = result.space_freed || 'some';
            showToast(`✅ Cleanup complete! Freed ${freed} of disk space.`, 'success');
            loadDockerHealth(); // Refresh to show new disk usage
        } else {
            showToast(`❌ Prune failed: ${result.error}`, 'error');
        }
    } catch (error) {
        showToast(`❌ Prune operation failed`, 'error');
    }
}

function showDockerProgress(message) {
    // Create progress overlay if it doesn't exist
    let progressEl = document.getElementById('dockerOperationProgress');
    if (!progressEl) {
        progressEl = document.createElement('div');
        progressEl.id = 'dockerOperationProgress';
        progressEl.className = 'docker-operation-progress';
        progressEl.innerHTML = `
            <div class="spinner"></div>
            <span class="progress-text">${message}</span>
        `;
        document.body.appendChild(progressEl);
    } else {
        progressEl.querySelector('.progress-text').textContent = message;
    }
    progressEl.classList.add('active');
}

function hideDockerProgress() {
    const progressEl = document.getElementById('dockerOperationProgress');
    if (progressEl) {
        progressEl.classList.remove('active');
    }
}

function showDockerOperationResult(title, result) {
    let content = '';
    
    if (result.steps) {
        content += '<div class="operation-steps">';
        result.steps.forEach(step => {
            const icon = step.success ? '✅' : '❌';
            content += `<div class="operation-step ${step.success ? 'success' : 'error'}">
                <span class="step-icon">${icon}</span>
                <span class="step-name">${step.name}</span>
                ${step.duration ? `<span class="step-duration">${step.duration}</span>` : ''}
            </div>`;
        });
        content += '</div>';
    }
    
    if (result.output) {
        content += `<pre class="log-viewer" style="max-height: 300px; margin-top: 12px;">${escapeHtml(result.output)}</pre>`;
    }
    
    if (result.duration) {
        content += `<p style="margin-top: 12px; color: var(--text-muted);">⏱️ Total time: ${result.duration}</p>`;
    }
    
    openModal(title, content);
}

async function showConfirmDialog(title, message, confirmText = 'Confirm', confirmClass = 'btn-primary') {
    return new Promise((resolve) => {
        openModal(title, message, [
            { text: 'Cancel', class: 'btn', onclick: () => { closeModal(); resolve(false); } },
            { text: confirmText, class: `btn ${confirmClass}`, onclick: () => { closeModal(); resolve(true); } }
        ]);
    });
}

// =============================================================================
// DOCKER HEALTH MONITORING
// =============================================================================

async function loadDockerHealth() {
    try {
        const health = await fetchAPI('/api/docker/health');
        updateDockerHealthDisplay(health);
    } catch (error) {
        console.error('Failed to load Docker health:', error);
        setHealthStatusError();
    }
}

function updateDockerHealthDisplay(health) {
    // Docker Daemon Status
    const daemonEl = document.getElementById('dockerDaemonStatus');
    if (daemonEl && health.daemon) {
        const daemon = health.daemon;
        daemonEl.querySelector('.health-status-text').textContent = 
            daemon.running ? `Running (${daemon.version || 'unknown version'})` : 'Not Running';
        daemonEl.querySelector('.health-indicator').className = 
            `health-indicator ${daemon.running ? 'healthy' : 'error'}`;
    }
    
    // Docker Compose Status
    const composeEl = document.getElementById('dockerComposeStatus');
    if (composeEl && health.compose) {
        const compose = health.compose;
        composeEl.querySelector('.health-status-text').textContent = 
            compose.available ? `Available (${compose.version || 'v2'})` : 'Not Found';
        composeEl.querySelector('.health-indicator').className = 
            `health-indicator ${compose.available ? 'healthy' : 'error'}`;
    }
    
    // Docker Network Status
    const networkEl = document.getElementById('dockerNetworkStatus');
    if (networkEl && health.networks) {
        const networks = health.networks;
        networkEl.querySelector('.health-status-text').textContent = 
            `${networks.count || 0} networks (${networks.aegis_network ? 'Aegis OK' : 'Aegis missing'})`;
        networkEl.querySelector('.health-indicator').className = 
            `health-indicator ${networks.aegis_network ? 'healthy' : 'warning'}`;
    }
    
    // Docker Volumes Status
    const volumesEl = document.getElementById('dockerVolumesStatus');
    if (volumesEl && health.volumes) {
        const volumes = health.volumes;
        volumesEl.querySelector('.health-status-text').textContent = 
            `${volumes.count || 0} volumes`;
        volumesEl.querySelector('.health-indicator').className = 
            `health-indicator healthy`;
    }
    
    // Docker Info Section
    if (health.info) {
        const info = health.info;
        document.getElementById('dockerRoot').textContent = info.docker_root || '--';
        document.getElementById('dockerVersion').textContent = info.version || '--';
        document.getElementById('composeFile').textContent = info.compose_file || '--';
        document.getElementById('totalImages').textContent = info.images_count || '--';
        document.getElementById('dockerDiskUsage').textContent = info.disk_usage || '--';
    }
}

function setHealthStatusError() {
    const indicators = document.querySelectorAll('.health-indicator');
    indicators.forEach(el => {
        el.className = 'health-indicator error';
    });
    
    const statusTexts = document.querySelectorAll('.health-status-text');
    statusTexts.forEach(el => {
        el.textContent = 'Failed to check';
    });
}

async function checkAllContainerPorts() {
    const gridEl = document.getElementById('portHealthGrid');
    gridEl.innerHTML = '<div class="loading">Checking container ports... This may take a moment.</div>';
    
    try {
        const result = await fetchAPI('/api/docker/port-check');
        
        if (!result.ports || result.ports.length === 0) {
            gridEl.innerHTML = '<div class="loading">No containers with exposed ports found</div>';
            return;
        }
        
        gridEl.innerHTML = result.ports.map(port => {
            const statusClass = port.running ? (port.accessible ? 'accessible' : 'inaccessible') : 'not-running';
            const icon = port.running ? (port.accessible ? '✅' : '❌') : '⏸️';
            const statusText = port.running ? (port.accessible ? 'Accessible' : 'Unreachable') : 'Not Running';
            
            return `
                <div class="port-health-item ${statusClass}">
                    <span class="port-icon">${icon}</span>
                    <div class="port-info">
                        <div class="port-name">${port.container}</div>
                        <div class="port-details">
                            <span>Port: ${port.internal_port}</span>
                            ${port.host_port ? `<span>→ ${port.host_port}</span>` : ''}
                        </div>
                    </div>
                    <span class="port-status ${statusClass}">${statusText}</span>
                    ${port.response_time ? `<span class="port-response-time ${port.response_time < 100 ? 'fast' : 'slow'}">${port.response_time}ms</span>` : ''}
                </div>
            `;
        }).join('');
        
        // Add summary
        const accessible = result.ports.filter(p => p.accessible).length;
        const running = result.ports.filter(p => p.running).length;
        const total = result.ports.length;
        
        gridEl.innerHTML += `
            <div class="port-health-summary" style="grid-column: 1 / -1; margin-top: 12px; padding: 10px; background: var(--bg-secondary); border-radius: var(--radius-sm); text-align: center; font-size: 12px; color: var(--text-muted);">
                📊 Summary: ${accessible}/${running} running containers accessible | ${running}/${total} containers running
            </div>
        `;
        
    } catch (error) {
        gridEl.innerHTML = `<div class="error-msg">Failed to check ports: ${error.message}</div>`;
    }
}

// =============================================================================
// DOCKER INSTALLATION & SERVICE MANAGEMENT
// =============================================================================

async function dockerServiceAction(action) {
    const actionNames = {
        'start': 'Starting Docker service',
        'stop': 'Stopping Docker service',
        'restart': 'Restarting Docker service',
        'enable': 'Enabling Docker service',
        'disable': 'Disabling Docker service'
    };
    
    showToast(`${actionNames[action]}...`, 'info');
    
    try {
        const result = await fetchAPI(`/api/docker/service/${action}`, {
            method: 'POST'
        });
        
        if (result.success) {
            showToast(`✅ ${actionNames[action]} completed`, 'success');
            // Refresh health status after service action
            setTimeout(() => loadDockerHealth(), 2000);
        } else {
            showToast(`❌ Failed: ${result.error}`, 'error');
        }
    } catch (error) {
        showToast(`❌ Service action failed: ${error.message}`, 'error');
    }
}

async function installDockerComponent(component) {
    const componentNames = {
        'engine': 'Docker Engine',
        'compose': 'Docker Compose',
        'buildx': 'Docker Buildx',
        'all': 'Full Docker Setup'
    };
    
    const componentName = componentNames[component] || component;
    
    // Show confirmation
    const confirmed = await showConfirmDialog(
        `🔧 Install ${componentName}`,
        `<p>This will install ${componentName} on your server.</p>
        <p style="margin-top: 10px; color: var(--text-muted);">
            ${component === 'all' 
                ? 'This includes Docker Engine, Docker Compose, and Buildx plugin, plus recommended configuration.'
                : `This will download and install ${componentName}.`
            }
        </p>
        <p class="text-warning" style="margin-top: 10px;">⚠️ Requires sudo access. The server will run installation commands.</p>
        <p style="margin-top: 10px;">Continue?</p>`,
        'Install',
        'btn-primary'
    );
    
    if (!confirmed) return;
    
    // Show progress modal
    openModal(`Installing ${componentName}`, `
        <div class="install-progress">
            <div class="install-progress-steps" id="installSteps">
                <div class="install-step running">
                    <span class="step-icon">⏳</span>
                    <div class="step-info">
                        <div class="step-name">Preparing installation...</div>
                        <div class="step-status">Please wait</div>
                    </div>
                </div>
            </div>
            <div class="install-output" id="installOutput">Starting installation...</div>
        </div>
    `);
    
    try {
        const result = await fetchAPI(`/api/docker/install/${component}`, {
            method: 'POST'
        });
        
        // Update modal with results
        const stepsHtml = (result.steps || []).map(step => `
            <div class="install-step ${step.success ? 'success' : 'error'}">
                <span class="step-icon">${step.success ? '✅' : '❌'}</span>
                <div class="step-info">
                    <div class="step-name">${step.name}</div>
                    <div class="step-status">${step.success ? 'Completed' : step.error || 'Failed'}</div>
                </div>
            </div>
        `).join('');
        
        document.getElementById('installSteps').innerHTML = stepsHtml || `
            <div class="install-step ${result.success ? 'success' : 'error'}">
                <span class="step-icon">${result.success ? '✅' : '❌'}</span>
                <div class="step-info">
                    <div class="step-name">${result.success ? 'Installation completed' : 'Installation failed'}</div>
                    <div class="step-status">${result.message || ''}</div>
                </div>
            </div>
        `;
        
        document.getElementById('installOutput').textContent = result.output || 'No output';
        
        if (result.success) {
            showToast(`✅ ${componentName} installed successfully!`, 'success');
        } else {
            showToast(`❌ Installation failed: ${result.error}`, 'error');
        }
        
        // Refresh health status
        setTimeout(() => {
            loadDockerHealth();
            loadDockerInstallStatus();
        }, 2000);
        
    } catch (error) {
        document.getElementById('installSteps').innerHTML = `
            <div class="install-step error">
                <span class="step-icon">❌</span>
                <div class="step-info">
                    <div class="step-name">Installation failed</div>
                    <div class="step-status">${error.message}</div>
                </div>
            </div>
        `;
        showToast(`❌ Installation failed: ${error.message}`, 'error');
    }
}

async function loadDockerInstallStatus() {
    try {
        const status = await fetchAPI('/api/docker/install-status');
        
        // Update Docker Engine status
        const engineStatusEl = document.getElementById('dockerEngineStatus');
        if (engineStatusEl) {
            if (status.engine.installed) {
                engineStatusEl.textContent = `Installed (${status.engine.version})`;
                engineStatusEl.className = 'install-status installed';
                document.getElementById('installDockerEngine')?.classList.add('installed');
                document.getElementById('installDockerEngine')?.classList.remove('not-installed');
            } else {
                engineStatusEl.textContent = 'Not installed';
                engineStatusEl.className = 'install-status not-installed';
                document.getElementById('installDockerEngine')?.classList.add('not-installed');
                document.getElementById('installDockerEngine')?.classList.remove('installed');
            }
        }
        
        // Update Docker Compose status
        const composeStatusEl = document.getElementById('dockerComposeInstallStatus');
        if (composeStatusEl) {
            if (status.compose.installed) {
                composeStatusEl.textContent = `Installed (${status.compose.version})`;
                composeStatusEl.className = 'install-status installed';
                document.getElementById('installDockerCompose')?.classList.add('installed');
                document.getElementById('installDockerCompose')?.classList.remove('not-installed');
            } else {
                composeStatusEl.textContent = 'Not installed';
                composeStatusEl.className = 'install-status not-installed';
                document.getElementById('installDockerCompose')?.classList.add('not-installed');
                document.getElementById('installDockerCompose')?.classList.remove('installed');
            }
        }
        
        // Update Buildx status
        const buildxStatusEl = document.getElementById('dockerBuildxStatus');
        if (buildxStatusEl) {
            if (status.buildx.installed) {
                buildxStatusEl.textContent = `Installed (${status.buildx.version})`;
                buildxStatusEl.className = 'install-status installed';
                document.getElementById('installDockerBuildx')?.classList.add('installed');
                document.getElementById('installDockerBuildx')?.classList.remove('not-installed');
            } else {
                buildxStatusEl.textContent = 'Not installed';
                buildxStatusEl.className = 'install-status not-installed';
                document.getElementById('installDockerBuildx')?.classList.add('not-installed');
                document.getElementById('installDockerBuildx')?.classList.remove('installed');
            }
        }
        
    } catch (error) {
        console.error('Failed to load Docker install status:', error);
    }
}

// =============================================================================
// DOCKER CONFIGURATION FILE MANAGEMENT
// =============================================================================

let currentDockerConfig = null;

async function loadDockerConfigs() {
    try {
        const configs = await fetchAPI('/api/docker/configs');
        
        // Update config statuses
        updateConfigStatus('daemonJsonStatus', configs.daemon);
        updateConfigStatus('dockerServiceStatus', configs.service);
        updateConfigStatus('composeOverrideStatus', configs.compose_override);
        updateConfigStatus('dockerEnvStatus', configs.env);
        updateConfigStatus('registriesStatus', configs.registries);
        updateConfigStatus('logrotateStatus', configs.logrotate);
        
        // Update config items with exists/missing class
        document.querySelectorAll('.docker-config-item').forEach(item => {
            const statusEl = item.querySelector('.config-status');
            if (statusEl) {
                if (statusEl.classList.contains('exists')) {
                    item.classList.add('exists');
                    item.classList.remove('missing');
                } else {
                    item.classList.add('missing');
                    item.classList.remove('exists');
                }
            }
        });
        
    } catch (error) {
        console.error('Failed to load Docker configs:', error);
    }
}

function updateConfigStatus(elementId, config) {
    const el = document.getElementById(elementId);
    if (!el) return;
    
    if (config && config.exists) {
        el.textContent = config.size || 'Exists';
        el.className = 'config-status exists';
    } else if (config && config.error) {
        el.textContent = 'Error';
        el.className = 'config-status error';
    } else {
        el.textContent = 'Not found';
        el.className = 'config-status missing';
    }
}

async function editDockerConfig(configType) {
    currentDockerConfig = configType;
    
    const configNames = {
        'daemon': 'daemon.json',
        'service': 'docker.service override',
        'compose-override': 'docker-compose.override.yml',
        'env': '.env',
        'registries': 'registries.conf',
        'logrotate': 'docker-logrotate'
    };
    
    const editorEl = document.getElementById('dockerConfigEditor');
    const titleEl = document.getElementById('configEditorTitle');
    const pathEl = document.getElementById('configEditorPath');
    const contentEl = document.getElementById('dockerConfigContent');
    
    titleEl.textContent = `Edit ${configNames[configType] || configType}`;
    contentEl.value = 'Loading...';
    editorEl.style.display = 'block';
    
    // Scroll to editor
    editorEl.scrollIntoView({ behavior: 'smooth', block: 'start' });
    
    try {
        const result = await fetchAPI(`/api/docker/config/${configType}`);
        
        pathEl.textContent = result.path || 'Unknown path';
        
        if (result.exists) {
            contentEl.value = result.content || '';
        } else {
            // Provide template for new file
            contentEl.value = result.template || getConfigTemplate(configType);
            contentEl.placeholder = 'File does not exist. Edit and save to create.';
        }
        
    } catch (error) {
        contentEl.value = `Error loading config: ${error.message}`;
    }
}

function getConfigTemplate(configType) {
    const templates = {
        'daemon': `{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "live-restore": true
}`,
        'service': `[Service]
# Add Docker service overrides here
# Example:
# Environment="HTTP_PROXY=http://proxy.example.com:80"
# Environment="HTTPS_PROXY=https://proxy.example.com:443"
`,
        'compose-override': `version: '3.8'
# Override settings for local development
# This file is merged with docker-compose.yaml

services:
  # Example: override a service setting
  # reactmap:
  #   environment:
  #     - DEBUG=true
`,
        'env': `# Docker Compose Environment Variables
# These are used by docker-compose.yaml

# Database
MYSQL_ROOT_PASSWORD=your_root_password
MYSQL_DATABASE=aegis
MYSQL_USER=aegis
MYSQL_PASSWORD=your_password

# Ports (uncomment to override defaults)
# REACTMAP_PORT=6001
# DRAGONITE_PORT=7272
`,
        'registries': `# Container registry configuration
unqualified-search-registries = ["docker.io"]

[[registry]]
prefix = "docker.io"
location = "docker.io"
`,
        'logrotate': `/var/lib/docker/containers/*/*.log {
    rotate 7
    daily
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
`
    };
    
    return templates[configType] || '# Configuration file\n';
}

function closeDockerConfigEditor() {
    document.getElementById('dockerConfigEditor').style.display = 'none';
    currentDockerConfig = null;
}

async function saveDockerConfig() {
    if (!currentDockerConfig) return;
    
    const content = document.getElementById('dockerConfigContent').value;
    
    showToast('Saving configuration...', 'info');
    
    try {
        const result = await fetchAPI(`/api/docker/config/${currentDockerConfig}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ content })
        });
        
        if (result.success) {
            showToast('✅ Configuration saved!', 'success');
            loadDockerConfigs(); // Refresh status
        } else {
            showToast(`❌ Failed to save: ${result.error}`, 'error');
        }
    } catch (error) {
        showToast(`❌ Save failed: ${error.message}`, 'error');
    }
}

async function saveDockerConfigAndRestart() {
    if (!currentDockerConfig) return;
    
    const content = document.getElementById('dockerConfigContent').value;
    
    const confirmed = await showConfirmDialog(
        '💾 Save & Restart Docker',
        `<p>This will save the configuration and restart the Docker service.</p>
        <p class="text-warning" style="margin-top: 10px;">⚠️ All running containers will be temporarily stopped during restart.</p>
        <p style="margin-top: 10px;">Continue?</p>`,
        'Save & Restart',
        'btn-warning'
    );
    
    if (!confirmed) return;
    
    showDockerProgress('Saving configuration and restarting Docker...');
    
    try {
        // Save first
        const saveResult = await fetchAPI(`/api/docker/config/${currentDockerConfig}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ content })
        });
        
        if (!saveResult.success) {
            hideDockerProgress();
            showToast(`❌ Failed to save: ${saveResult.error}`, 'error');
            return;
        }
        
        // Then restart Docker
        const restartResult = await fetchAPI('/api/docker/service/restart', {
            method: 'POST'
        });
        
        hideDockerProgress();
        
        if (restartResult.success) {
            showToast('✅ Configuration saved and Docker restarted!', 'success');
            closeDockerConfigEditor();
            
            // Wait a bit then refresh everything
            setTimeout(() => {
                loadDockerHealth();
                loadDockerConfigs();
                loadContainerDetails();
            }, 5000);
        } else {
            showToast(`⚠️ Config saved but restart failed: ${restartResult.error}`, 'warning');
        }
        
    } catch (error) {
        hideDockerProgress();
        showToast(`❌ Operation failed: ${error.message}`, 'error');
    }
}

async function validateDockerConfig() {
    if (!currentDockerConfig) return;
    
    const content = document.getElementById('dockerConfigContent').value;
    
    // Client-side validation for JSON configs
    if (currentDockerConfig === 'daemon') {
        try {
            JSON.parse(content);
            showToast('✅ Valid JSON syntax!', 'success');
        } catch (e) {
            showToast(`❌ Invalid JSON: ${e.message}`, 'error');
        }
        return;
    }
    
    // Server-side validation for other configs
    try {
        const result = await fetchAPI(`/api/docker/config/${currentDockerConfig}/validate`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ content })
        });
        
        if (result.valid) {
            showToast('✅ Configuration is valid!', 'success');
        } else {
            showToast(`❌ Invalid: ${result.error}`, 'error');
        }
    } catch (error) {
        showToast(`⚠️ Could not validate: ${error.message}`, 'warning');
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
// STACK LOGS VIEWER
// =============================================================================

let currentLogSource = 'all';
let logAutoRefreshInterval = null;
let originalLogContent = '';

const logSourceTitles = {
    'all': '📊 All Stack Logs',
    'dragonite': '🐉 Dragonite Logs',
    'golbat': '🦇 Golbat Logs',
    'rotom': '📱 Rotom Logs',
    'reactmap': '🗺️ ReactMap Logs',
    'koji': '📍 Koji Logs',
    'xilriws': '🔐 Xilriws Logs',
    'database': '🗄️ Database Logs',
    'grafana': '📊 Grafana Logs',
    'victoriametrics': '📈 VictoriaMetrics Logs',
    'fletchling': '🪺 Fletchling Logs',
    'poracle': '🔔 Poracle Logs',
    'shellder': '🐚 Shellder Logs',
    'custom': '⚙️ Custom Search'
};

// Switch log source
function switchLogSource(source) {
    currentLogSource = source;
    
    // Update tab active state
    document.querySelectorAll('.log-tab').forEach(tab => {
        tab.classList.toggle('active', tab.dataset.source === source);
    });
    
    // Update title
    const titleEl = document.getElementById('logSourceTitle');
    if (titleEl) {
        titleEl.textContent = logSourceTitles[source] || `📊 ${source} Logs`;
    }
    
    // Show/hide custom panel
    const customPanel = document.getElementById('customLogPanel');
    if (customPanel) {
        customPanel.style.display = source === 'custom' ? 'block' : 'none';
    }
    
    // Load logs (except for custom which requires user to click Search)
    if (source !== 'custom') {
        loadStackLogs();
    } else {
        // Update preset dropdown when switching to custom
        updatePresetDropdown();
        
        // Start the current time display
        startCurrentTimeDisplay();
        
        // Set default time range to last hour
        setTimePreset('1h');
        
        const logEl = document.getElementById('logContent');
        if (logEl) {
            logEl.textContent = 'Configure your search options above and click "Search Logs"';
        }
    }
}

// Load stack logs based on current source
async function loadStackLogs() {
    const lines = document.getElementById('logLines')?.value || 100;
    const logEl = document.getElementById('logContent');
    
    if (!logEl) return;
    
    logEl.textContent = 'Loading logs...';
    
    try {
        let endpoint;
        if (currentLogSource === 'all') {
            endpoint = `/api/logs/stack?lines=${lines}`;
        } else if (currentLogSource === 'shellder') {
            endpoint = `/api/logs/shellder?lines=${lines}`;
        } else {
            endpoint = `/api/logs/docker/${currentLogSource}?lines=${lines}`;
        }
        
        const result = await fetchAPI(endpoint);
        
        if (result.logs) {
            originalLogContent = result.logs;
            logEl.textContent = result.logs;
            
            // Update line count
            const lineCount = result.logs.split('\n').length;
            const countEl = document.getElementById('logLineCount');
            if (countEl) countEl.textContent = `${lineCount} lines`;
        } else if (result.error) {
            logEl.textContent = `Error: ${result.error}`;
        } else {
            logEl.textContent = 'No logs available';
        }
        
        // Update last refresh time
        const lastUpdateEl = document.getElementById('logLastUpdate');
        if (lastUpdateEl) {
            lastUpdateEl.textContent = `Updated: ${new Date().toLocaleTimeString()}`;
        }
        
        // Apply filter if set
        filterLogs();
        
        // Scroll to bottom
        logEl.scrollTop = logEl.scrollHeight;
        
    } catch (error) {
        logEl.textContent = `Failed to load logs: ${error.message}`;
    }
}

// Filter logs display
function filterLogs() {
    const filterText = document.getElementById('logFilter')?.value?.toLowerCase() || '';
    const logEl = document.getElementById('logContent');
    
    if (!filterText || !originalLogContent) {
        if (logEl && originalLogContent) logEl.textContent = originalLogContent;
        return;
    }
    
    const lines = originalLogContent.split('\n');
    const filtered = lines.filter(line => line.toLowerCase().includes(filterText));
    
    if (logEl) {
        logEl.textContent = filtered.length > 0 ? filtered.join('\n') : 'No matching logs found';
        
        const countEl = document.getElementById('logLineCount');
        if (countEl) countEl.textContent = `${filtered.length} lines (filtered)`;
    }
}

// Toggle auto-refresh
function toggleLogAutoRefresh() {
    const checkbox = document.getElementById('logAutoRefresh');
    
    if (checkbox?.checked) {
        logAutoRefreshInterval = setInterval(loadStackLogs, 5000);
        showToast('Auto-refresh enabled (5s)', 'info');
    } else {
        if (logAutoRefreshInterval) {
            clearInterval(logAutoRefreshInterval);
            logAutoRefreshInterval = null;
        }
        showToast('Auto-refresh disabled', 'info');
    }
}

// Download logs
function downloadLogs() {
    const logEl = document.getElementById('logContent');
    if (!logEl || !logEl.textContent) {
        showToast('No logs to download', 'warning');
        return;
    }
    
    const blob = new Blob([logEl.textContent], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `${currentLogSource}-logs-${new Date().toISOString().slice(0,10)}.txt`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    
    showToast('Logs downloaded', 'success');
}

// Clear log display
function clearLogDisplay() {
    const logEl = document.getElementById('logContent');
    if (logEl) {
        logEl.textContent = '';
        originalLogContent = '';
    }
    const countEl = document.getElementById('logLineCount');
    if (countEl) countEl.textContent = '0 lines';
}

// Toggle log cards visibility
function toggleLogCards() {
    const container = document.getElementById('logCardsContainer');
    const icon = document.getElementById('logCardsToggleIcon');
    
    if (container) {
        const isHidden = container.style.display === 'none';
        container.style.display = isHidden ? 'grid' : 'none';
        if (icon) icon.textContent = isHidden ? '▲' : '▼';
        
        if (isHidden) {
            loadContainerLogStatus();
        }
    }
}

// Load container status for log cards
async function loadContainerLogStatus() {
    try {
        const data = await fetchAPI('/api/containers');
        
        const containers = ['dragonite', 'golbat', 'rotom', 'reactmap', 'koji', 'xilriws', 'database', 'grafana'];
        
        containers.forEach(name => {
            const statusEl = document.getElementById(`${name}-log-status`);
            if (!statusEl) return;
            
            const container = data.containers?.find(c => c.name?.toLowerCase().includes(name));
            if (container) {
                const isRunning = container.state === 'running';
                statusEl.textContent = isRunning ? '● Running' : '○ Stopped';
                statusEl.className = `log-card-status ${isRunning ? 'running' : 'stopped'}`;
            } else {
                statusEl.textContent = '○ Not found';
                statusEl.className = 'log-card-status stopped';
            }
        });
    } catch (e) {
        console.error('Failed to load container status:', e);
    }
}

// =============================================================================
// CUSTOM LOG SEARCH
// =============================================================================

// Show/hide custom panel based on source
function updateCustomPanel() {
    const customPanel = document.getElementById('customLogPanel');
    if (customPanel) {
        customPanel.style.display = currentLogSource === 'custom' ? 'block' : 'none';
    }
}

// Get user's timezone offset in hours
function getUserTimezoneOffset() {
    return -new Date().getTimezoneOffset() / 60;
}

// Get user's timezone name
function getUserTimezoneName() {
    try {
        return Intl.DateTimeFormat().resolvedOptions().timeZone;
    } catch (e) {
        const offset = getUserTimezoneOffset();
        const sign = offset >= 0 ? '+' : '';
        return `UTC${sign}${offset}`;
    }
}

// Get timezone abbreviation (EST, PST, etc.)
function getTimezoneAbbr() {
    const date = new Date();
    const match = date.toLocaleTimeString('en-US', { timeZoneName: 'short' }).match(/[A-Z]{2,5}$/);
    return match ? match[0] : `UTC${getUserTimezoneOffset() >= 0 ? '+' : ''}${getUserTimezoneOffset()}`;
}

// Update the current time display
function updateCurrentTimeDisplay() {
    const now = new Date();
    const timeEl = document.getElementById('currentLocalTime');
    const tzEl = document.getElementById('userTimezone');
    const tzInfoEl = document.getElementById('timezoneInfo');
    
    if (timeEl) {
        timeEl.textContent = now.toLocaleTimeString();
    }
    
    if (tzEl) {
        tzEl.textContent = getTimezoneAbbr();
    }
    
    if (tzInfoEl) {
        const offset = getUserTimezoneOffset();
        const sign = offset >= 0 ? '+' : '';
        tzInfoEl.textContent = `(${getUserTimezoneName()}, UTC${sign}${offset})`;
    }
}

// Start updating the current time display
let currentTimeInterval = null;
function startCurrentTimeDisplay() {
    updateCurrentTimeDisplay();
    if (currentTimeInterval) clearInterval(currentTimeInterval);
    currentTimeInterval = setInterval(updateCurrentTimeDisplay, 1000);
}

// Format date for datetime-local input in LOCAL time (not UTC!)
function formatDateTimeLocal(date) {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    const hours = String(date.getHours()).padStart(2, '0');
    const minutes = String(date.getMinutes()).padStart(2, '0');
    return `${year}-${month}-${day}T${hours}:${minutes}`;
}

// Convert local datetime-local input value to UTC for log comparison
function localInputToUTC(localDateTimeStr) {
    if (!localDateTimeStr) return null;
    // datetime-local gives us local time, convert to Date object
    const localDate = new Date(localDateTimeStr);
    return localDate;
}

// Convert UTC timestamp from logs to local time for display
function utcToLocal(utcDateStr) {
    const utcDate = new Date(utcDateStr);
    return utcDate.toLocaleString();
}

// Set time preset - uses LOCAL time
function setTimePreset(preset) {
    const now = new Date();
    let from = new Date();
    
    switch (preset) {
        case '15m': from.setMinutes(now.getMinutes() - 15); break;
        case '1h': from.setHours(now.getHours() - 1); break;
        case '6h': from.setHours(now.getHours() - 6); break;
        case '24h': from.setDate(now.getDate() - 1); break;
        case '7d': from.setDate(now.getDate() - 7); break;
        case 'now': 
            from = new Date(now.getTime() - 60000); // 1 minute ago
            break;
    }
    
    // Format in LOCAL time for the input
    document.getElementById('logTimeFrom').value = formatDateTimeLocal(from);
    document.getElementById('logTimeTo').value = formatDateTimeLocal(now);
}

// Load custom filtered logs
async function loadCustomLogs() {
    const logEl = document.getElementById('logContent');
    if (!logEl) return;
    
    logEl.textContent = 'Loading custom logs...';
    
    // Get selected containers
    const selectedContainers = [];
    document.querySelectorAll('#customLogPanel .container-checkboxes input:checked').forEach(cb => {
        selectedContainers.push(cb.value);
    });
    
    if (selectedContainers.length === 0) {
        logEl.textContent = 'Please select at least one container';
        return;
    }
    
    // Get time range (user inputs in LOCAL time)
    const timeFromInput = document.getElementById('logTimeFrom')?.value;
    const timeToInput = document.getElementById('logTimeTo')?.value;
    
    // Convert local input times to Date objects for comparison
    // datetime-local values are interpreted as local time by the browser
    const timeFromLocal = timeFromInput ? new Date(timeFromInput) : null;
    const timeToLocal = timeToInput ? new Date(timeToInput) : null;
    
    // Get search filters
    const searchText = document.getElementById('logSearchText')?.value?.trim() || '';
    const searchRegex = document.getElementById('logSearchRegex')?.value?.trim() || '';
    const caseSensitive = document.getElementById('logCaseSensitive')?.checked || false;
    
    // Get exclude filters
    const excludeDebug = document.getElementById('excludeDebug')?.checked || false;
    const excludeInfo = document.getElementById('excludeInfo')?.checked || false;
    const excludeHeartbeat = document.getElementById('excludeHeartbeat')?.checked || false;
    const excludeHealth = document.getElementById('excludeHealth')?.checked || false;
    const customExcludes = document.getElementById('customExcludePatterns')?.value?.trim() || '';
    
    // Get level filters
    const levelFilters = [];
    document.querySelectorAll('#customLogPanel .level-filters input:checked').forEach(cb => {
        levelFilters.push(cb.value);
    });
    
    const lines = document.getElementById('logLines')?.value || 500;
    
    try {
        // Fetch logs from each selected container
        let combinedLogs = [];
        
        for (const container of selectedContainers) {
            const endpoint = `/api/logs/docker/${container}?lines=${lines}`;
            const result = await fetchAPI(endpoint);
            
            if (result.logs) {
                // Parse log lines and add container prefix
                const containerLogs = result.logs.split('\n').map(line => {
                    if (line.trim()) {
                        const timestamp = extractTimestamp(line);
                        // Parse UTC timestamp from log and convert to Date object
                        const timestampDate = timestamp ? parseLogTimestamp(timestamp) : null;
                        return { container, line, timestamp, timestampDate };
                    }
                    return null;
                }).filter(Boolean);
                
                combinedLogs = combinedLogs.concat(containerLogs);
            }
        }
        
        // Sort by timestamp
        combinedLogs.sort((a, b) => {
            if (a.timestampDate && b.timestampDate) {
                return a.timestampDate - b.timestampDate;
            }
            return 0;
        });
        
        // Apply time filter - compare UTC log times with user's local input times
        // The comparison works because both are Date objects (JavaScript handles timezone internally)
        if (timeFromLocal || timeToLocal) {
            combinedLogs = combinedLogs.filter(log => {
                if (!log.timestampDate) return true; // Keep logs without timestamps
                // Date objects are compared in absolute time (UTC internally)
                if (timeFromLocal && log.timestampDate < timeFromLocal) return false;
                if (timeToLocal && log.timestampDate > timeToLocal) return false;
                return true;
            });
        }
        
        // Apply text/regex search
        if (searchText || searchRegex) {
            const searchLower = searchText.toLowerCase();
            let regex = null;
            
            if (searchRegex) {
                try {
                    regex = new RegExp(searchRegex, caseSensitive ? '' : 'i');
                } catch (e) {
                    showToast('Invalid regex pattern', 'error');
                }
            }
            
            combinedLogs = combinedLogs.filter(log => {
                const line = caseSensitive ? log.line : log.line.toLowerCase();
                const text = caseSensitive ? searchText : searchLower;
                
                if (searchText && !line.includes(text)) return false;
                if (regex && !regex.test(log.line)) return false;
                return true;
            });
        }
        
        // Apply exclusion filters
        combinedLogs = combinedLogs.filter(log => {
            const lineLower = log.line.toLowerCase();
            
            if (excludeDebug && lineLower.includes('debug')) return false;
            if (excludeInfo && (lineLower.includes('[info]') || lineLower.includes('| i |'))) return false;
            if (excludeHeartbeat && (lineLower.includes('heartbeat') || lineLower.includes('ping'))) return false;
            if (excludeHealth && (lineLower.includes('health') || lineLower.includes('GET /health'))) return false;
            
            // Custom exclude patterns
            if (customExcludes) {
                const patterns = customExcludes.split('\n').filter(p => p.trim());
                for (const pattern of patterns) {
                    if (lineLower.includes(pattern.toLowerCase())) return false;
                }
            }
            
            return true;
        });
        
        // Apply level filters
        if (levelFilters.length < 4) { // Not all levels selected
            combinedLogs = combinedLogs.filter(log => {
                const lineLower = log.line.toLowerCase();
                
                const isError = lineLower.includes('error') || lineLower.includes('| e |') || lineLower.includes('[error]');
                const isWarn = lineLower.includes('warn') || lineLower.includes('| w |') || lineLower.includes('[warn]');
                const isInfo = lineLower.includes('info') || lineLower.includes('| i |') || lineLower.includes('[info]');
                const isDebug = lineLower.includes('debug') || lineLower.includes('| d |') || lineLower.includes('[debug]');
                
                if (isError && levelFilters.includes('error')) return true;
                if (isWarn && levelFilters.includes('warn')) return true;
                if (isInfo && levelFilters.includes('info')) return true;
                if (isDebug && levelFilters.includes('debug')) return true;
                
                // If no level detected, include by default
                if (!isError && !isWarn && !isInfo && !isDebug) return true;
                
                return false;
            });
        }
        
        // Format output with container labels and converted timestamps
        const formattedLogs = combinedLogs.map(log => {
            const containerLabel = `[${log.container.toUpperCase().padEnd(10)}]`;
            const convertedLine = convertLogTimestamp(log.line);
            return `${containerLabel} ${convertedLine}`;
        }).join('\n');
        
        originalLogContent = formattedLogs;
        logEl.textContent = formattedLogs || 'No logs match your filters';
        
        // Update stats
        const countEl = document.getElementById('logLineCount');
        if (countEl) countEl.textContent = `${combinedLogs.length} lines`;
        
        const lastUpdateEl = document.getElementById('logLastUpdate');
        if (lastUpdateEl) lastUpdateEl.textContent = `Updated: ${new Date().toLocaleTimeString()}`;
        
        logEl.scrollTop = logEl.scrollHeight;
        
    } catch (e) {
        logEl.textContent = `Error loading logs: ${e.message}`;
    }
}

// Server timezone offset (fetched from /api/status)
// Default to 0 (UTC) until fetched
let serverTimezoneOffsetHours = 0;
let serverTimezoneName = 'UTC';

// Fetch and cache server timezone from /api/status
async function fetchServerTimezone() {
    try {
        const response = await fetch('/api/status');
        const data = await response.json();
        if (data.server_timezone) {
            serverTimezoneOffsetHours = data.server_timezone.offset_hours || 0;
            serverTimezoneName = data.server_timezone.name || 'UTC';
            console.log(`Server timezone: ${serverTimezoneName} (UTC${serverTimezoneOffsetHours >= 0 ? '+' : ''}${serverTimezoneOffsetHours})`);
        }
    } catch (e) {
        console.warn('Could not fetch server timezone, defaulting to UTC:', e);
    }
}

// Extract timestamp from log line
function extractTimestamp(line) {
    // Try various timestamp formats in order of specificity
    const patterns = [
        // ISO format with Z (UTC): 2025-12-05T15:08:06.863506872Z
        /(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)/,
        // ISO format with explicit offset: 2025-12-06T01:14:36.682563504-05:00
        /(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?[+-]\d{2}:\d{2})/,
        // ISO format without timezone (will need server TZ): 2025-12-05T15:08:06
        /(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?)/,
        // Apache CLF format: [06/Dec/2025:06:14:48 +0000]
        /\[(\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4})\]/,
        // Space-separated format (server local): 2025-12-05 15:08:06
        /(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/,
        // Time only (server local, no date): 15:08:06.86
        /^\[?(\d{2}:\d{2}:\d{2}(?:\.\d+)?)\]?\s*\|/
    ];
    
    for (const pattern of patterns) {
        const match = line.match(pattern);
        if (match) {
            return match[1];
        }
    }
    
    return null;
}

// Parse log timestamp string to Date object
// Docker containers default to UTC unless TZ is explicitly configured
function parseLogTimestamp(timestampStr) {
    if (!timestampStr) return null;
    
    try {
        // 1. ISO format with Z suffix (UTC) - koji, rotom, victoriametrics, vmagent
        if (timestampStr.endsWith('Z')) {
            const dateStr = timestampStr.replace(/(\.\d{3})\d*Z$/, '$1Z');
            return new Date(dateStr);
        }
        
        // 2. ISO format with explicit offset (e.g., -05:00) - grafana
        if (/[+-]\d{2}:\d{2}$/.test(timestampStr)) {
            // Truncate excessive fractional seconds for JS Date compatibility
            const dateStr = timestampStr.replace(/(\.\d{3})\d*([+-])/, '$1$2');
            return new Date(dateStr);
        }
        
        // 3. Apache CLF format: 06/Dec/2025:06:14:48 +0000 - pma
        const clfMatch = timestampStr.match(/(\d{2})\/(\w{3})\/(\d{4}):(\d{2}):(\d{2}):(\d{2}) ([+-]\d{4})/);
        if (clfMatch) {
            const months = { Jan: 0, Feb: 1, Mar: 2, Apr: 3, May: 4, Jun: 5, Jul: 6, Aug: 7, Sep: 8, Oct: 9, Nov: 10, Dec: 11 };
            const [, day, mon, year, hour, min, sec, tz] = clfMatch;
            const tzHours = parseInt(tz.slice(0, 3), 10);
            const tzMins = parseInt(tz.slice(0, 1) + tz.slice(3), 10);
            const date = new Date(Date.UTC(
                parseInt(year), months[mon], parseInt(day),
                parseInt(hour) - tzHours, parseInt(min) - tzMins, parseInt(sec)
            ));
            return date;
        }
        
        // 4. ISO format without timezone - Docker containers use UTC by default
        if (timestampStr.includes('T')) {
            const dateStr = timestampStr.replace(/(\.\d{3})\d*$/, '$1');
            const parts = dateStr.split(/[T:.-]/);
            // Treat as UTC (Docker default)
            const date = new Date(Date.UTC(
                parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]),
                parseInt(parts[3]),
                parseInt(parts[4]),
                parseInt(parts[5] || 0)
            ));
            return date;
        }
        
        // 5. Space-separated format: 2025-12-05 15:08:06 - dragonite, golbat, admin, database, reactmap
        // Docker containers use UTC by default
        if (timestampStr.includes(' ') && timestampStr.includes('-')) {
            const [datePart, timePart] = timestampStr.split(' ');
            const [year, month, day] = datePart.split('-').map(Number);
            const [hour, minute, second] = timePart.split(':').map(s => parseFloat(s));
            // Treat as UTC (Docker default)
            const date = new Date(Date.UTC(
                year, month - 1, day,
                Math.floor(hour),
                Math.floor(minute),
                Math.floor(second || 0)
            ));
            return date;
        }
        
        // 6. Time only (no date): 05:43:39.17 - xilriws uses server local time
        if (/^\d{2}:\d{2}:\d{2}/.test(timestampStr)) {
            const now = new Date();
            const [hours, minutes, seconds] = timestampStr.split(':').map(s => parseFloat(s));
            // Xilriws outputs in server local time, convert to UTC
            const date = new Date(Date.UTC(
                now.getUTCFullYear(),
                now.getUTCMonth(),
                now.getUTCDate(),
                Math.floor(hours) - serverTimezoneOffsetHours,
                Math.floor(minutes),
                Math.floor(seconds || 0)
            ));
            return date;
        }
        
        // Fallback: try native parsing
        return new Date(timestampStr);
        
    } catch (e) {
        console.error('Failed to parse timestamp:', timestampStr, e);
        return null;
    }
}

// Convert log timestamp to browser local time for display
function convertLogTimestamp(line) {
    // Find timestamp in various formats and convert to local time
    const patterns = [
        // ISO format with Z (UTC): 2025-12-05T15:08:06.863506872Z
        { regex: /(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)/, type: 'utc' },
        // ISO format with explicit offset: 2025-12-06T01:14:36.682563504-05:00
        { regex: /(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?[+-]\d{2}:\d{2})/, type: 'offset' },
        // Apache CLF format: [06/Dec/2025:06:14:48 +0000]
        { regex: /\[(\d{2}\/\w{3}\/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4})\]/, type: 'clf' },
        // Space-separated format (server local): 2025-12-05 15:08:06
        { regex: /(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/, type: 'server_local' },
        // ISO format without Z (server local): 2025-12-05T15:08:06
        { regex: /(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?)/, type: 'server_local' },
        // Time only (server local): 15:08:06.86
        { regex: /^(\[?)(\d{2}:\d{2}:\d{2}(?:\.\d+)?)(\]?\s*\|)/, type: 'time_only' }
    ];
    
    for (const pattern of patterns) {
        const match = line.match(pattern.regex);
        if (match) {
            try {
                let date;
                const timestampStr = match[1] || match[2]; // Handle time_only group differently
                
                switch (pattern.type) {
                    case 'utc':
                        date = new Date(timestampStr.replace(/(\.\d{3})\d*Z$/, '$1Z'));
                        break;
                    case 'offset':
                        date = new Date(timestampStr.replace(/(\.\d{3})\d*([+-])/, '$1$2'));
                        break;
                    case 'clf':
                        date = parseLogTimestamp(timestampStr);
                        break;
                    case 'server_local':
                        date = parseLogTimestamp(timestampStr);
                        break;
                    case 'time_only':
                        // For time-only, prepend today's date
                        date = parseLogTimestamp(match[2]);
                        if (date) {
                            const localTime = date.toLocaleTimeString(undefined, {
                                hour: '2-digit',
                                minute: '2-digit',
                                second: '2-digit',
                                hour12: true
                            });
                            return line.replace(match[0], `${match[1]}[${localTime}]${match[3]}`);
                        }
                        return line;
                    default:
                        continue;
                }
                
                if (date && !isNaN(date.getTime())) {
                    // Format as local time with timezone abbreviation
                    const localTime = date.toLocaleString(undefined, {
                        year: 'numeric',
                        month: '2-digit',
                        day: '2-digit',
                        hour: '2-digit',
                        minute: '2-digit',
                        second: '2-digit',
                        hour12: true
                    });
                    
                    return line.replace(match[0], `[${localTime}]`);
                }
            } catch (e) {
                // Keep original if conversion fails
                console.warn('Timestamp conversion failed:', e);
            }
        }
    }
    
    return line;
}

// Reset custom filters
function resetCustomFilters() {
    // Reset containers to default
    document.querySelectorAll('#customLogPanel .container-checkboxes input').forEach((cb, i) => {
        cb.checked = i < 3; // First 3 checked by default
    });
    
    // Reset time
    document.getElementById('logTimeFrom').value = '';
    document.getElementById('logTimeTo').value = '';
    
    // Reset search
    document.getElementById('logSearchText').value = '';
    document.getElementById('logSearchRegex').value = '';
    document.getElementById('logCaseSensitive').checked = false;
    
    // Reset excludes
    document.getElementById('excludeDebug').checked = false;
    document.getElementById('excludeInfo').checked = false;
    document.getElementById('excludeHeartbeat').checked = false;
    document.getElementById('excludeHealth').checked = false;
    document.getElementById('customExcludePatterns').value = '';
    
    // Reset levels
    document.querySelectorAll('#customLogPanel .level-filters input').forEach(cb => {
        cb.checked = true;
    });
    
    showToast('Filters reset', 'info');
}

// Save log preset (to localStorage)
function saveLogPreset() {
    const name = prompt('Enter preset name:');
    if (!name) return;
    
    const preset = {
        containers: [],
        timeRange: {
            from: document.getElementById('logTimeFrom')?.value,
            to: document.getElementById('logTimeTo')?.value
        },
        search: {
            text: document.getElementById('logSearchText')?.value,
            regex: document.getElementById('logSearchRegex')?.value,
            caseSensitive: document.getElementById('logCaseSensitive')?.checked
        },
        exclude: {
            debug: document.getElementById('excludeDebug')?.checked,
            info: document.getElementById('excludeInfo')?.checked,
            heartbeat: document.getElementById('excludeHeartbeat')?.checked,
            health: document.getElementById('excludeHealth')?.checked,
            custom: document.getElementById('customExcludePatterns')?.value
        },
        levels: []
    };
    
    // Get selected containers
    document.querySelectorAll('#customLogPanel .container-checkboxes input:checked').forEach(cb => {
        preset.containers.push(cb.value);
    });
    
    // Get selected levels
    document.querySelectorAll('#customLogPanel .level-filters input:checked').forEach(cb => {
        preset.levels.push(cb.value);
    });
    
    // Save to localStorage
    const presets = JSON.parse(localStorage.getItem('shellderLogPresets') || '{}');
    presets[name] = preset;
    localStorage.setItem('shellderLogPresets', JSON.stringify(presets));
    
    showToast(`Preset "${name}" saved`, 'success');
    
    // Update preset dropdown
    updatePresetDropdown();
}

// Load log preset
function loadLogPreset(presetName) {
    if (!presetName) return;
    
    // Built-in presets
    const builtInPresets = {
        'errors': {
            containers: ['dragonite', 'golbat', 'rotom', 'xilriws', 'database'],
            levels: ['error', 'warn'],
            exclude: { debug: true, info: true, heartbeat: true, health: true }
        },
        'scanner': {
            containers: ['dragonite', 'golbat', 'rotom'],
            levels: ['error', 'warn', 'info'],
            search: { text: '' },
            exclude: { heartbeat: true, health: true }
        },
        'auth': {
            containers: ['xilriws', 'dragonite'],
            search: { regex: 'auth|login|token|cookie|error|fail' },
            levels: ['error', 'warn', 'info']
        }
    };
    
    // Check built-in first, then localStorage
    let preset = builtInPresets[presetName];
    if (!preset) {
        const savedPresets = JSON.parse(localStorage.getItem('shellderLogPresets') || '{}');
        preset = savedPresets[presetName];
    }
    
    if (!preset) {
        showToast('Preset not found', 'error');
        return;
    }
    
    // Apply preset
    if (preset.containers) {
        document.querySelectorAll('#customLogPanel .container-checkboxes input').forEach(cb => {
            cb.checked = preset.containers.includes(cb.value);
        });
    }
    
    if (preset.timeRange) {
        document.getElementById('logTimeFrom').value = preset.timeRange.from || '';
        document.getElementById('logTimeTo').value = preset.timeRange.to || '';
    }
    
    if (preset.search) {
        document.getElementById('logSearchText').value = preset.search.text || '';
        document.getElementById('logSearchRegex').value = preset.search.regex || '';
        document.getElementById('logCaseSensitive').checked = preset.search.caseSensitive || false;
    }
    
    if (preset.exclude) {
        document.getElementById('excludeDebug').checked = preset.exclude.debug || false;
        document.getElementById('excludeInfo').checked = preset.exclude.info || false;
        document.getElementById('excludeHeartbeat').checked = preset.exclude.heartbeat || false;
        document.getElementById('excludeHealth').checked = preset.exclude.health || false;
        document.getElementById('customExcludePatterns').value = preset.exclude.custom || '';
    }
    
    if (preset.levels) {
        document.querySelectorAll('#customLogPanel .level-filters input').forEach(cb => {
            cb.checked = preset.levels.includes(cb.value);
        });
    }
    
    showToast(`Preset "${presetName}" loaded`, 'success');
    
    // Reset dropdown
    document.getElementById('logPresets').value = '';
}

// Update preset dropdown with saved presets
function updatePresetDropdown() {
    const dropdown = document.getElementById('logPresets');
    if (!dropdown) return;
    
    // Keep built-in options
    dropdown.innerHTML = `
        <option value="">Load Preset...</option>
        <option value="errors">Errors Only</option>
        <option value="scanner">Scanner Activity</option>
        <option value="auth">Auth Issues</option>
    `;
    
    // Add saved presets
    const savedPresets = JSON.parse(localStorage.getItem('shellderLogPresets') || '{}');
    const savedNames = Object.keys(savedPresets);
    
    if (savedNames.length > 0) {
        const optgroup = document.createElement('optgroup');
        optgroup.label = 'Saved Presets';
        
        savedNames.forEach(name => {
            const option = document.createElement('option');
            option.value = name;
            option.textContent = name;
            optgroup.appendChild(option);
        });
        
        dropdown.appendChild(optgroup);
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
    
    // Handle footer - can be string HTML or array of button configs
    const footerEl = document.getElementById('modalFooter');
    if (Array.isArray(footer)) {
        // Array of button configurations: [{text, class, onclick}]
        footerEl.innerHTML = '';
        footer.forEach(btn => {
            const button = document.createElement('button');
            button.textContent = btn.text;
            button.className = btn.class || 'btn';
            button.onclick = btn.onclick;
            footerEl.appendChild(button);
        });
    } else {
        footerEl.innerHTML = footer;
    }
    
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

// NOTE: updateXilriwsPage is defined earlier in the file (around line 1913)
// Do not duplicate it here - the earlier version uses the correct field names

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

// Current file being edited or selected
let selectedFilePath = null;

async function navigateToPath(path) {
    currentFilePath = path || '';
    
    // Update breadcrumb
    updateBreadcrumb(path);
    
    const container = document.getElementById('fileList');
    container.innerHTML = '<div class="loading">Loading...</div>';
    
    try {
        const data = await fetchAPI(`/api/files?path=${encodeURIComponent(path)}`);
        
        if (data.error) {
            container.innerHTML = `<div class="text-danger">${escapeHtml(data.error)}</div>`;
            return;
        }
        
        // Update file count
        const countEl = document.getElementById('fileCount');
        if (countEl) {
            countEl.textContent = `${data.files?.length || 0} items`;
        }
        
        if (!data.files || data.files.length === 0) {
            container.innerHTML = '<div class="text-muted" style="padding: 20px; text-align: center;">📂 Empty directory</div>';
            return;
        }
        
        container.innerHTML = data.files.map(f => {
            const icon = f.type === 'directory' ? '📁' : getFileIcon(f.name);
            const sizeStr = f.type === 'file' ? formatBytes(f.size) : '-';
            const fullPath = path ? `${path}/${f.name}` : f.name;
            const modifiedDate = f.modified ? new Date(f.modified).toLocaleString() : '-';
            // Escape for use in data attributes and onclick - use base64 to avoid all escaping issues
            const pathB64 = encodePathToB64(fullPath);
            const nameB64 = encodePathToB64(f.name);
            
            return `
                <div class="file-item ${f.type}" data-path="${escapeHtml(fullPath)}" data-type="${f.type}">
                    <span class="file-icon">${icon}</span>
                    <span class="file-name" onclick="handleFileClick('${pathB64}', '${f.type}')">${escapeHtml(f.name)}</span>
                    <span class="file-size">${sizeStr}</span>
                    <span class="file-modified">${modifiedDate}</span>
                    <div class="file-actions">
                        ${f.type === 'file' ? `
                            <button class="btn btn-xs" onclick="handleFileEdit('${pathB64}')" title="Edit">✏️</button>
                            <button class="btn btn-xs" onclick="handleFileDownload('${pathB64}')" title="Download">⬇️</button>
                        ` : ''}
                        <button class="btn btn-xs" onclick="handleFileInfo('${pathB64}')" title="Properties">ℹ️</button>
                        <button class="btn btn-xs" onclick="handleFileRename('${pathB64}', '${nameB64}')" title="Rename">✏️</button>
                        <button class="btn btn-xs btn-danger" onclick="handleFileDelete('${pathB64}', '${f.type}')" title="Delete">🗑️</button>
                    </div>
                </div>
            `;
        }).join('');
    } catch (error) {
        container.innerHTML = '<div class="text-danger">Failed to load files</div>';
        console.error('File list error:', error);
    }
}

function updateBreadcrumb(path) {
    const breadcrumb = document.getElementById('pathBreadcrumb');
    if (!breadcrumb) return;
    
    let html = '<span class="breadcrumb-item" onclick="navigateToPath(\'\')">Aegis-All-In-One</span>';
    
    if (path) {
        const parts = path.split('/').filter(p => p);
        let cumPath = '';
        
        for (const part of parts) {
            cumPath += (cumPath ? '/' : '') + part;
            html += `<span class="breadcrumb-separator">/</span>`;
            html += `<span class="breadcrumb-item" onclick="navigateToPath('${cumPath}')">${escapeHtml(part)}</span>`;
        }
    }
    
    breadcrumb.innerHTML = html;
}

function navigateUp() {
    const parts = currentFilePath.split('/').filter(p => p);
    parts.pop();
    navigateToPath(parts.join('/'));
}

function refreshFiles() {
    navigateToPath(currentFilePath);
}

// Base64 encode/decode helpers for file paths (handles Unicode properly)
function encodePathToB64(str) {
    try {
        // Use TextEncoder for proper Unicode support
        const encoder = new TextEncoder();
        const bytes = encoder.encode(str);
        let binary = '';
        for (let i = 0; i < bytes.length; i++) {
            binary += String.fromCharCode(bytes[i]);
        }
        return btoa(binary);
    } catch (e) {
        console.error('Failed to encode path:', str, e);
        return '';
    }
}

function decodeFilePath(b64) {
    try {
        // Decode base64 to binary string, then to UTF-8
        const binary = atob(b64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) {
            bytes[i] = binary.charCodeAt(i);
        }
        const decoder = new TextDecoder();
        return decoder.decode(bytes);
    } catch (e) {
        console.error('Failed to decode path:', b64, e);
        showToast('Failed to decode file path', 'error');
        return '';
    }
}

// Handler functions that decode base64 paths
function handleFileClick(pathB64, type) {
    console.log('handleFileClick:', pathB64, type);
    const path = decodeFilePath(pathB64);
    if (!path) return;
    
    if (type === 'directory') {
        navigateToPath(path);
    } else {
        editFile(path);
    }
}

function handleFileEdit(pathB64) {
    console.log('handleFileEdit:', pathB64);
    const path = decodeFilePath(pathB64);
    if (!path) return;
    editFile(path);
}

function handleFileDownload(pathB64) {
    console.log('handleFileDownload:', pathB64);
    const path = decodeFilePath(pathB64);
    if (!path) return;
    downloadFile(path);
}

function handleFileInfo(pathB64) {
    console.log('handleFileInfo:', pathB64);
    const path = decodeFilePath(pathB64);
    if (!path) return;
    showFileInfo(path);
}

function handleFileRename(pathB64, nameB64) {
    console.log('handleFileRename:', pathB64, nameB64);
    const path = decodeFilePath(pathB64);
    const name = decodeFilePath(nameB64);
    if (!path || !name) return;
    showRenameModal(path, name);
}

function handleFileDelete(pathB64, type) {
    console.log('handleFileDelete:', pathB64, type);
    const path = decodeFilePath(pathB64);
    if (!path) return;
    deleteFile(path, type);
}

// Edit file in text editor
async function editFile(path) {
    console.log('editFile called with path:', path);
    
    if (!path) {
        showToast('No file path provided', 'error');
        return;
    }
    
    selectedFilePath = path;
    
    try {
        console.log('Fetching file content...');
        const data = await fetchAPI(`/api/file?path=${encodeURIComponent(path)}`);
        console.log('API response:', data);
        
        if (data.error) {
            showToast(data.error, 'error');
            return;
        }
        
        const modal = document.getElementById('fileEditorModal');
        const fileNameEl = document.getElementById('editorFileName');
        const contentEl = document.getElementById('fileEditorContent');
        const infoEl = document.getElementById('editorFileInfo');
        
        if (!modal || !fileNameEl || !contentEl || !infoEl) {
            console.error('Missing modal elements:', { modal, fileNameEl, contentEl, infoEl });
            showToast('Editor modal elements not found', 'error');
            return;
        }
        
        fileNameEl.textContent = `📝 ${path.split('/').pop()}`;
        contentEl.value = data.content || '';
        infoEl.textContent = `Path: ${path}`;
        modal.classList.add('active');
        console.log('Editor modal opened');
    } catch (e) {
        console.error('editFile error:', e);
        showToast('Failed to load file: ' + e.message, 'error');
    }
}

function closeFileEditor() {
    document.getElementById('fileEditorModal').classList.remove('active');
    selectedFilePath = null;
}

async function saveFileContent() {
    if (!selectedFilePath) return;
    
    const content = document.getElementById('fileEditorContent').value;
    
    try {
        const result = await fetchAPI('/api/files/save', {
            method: 'POST',
            body: JSON.stringify({ path: selectedFilePath, content })
        });
        
        if (result.success) {
            showToast('File saved successfully', 'success');
            closeFileEditor();
        } else {
            showToast(result.error || 'Failed to save file', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Create new file
function showCreateFileModal() {
    document.getElementById('newFileName').value = '';
    document.getElementById('createFileModal').classList.add('active');
    document.getElementById('newFileName').focus();
}

function closeCreateFileModal() {
    document.getElementById('createFileModal').classList.remove('active');
}

async function createNewFile() {
    const filename = document.getElementById('newFileName').value.trim();
    if (!filename) {
        showToast('Please enter a filename', 'warning');
        return;
    }
    
    try {
        const result = await fetchAPI('/api/files/create', {
            method: 'POST',
            body: JSON.stringify({ path: currentFilePath, filename })
        });
        
        if (result.success) {
            showToast(result.message, 'success');
            closeCreateFileModal();
            refreshFiles();
            // Open for editing
            const fullPath = currentFilePath ? `${currentFilePath}/${filename}` : filename;
            editFile(fullPath);
        } else {
            showToast(result.error || 'Failed to create file', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Create new folder
function showCreateFolderModal() {
    document.getElementById('newFolderName').value = '';
    document.getElementById('createFolderModal').classList.add('active');
    document.getElementById('newFolderName').focus();
}

function closeCreateFolderModal() {
    document.getElementById('createFolderModal').classList.remove('active');
}

async function createNewFolder() {
    const dirname = document.getElementById('newFolderName').value.trim();
    if (!dirname) {
        showToast('Please enter a folder name', 'warning');
        return;
    }
    
    try {
        const result = await fetchAPI('/api/files/mkdir', {
            method: 'POST',
            body: JSON.stringify({ path: currentFilePath, dirname })
        });
        
        if (result.success) {
            showToast(result.message, 'success');
            closeCreateFolderModal();
            refreshFiles();
        } else {
            showToast(result.error || 'Failed to create folder', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Delete file/folder
async function deleteFile(path, type) {
    const name = path.split('/').pop();
    const typeLabel = type === 'directory' ? 'folder' : 'file';
    
    if (!confirm(`Are you sure you want to delete ${typeLabel} "${name}"?\n\nThis action cannot be undone.`)) {
        return;
    }
    
    try {
        const result = await fetchAPI('/api/files/delete', {
            method: 'POST',
            body: JSON.stringify({ path })
        });
        
        if (result.success) {
            showToast(result.message, 'success');
            refreshFiles();
        } else {
            showToast(result.error || 'Failed to delete', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Rename file/folder
function showRenameModal(path, currentName) {
    console.log('showRenameModal called:', path, currentName);
    
    if (!path || !currentName) {
        showToast('Missing path or name for rename', 'error');
        return;
    }
    
    selectedFilePath = path;
    
    const modal = document.getElementById('renameModal');
    const input = document.getElementById('renameInput');
    
    if (!modal || !input) {
        console.error('Rename modal elements not found:', { modal, input });
        showToast('Rename modal not found', 'error');
        return;
    }
    
    input.value = currentName;
    modal.classList.add('active');
    input.focus();
    input.select();
    console.log('Rename modal opened');
}

function closeRenameModal() {
    document.getElementById('renameModal').classList.remove('active');
    selectedFilePath = null;
}

async function confirmRename() {
    if (!selectedFilePath) return;
    
    const newName = document.getElementById('renameInput').value.trim();
    if (!newName) {
        showToast('Please enter a new name', 'warning');
        return;
    }
    
    try {
        const result = await fetchAPI('/api/files/rename', {
            method: 'POST',
            body: JSON.stringify({ path: selectedFilePath, new_name: newName })
        });
        
        if (result.success) {
            showToast(result.message, 'success');
            closeRenameModal();
            refreshFiles();
        } else {
            showToast(result.error || 'Failed to rename', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// File info/properties
async function showFileInfo(path) {
    selectedFilePath = path;
    
    try {
        const data = await fetchAPI(`/api/files/info?path=${encodeURIComponent(path)}`);
        
        if (data.error) {
            showToast(data.error, 'error');
            return;
        }
        
        const content = document.getElementById('fileInfoContent');
        content.innerHTML = `
            <div class="file-info-row">
                <span class="file-info-label">Name</span>
                <span class="file-info-value">${escapeHtml(data.name)}</span>
            </div>
            <div class="file-info-row">
                <span class="file-info-label">Type</span>
                <span class="file-info-value">${data.type}</span>
            </div>
            <div class="file-info-row">
                <span class="file-info-label">Size</span>
                <span class="file-info-value">${formatBytes(data.size)}</span>
            </div>
            <div class="file-info-row">
                <span class="file-info-label">Owner</span>
                <span class="file-info-value">${data.owner}:${data.group}</span>
            </div>
            <div class="file-info-row">
                <span class="file-info-label">Permissions</span>
                <span class="file-info-value">${data.permissions} (${data.permissions_octal})</span>
            </div>
            <div class="file-info-row">
                <span class="file-info-label">Modified</span>
                <span class="file-info-value">${new Date(data.modified).toLocaleString()}</span>
            </div>
            <div class="file-info-row">
                <span class="file-info-label">Access</span>
                <span class="file-info-value">
                    ${data.readable ? '✅ Read' : '❌ Read'} 
                    ${data.writable ? '✅ Write' : '❌ Write'} 
                    ${data.executable ? '✅ Exec' : '❌ Exec'}
                </span>
            </div>
        `;
        
        document.getElementById('fileInfoPanel').style.display = 'block';
    } catch (e) {
        showToast('Failed to get file info: ' + e.message, 'error');
    }
}

function closeFileInfo() {
    document.getElementById('fileInfoPanel').style.display = 'none';
}

// Change ownership
function changeOwnership() {
    document.getElementById('chownInput').value = '';
    document.getElementById('chownRecursive').checked = false;
    document.getElementById('chownModal').classList.add('active');
}

function closeChownModal() {
    document.getElementById('chownModal').classList.remove('active');
}

async function applyChown() {
    if (!selectedFilePath) return;
    
    const owner = document.getElementById('chownInput').value.trim();
    const recursive = document.getElementById('chownRecursive').checked;
    
    try {
        const result = await fetchAPI('/api/files/chown', {
            method: 'POST',
            body: JSON.stringify({ path: selectedFilePath, owner, recursive })
        });
        
        if (result.success) {
            showToast(result.message, 'success');
            closeChownModal();
            showFileInfo(selectedFilePath); // Refresh info
        } else {
            showToast(result.error || 'Failed to change ownership', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Change permissions
function changePermissions() {
    // Parse current permissions and set checkboxes
    document.getElementById('chmod-owner-r').checked = true;
    document.getElementById('chmod-owner-w').checked = true;
    document.getElementById('chmod-owner-x').checked = true;
    document.getElementById('chmod-group-r').checked = true;
    document.getElementById('chmod-group-x').checked = true;
    document.getElementById('chmod-other-r').checked = true;
    document.getElementById('chmod-other-x').checked = true;
    document.getElementById('chmodRecursive').checked = false;
    
    updateChmodPreview();
    document.getElementById('chmodModal').classList.add('active');
    
    // Add event listeners to update preview
    document.querySelectorAll('#chmodModal input[type="checkbox"]').forEach(cb => {
        cb.onchange = updateChmodPreview;
    });
}

function updateChmodPreview() {
    let owner = 0, group = 0, other = 0;
    
    if (document.getElementById('chmod-owner-r').checked) owner += 4;
    if (document.getElementById('chmod-owner-w').checked) owner += 2;
    if (document.getElementById('chmod-owner-x').checked) owner += 1;
    
    if (document.getElementById('chmod-group-r').checked) group += 4;
    if (document.getElementById('chmod-group-w').checked) group += 2;
    if (document.getElementById('chmod-group-x').checked) group += 1;
    
    if (document.getElementById('chmod-other-r').checked) other += 4;
    if (document.getElementById('chmod-other-w').checked) other += 2;
    if (document.getElementById('chmod-other-x').checked) other += 1;
    
    document.getElementById('chmodPreview').textContent = `${owner}${group}${other}`;
}

function closeChmodModal() {
    document.getElementById('chmodModal').classList.remove('active');
}

async function applyChmod() {
    if (!selectedFilePath) return;
    
    const mode = document.getElementById('chmodPreview').textContent;
    const recursive = document.getElementById('chmodRecursive').checked;
    
    try {
        const result = await fetchAPI('/api/files/chmod', {
            method: 'POST',
            body: JSON.stringify({ path: selectedFilePath, mode, recursive })
        });
        
        if (result.success) {
            showToast(result.message, 'success');
            closeChmodModal();
            showFileInfo(selectedFilePath); // Refresh info
        } else {
            showToast(result.error || 'Failed to change permissions', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Download file
function downloadFile(path) {
    window.open(`/api/files/download?path=${encodeURIComponent(path)}`, '_blank');
}

// Upload file
function triggerFileUpload() {
    document.getElementById('fileUploadInput').click();
}

async function uploadFile() {
    const input = document.getElementById('fileUploadInput');
    const files = input.files;
    
    if (!files || files.length === 0) return;
    
    for (const file of files) {
        try {
            showToast(`Uploading ${file.name}...`, 'info');
            
            const formData = new FormData();
            formData.append('file', file);
            formData.append('path', currentFilePath);
            
            const response = await fetch('/api/files/upload', {
                method: 'POST',
                body: formData
            });
            
            const result = await response.json();
            
            if (result.success) {
                showToast(result.message, 'success');
            } else {
                showToast(result.error || 'Upload failed', 'error');
            }
        } catch (e) {
            showToast(`Failed to upload ${file.name}: ${e.message}`, 'error');
        }
    }
    
    // Clear input and refresh
    input.value = '';
    refreshFiles();
}

// Fix all ownership to current user
let pendingSudoAction = null;

async function fixAllOwnership(sudoPassword = null) {
    const pathDesc = currentFilePath ? `"${currentFilePath}"` : 'entire Aegis directory';
    
    // Only show confirm on first attempt (not when retrying with password)
    if (!sudoPassword) {
        if (!confirm(`Change ownership of ALL files in ${pathDesc} to your current user?\n\nThis will run: sudo chown -R user:user ${pathDesc}`)) {
            return;
        }
    }
    
    try {
        showToast('Fixing ownership... This may take a moment.', 'info');
        
        const payload = { path: currentFilePath };
        if (sudoPassword) {
            payload.sudo_password = sudoPassword;
        }
        
        const result = await fetchAPI('/api/files/chown-all', {
            method: 'POST',
            body: JSON.stringify(payload)
        });
        
        if (result.success) {
            showToast(result.message, 'success');
            refreshFiles();
        } else if (result.needs_password) {
            // Show password modal
            showSudoPasswordModal(result.target_user, currentFilePath || 'Aegis-All-In-One', 'fixAllOwnership');
        } else {
            showToast(result.error || 'Failed to fix ownership', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Sudo password modal functions
function showSudoPasswordModal(targetUser, targetPath, action) {
    document.getElementById('sudoTargetUser').textContent = targetUser || 'current user';
    document.getElementById('sudoTargetPath').textContent = targetPath || '/';
    document.getElementById('sudoPasswordInput').value = '';
    document.getElementById('sudoPasswordModal').classList.add('active');
    document.getElementById('sudoPasswordInput').focus();
    pendingSudoAction = action;
}

function closeSudoPasswordModal() {
    document.getElementById('sudoPasswordModal').classList.remove('active');
    document.getElementById('sudoPasswordInput').value = '';
    pendingSudoAction = null;
}

async function submitSudoPassword() {
    const password = document.getElementById('sudoPasswordInput').value;
    if (!password) {
        showToast('Please enter your password', 'error');
        return;
    }
    
    closeSudoPasswordModal();
    
    // Execute the pending action with password
    if (pendingSudoAction === 'fixAllOwnership') {
        await fixAllOwnership(password);
    }
    // Add more actions here as needed
}

// Load current user info
async function loadCurrentUser() {
    try {
        const data = await fetchAPI('/api/files/current-user');
        const display = document.getElementById('currentUserDisplay');
        if (display && data.username) {
            display.textContent = `👤 ${data.username}`;
            display.title = `UID: ${data.uid}, GID: ${data.gid}`;
        }
    } catch (e) {
        console.error('Failed to load current user:', e);
    }
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
        case 'containers':
            loadDockerHealth();
            loadContainerUpdates();
            loadDockerInstallStatus();
            loadDockerConfigs();
            break;
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
            loadSecurityData();  // Load security services
            updateSetupWizardStatus();  // Update setup wizard status
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
        case 'setup':
            loadSetupPage();
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
                                ${d.uuid || '-'}
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
        document.getElementById('logContextModal').classList.add('active');
        
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
    document.getElementById('logContextModal').classList.remove('active');
    currentCrashId = null;
}

async function showDeviceDetail(deviceName) {
    const modal = document.getElementById('deviceDetailModal');
    const content = document.getElementById('deviceDetailContent');
    
    modal.classList.add('active');
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
    document.getElementById('deviceDetailModal').classList.remove('active');
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
        
        document.getElementById('logContextModal').classList.add('active');
        
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
                            <span class="device-uuid">${d.uuid || '-'}</span>
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

// Service display info - clarify what each service is and if it has a UI
const SERVICE_INFO = {
    'reactmap': { name: 'ReactMap', desc: 'Map Frontend', hasUI: true, icon: '🗺️' },
    'admin': { name: 'Admin Panel', desc: 'Dragonite Web UI', hasUI: true, icon: '⚙️' },
    'rotom': { name: 'Rotom', desc: 'Device Manager', hasUI: true, icon: '📱' },
    'koji': { name: 'Koji', desc: 'Geofence Editor', hasUI: true, icon: '📍' },
    'grafana': { name: 'Grafana', desc: 'Monitoring Dashboard', hasUI: true, icon: '📊' },
    'shellder': { name: 'Shellder', desc: 'Control Panel', hasUI: true, icon: '🐚' },
    'phpmyadmin': { name: 'phpMyAdmin', desc: 'Database Admin', hasUI: true, icon: '🗄️' },
    'pma': { name: 'phpMyAdmin', desc: 'Database Admin', hasUI: true, icon: '🗄️' },
    // Backend-only services - no UI, shouldn't be proxied directly
    'dragonite': { name: 'Dragonite', desc: 'Backend API Only', hasUI: false, icon: '⚠️', warning: 'No web UI - use Admin Panel instead' },
    'golbat': { name: 'Golbat', desc: 'Backend API Only', hasUI: false, icon: '⚠️', warning: 'No web UI - data processor only' },
    'xilriws': { name: 'Xilriws', desc: 'Auth Proxy API', hasUI: false, icon: '⚠️', warning: 'No web UI - auth API only' },
};

function getSiteDisplayInfo(siteName) {
    // Extract service name from site config name (e.g., "aegis-reactmap" -> "reactmap", "map.example.com" -> check content)
    const lower = siteName.toLowerCase();
    
    for (const [key, info] of Object.entries(SERVICE_INFO)) {
        if (lower.includes(key)) {
            return { ...info, originalName: siteName };
        }
    }
    
    // Unknown service - assume it's a custom site
    return { name: siteName, desc: 'Custom Site', hasUI: true, icon: '🌐', originalName: siteName };
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
        
        // Render enabled sites with enhanced display
        if (enabledEl) {
            if (data.enabled && data.enabled.length > 0) {
                enabledEl.innerHTML = data.enabled.map(site => {
                    const info = getSiteDisplayInfo(site.name);
                    const warningHtml = info.warning ? `<span class="site-warning" title="${info.warning}">⚠️</span>` : '';
                    const descClass = info.hasUI ? '' : 'text-warning';
                    return `
                    <div class="site-item enabled ${info.hasUI ? '' : 'backend-only'}">
                        <span class="site-icon">${info.icon}</span>
                        <div class="site-info">
                            <span class="site-name">${site.name}</span>
                            <span class="site-desc ${descClass}">${info.desc} ${warningHtml}</span>
                        </div>
                        <div class="site-actions">
                            <button class="btn btn-sm" onclick="loadSiteConfig('${site.name}')" title="Edit">📝</button>
                            <button class="btn btn-sm btn-warning" onclick="disableSite('${site.name}')" title="Disable">⏸️</button>
                        </div>
                    </div>
                `}).join('');
            } else {
                enabledEl.innerHTML = '<div class="no-data">No sites enabled</div>';
            }
        }
        
        // Render available (disabled) sites with enhanced display
        if (availableEl) {
            const disabled = data.available?.filter(s => !s.enabled) || [];
            if (disabled.length > 0) {
                availableEl.innerHTML = disabled.map(site => {
                    const info = getSiteDisplayInfo(site.name);
                    const warningHtml = info.warning ? `<span class="site-warning" title="${info.warning}">⚠️</span>` : '';
                    const descClass = info.hasUI ? '' : 'text-warning';
                    return `
                    <div class="site-item disabled ${info.hasUI ? '' : 'backend-only'}">
                        <span class="site-icon">${info.icon}</span>
                        <div class="site-info">
                            <span class="site-name">${site.name}</span>
                            <span class="site-desc ${descClass}">${info.desc} ${warningHtml}</span>
                        </div>
                        <div class="site-actions">
                            <button class="btn btn-sm" onclick="loadSiteConfig('${site.name}')" title="Edit">📝</button>
                            <button class="btn btn-sm btn-success" onclick="enableSite('${site.name}')" title="Enable">▶️</button>
                        </div>
                    </div>
                `}).join('');
            } else {
                availableEl.innerHTML = '<div class="no-data">All sites are enabled</div>';
            }
        }
        
        // Populate selector with clarified names
        if (selectorEl) {
            const allSites = [...(data.enabled || []), ...(data.available || [])];
            const uniqueSites = [...new Set(allSites.map(s => s.name))];
            selectorEl.innerHTML = '<option value="">Select a site to edit...</option>' +
                uniqueSites.map(name => {
                    const info = getSiteDisplayInfo(name);
                    const warning = info.hasUI ? '' : ' ⚠️';
                    return `<option value="${name}">${name} (${info.desc})${warning}</option>`;
                }).join('');
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
// SECURITY SERVICES
// =============================================================================

// Load all security service statuses
// =============================================================================
// NGINX SETUP WIZARD
// =============================================================================

// Refresh security service status for setup wizard
async function refreshSecurityStatus() {
    showToast('Checking security services...', 'info');
    await updateSetupWizardStatus();
    await loadSecurityStatus();
    showToast('Status updated', 'success');
}

// Update setup wizard step statuses
async function updateSetupWizardStatus() {
    try {
        const data = await fetchAPI('/api/security/setup-status');
        
        const steps = ['nginx', 'certbot', 'fail2ban', 'ufw', 'sites'];
        steps.forEach(step => {
            const stepEl = document.getElementById(`step-${step}`);
            if (!stepEl) return;
            
            const statusEl = stepEl.querySelector('.step-status');
            const actionBtn = stepEl.querySelector('.step-action button');
            
            const status = data[step];
            if (status) {
                if (status.installed && status.running) {
                    statusEl.textContent = '✅';
                    statusEl.className = 'step-status success';
                    if (actionBtn) actionBtn.textContent = 'Installed ✓';
                    if (actionBtn) actionBtn.disabled = true;
                } else if (status.installed) {
                    statusEl.textContent = '⚠️';
                    statusEl.className = 'step-status warning';
                    if (actionBtn) actionBtn.textContent = 'Start';
                } else {
                    statusEl.textContent = '⏳';
                    statusEl.className = 'step-status';
                }
            }
        });
        
        // Check auth status separately
        try {
            const basicAuthData = await fetchAPI('/api/security/basicauth/users');
            const autheliaData = await fetchAPI('/api/security/authelia/status');
            updateAuthWizardStep(basicAuthData, autheliaData);
        } catch (e) {
            console.log('Could not load auth status:', e);
        }
        
    } catch (e) {
        console.error('Error updating wizard status:', e);
    }
}


// Install Nginx
async function installNginx() {
    if (!confirm('Install Nginx web server?\n\nThis will:\n- Install nginx package\n- Start the nginx service\n- Enable nginx to start on boot')) return;
    
    showSetupOutput('Installing Nginx...');
    try {
        const result = await fetchAPI('/api/security/install/nginx', { method: 'POST' });
        appendSetupOutput(result.output || result.message);
        if (result.success) {
            showToast('Nginx installed successfully', 'success');
            updateSetupWizardStatus();
            loadNginxStatus();
        } else {
            showToast('Nginx installation failed', 'error');
        }
    } catch (e) {
        appendSetupOutput('Error: ' + e.message);
        showToast('Error: ' + e.message, 'error');
    }
}

// Install Certbot
async function installCertbot() {
    if (!confirm('Install Certbot for SSL certificates?\n\nThis will:\n- Install certbot package\n- Enable auto-renewal timer')) return;
    
    showSetupOutput('Installing Certbot...');
    try {
        const result = await fetchAPI('/api/security/install/certbot', { method: 'POST' });
        appendSetupOutput(result.output || result.message);
        if (result.success) {
            showToast('Certbot installed successfully', 'success');
            updateSetupWizardStatus();
        } else {
            showToast('Certbot installation failed', 'error');
        }
    } catch (e) {
        appendSetupOutput('Error: ' + e.message);
        showToast('Error: ' + e.message, 'error');
    }
}

// Install Fail2Ban
async function installFail2ban() {
    if (!confirm('Install Fail2Ban for brute-force protection?\n\nThis will:\n- Install fail2ban package\n- Configure nginx jails\n- Start fail2ban service')) return;
    
    showSetupOutput('Installing Fail2Ban...');
    try {
        const result = await fetchAPI('/api/security/install/fail2ban', { method: 'POST' });
        appendSetupOutput(result.output || result.message);
        if (result.success) {
            showToast('Fail2Ban installed successfully', 'success');
            updateSetupWizardStatus();
            loadFail2banStatus();
        } else {
            showToast('Fail2Ban installation failed', 'error');
        }
    } catch (e) {
        appendSetupOutput('Error: ' + e.message);
        showToast('Error: ' + e.message, 'error');
    }
}

// Setup UFW Firewall
async function setupUfw() {
    if (!confirm('Setup UFW Firewall?\n\nThis will:\n- Install ufw if needed\n- Allow SSH (port 22)\n- Allow HTTP/HTTPS (80, 443)\n- Allow Aegis ports (5000-7272)\n- Enable UFW')) return;
    
    showSetupOutput('Setting up UFW Firewall...');
    try {
        const result = await fetchAPI('/api/security/install/ufw', { method: 'POST' });
        appendSetupOutput(result.output || result.message);
        if (result.success) {
            showToast('UFW configured successfully', 'success');
            updateSetupWizardStatus();
            loadUfwRules();
        } else {
            showToast('UFW setup failed', 'error');
        }
    } catch (e) {
        appendSetupOutput('Error: ' + e.message);
        showToast('Error: ' + e.message, 'error');
    }
}

// Show site setup modal
function showSiteSetupModal() {
    // Scroll to the Quick Setup section
    const quickSetup = document.querySelector('.nginx-setup-form');
    if (quickSetup) {
        quickSetup.scrollIntoView({ behavior: 'smooth', block: 'center' });
        quickSetup.style.boxShadow = '0 0 20px var(--accent-primary)';
        setTimeout(() => { quickSetup.style.boxShadow = ''; }, 2000);
    }
}

// ============================================
// Authentication Setup Functions
// ============================================

// Show authentication setup modal
async function showAuthSetupModal() {
    document.getElementById('authSetupModal').classList.add('active');
    
    // Hide both setup panels, show choice
    document.getElementById('basicAuthSetupPanel').style.display = 'none';
    document.getElementById('autheliaSetupPanel').style.display = 'none';
    document.querySelector('.auth-choice-section').style.display = 'block';
    
    // Load current status
    await loadAuthStatus();
}

// Close auth setup modal
function closeAuthSetupModal() {
    document.getElementById('authSetupModal').classList.remove('active');
}

// Load authentication status for both options
async function loadAuthStatus() {
    try {
        // Load Basic Auth status
        const basicAuthData = await fetchAPI('/api/security/basicauth/users');
        const basicAuthStatus = document.getElementById('basicAuthStatus');
        const hasBasicAuth = basicAuthData.users && basicAuthData.users.length > 0;
        
        if (hasBasicAuth) {
            basicAuthStatus.textContent = `${basicAuthData.users.length} user(s)`;
            basicAuthStatus.className = 'auth-status configured';
        } else {
            basicAuthStatus.textContent = 'Not Configured';
            basicAuthStatus.className = 'auth-status';
        }
        
        // Load Authelia status
        const autheliaData = await fetchAPI('/api/security/authelia/status');
        const autheliaStatus = document.getElementById('autheliaStatus');
        const hasAuthelia = autheliaData.installed;
        const autheliaRunning = autheliaData.running;
        
        if (hasAuthelia) {
            if (autheliaRunning) {
                autheliaStatus.textContent = 'Running';
                autheliaStatus.className = 'auth-status running';
            } else {
                autheliaStatus.textContent = 'Stopped';
                autheliaStatus.className = 'auth-status stopped';
            }
        } else {
            autheliaStatus.textContent = 'Not Installed';
            autheliaStatus.className = 'auth-status';
        }
        
        // Check for conflicts and update UI
        checkAuthConflict(hasBasicAuth, hasAuthelia, autheliaRunning);
        
        // Update button states based on conflicts
        updateAuthButtonStates(hasBasicAuth, hasAuthelia, autheliaRunning);
        
        // Update the wizard step status as well
        updateAuthWizardStep(basicAuthData, autheliaData);
        
    } catch (e) {
        console.error('Error loading auth status:', e);
    }
}

// Check for authentication conflicts
function checkAuthConflict(hasBasicAuth, hasAuthelia, autheliaRunning) {
    const warningBox = document.getElementById('authConflictWarning');
    const warningMessage = document.getElementById('authConflictMessage');
    
    if (!warningBox || !warningMessage) return;
    
    if (hasBasicAuth && hasAuthelia) {
        warningBox.style.display = 'block';
        if (autheliaRunning) {
            warningMessage.textContent = 'Both Basic Auth and Authelia are configured. Authelia is currently running. Please disable Basic Auth or stop Authelia to avoid conflicts.';
        } else {
            warningMessage.textContent = 'Both Basic Auth and Authelia are configured. Please disable one to avoid conflicts.';
        }
    } else {
        warningBox.style.display = 'none';
    }
}

// Update authentication button states based on conflicts
function updateAuthButtonStates(hasBasicAuth, hasAuthelia, autheliaRunning) {
    const basicAuthCard = document.getElementById('basicAuthCard');
    const autheliaCard = document.getElementById('autheliaCard');
    const basicAuthBtn = basicAuthCard?.querySelector('button');
    const autheliaBtn = autheliaCard?.querySelector('button');
    
    if (hasAuthelia && autheliaRunning) {
        // Authelia is running - disable Basic Auth setup
        if (basicAuthBtn) {
            basicAuthBtn.disabled = true;
            basicAuthBtn.title = 'Authelia is running. Stop Authelia first to use Basic Auth.';
            if (basicAuthCard) {
                basicAuthCard.style.opacity = '0.6';
                basicAuthCard.style.pointerEvents = 'none';
            }
        }
    } else {
        // Authelia not running - enable Basic Auth
        if (basicAuthBtn) {
            basicAuthBtn.disabled = false;
            basicAuthBtn.title = '';
            if (basicAuthCard) {
                basicAuthCard.style.opacity = '1';
                basicAuthCard.style.pointerEvents = 'auto';
            }
        }
    }
    
    if (hasBasicAuth) {
        // Basic Auth has users - disable Authelia setup
        if (autheliaBtn) {
            autheliaBtn.disabled = true;
            autheliaBtn.title = 'Basic Auth is configured. Remove all Basic Auth users first to use Authelia.';
            if (autheliaCard) {
                autheliaCard.style.opacity = '0.6';
                autheliaCard.style.pointerEvents = 'none';
            }
        }
    } else {
        // No Basic Auth users - enable Authelia
        if (autheliaBtn) {
            autheliaBtn.disabled = false;
            autheliaBtn.title = '';
            if (autheliaCard) {
                autheliaCard.style.opacity = '1';
                autheliaCard.style.pointerEvents = 'auto';
            }
        }
    }
}

// Update auth wizard step status
function updateAuthWizardStep(basicAuthData, autheliaData) {
    const stepEl = document.getElementById('step-auth');
    if (!stepEl) return;
    
    const statusEl = stepEl.querySelector('.step-status');
    const actionBtn = stepEl.querySelector('.step-action button');
    
    const hasBasicAuth = basicAuthData && basicAuthData.users && basicAuthData.users.length > 0;
    const hasAuthelia = autheliaData && autheliaData.installed && autheliaData.running;
    
    if (hasBasicAuth || hasAuthelia) {
        statusEl.textContent = '✅';
        statusEl.className = 'step-status success';
        if (actionBtn) actionBtn.textContent = 'Configured ✓';
    } else {
        statusEl.textContent = '⏳';
        statusEl.className = 'step-status';
        if (actionBtn) actionBtn.textContent = 'Configure';
    }
}

// Show Basic Auth setup panel
async function showBasicAuthSetup() {
    // Check if Authelia is running
    try {
        const autheliaData = await fetchAPI('/api/security/authelia/status');
        if (autheliaData.installed && autheliaData.running) {
            if (!confirm('⚠️ Authelia is currently running!\n\nUsing both Basic Auth and Authelia together can cause conflicts.\n\nDo you want to stop Authelia and proceed with Basic Auth setup?')) {
                return;
            }
            // Stop Authelia first
            showToast('Stopping Authelia...', 'info');
            const stopResult = await fetchAPI('/api/security/authelia/stop', { method: 'POST' });
            if (!stopResult.success) {
                showToast('Failed to stop Authelia: ' + (stopResult.error || 'Unknown error'), 'error');
                return;
            }
            showToast('Authelia stopped. Proceeding with Basic Auth setup.', 'success');
            await loadAuthStatus();
        }
    } catch (e) {
        console.error('Error checking Authelia status:', e);
    }
    
    document.querySelector('.auth-choice-section').style.display = 'none';
    document.getElementById('autheliaSetupPanel').style.display = 'none';
    document.getElementById('basicAuthSetupPanel').style.display = 'block';
    
    await loadBasicAuthUsers();
}

// Hide Basic Auth setup panel
function hideBasicAuthSetup() {
    document.getElementById('basicAuthSetupPanel').style.display = 'none';
    document.querySelector('.auth-choice-section').style.display = 'block';
}

// Load basic auth users
async function loadBasicAuthUsers() {
    const usersList = document.getElementById('basicAuthUsersList');
    usersList.innerHTML = '<div class="loading">Loading users...</div>';
    
    try {
        const data = await fetchAPI('/api/security/basicauth/users');
        
        if (data.users && data.users.length > 0) {
            usersList.innerHTML = data.users.map(user => `
                <div class="user-tag">
                    <span>👤 ${user}</span>
                    <span class="delete-user" onclick="deleteBasicAuthUser('${user}')" title="Delete user">✕</span>
                </div>
            `).join('');
        } else {
            usersList.innerHTML = '<div class="text-muted">No users configured. Add a user below.</div>';
        }
    } catch (e) {
        usersList.innerHTML = '<div class="text-error">Error loading users: ' + e.message + '</div>';
    }
}

// Add basic auth user
async function addBasicAuthUser() {
    const username = document.getElementById('basicAuthUsername').value.trim();
    const password = document.getElementById('basicAuthPassword').value;
    
    if (!username || !password) {
        showToast('Please enter both username and password', 'error');
        return;
    }
    
    // Check if Authelia is running
    try {
        const autheliaData = await fetchAPI('/api/security/authelia/status');
        if (autheliaData.installed && autheliaData.running) {
            showToast('⚠️ Cannot add Basic Auth user: Authelia is running. Stop Authelia first to use Basic Auth.', 'error');
            return;
        }
    } catch (e) {
        console.error('Error checking Authelia status:', e);
    }
    
    try {
        const result = await fetchAPI('/api/security/basicauth/user', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ username, password })
        });
        
        if (result.success) {
            showToast(`User '${username}' added successfully`, 'success');
            document.getElementById('basicAuthUsername').value = '';
            document.getElementById('basicAuthPassword').value = '';
            await loadBasicAuthUsers();
            await loadAuthStatus();
        } else {
            showToast('Failed to add user: ' + (result.error || result.output), 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Delete basic auth user
async function deleteBasicAuthUser(username) {
    if (!confirm(`Delete user '${username}'?`)) return;
    
    try {
        const result = await fetchAPI(`/api/security/basicauth/user/${encodeURIComponent(username)}`, {
            method: 'DELETE'
        });
        
        if (result.success) {
            showToast(`User '${username}' deleted`, 'success');
            await loadBasicAuthUsers();
            await loadAuthStatus();
        } else {
            showToast('Failed to delete user: ' + (result.error || result.output), 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Copy basic auth nginx config
function copyBasicAuthConfig() {
    const config = `auth_basic "Restricted Access";
auth_basic_user_file /etc/nginx/.htpasswd;`;
    
    navigator.clipboard.writeText(config).then(() => {
        showToast('Copied to clipboard!', 'success');
    }).catch(() => {
        showToast('Failed to copy', 'error');
    });
}

// Show Authelia setup panel
async function showAutheliaSetup() {
    // Check if Basic Auth has users
    try {
        const basicAuthData = await fetchAPI('/api/security/basicauth/users');
        if (basicAuthData.users && basicAuthData.users.length > 0) {
            if (!confirm(`⚠️ Basic Auth is configured with ${basicAuthData.users.length} user(s)!\n\nUsing both Basic Auth and Authelia together can cause conflicts.\n\nDo you want to remove all Basic Auth users and proceed with Authelia setup?`)) {
                return;
            }
            // Remove all Basic Auth users
            showToast('Removing Basic Auth users...', 'info');
            for (const username of basicAuthData.users) {
                try {
                    await fetchAPI(`/api/security/basicauth/user/${encodeURIComponent(username)}`, { method: 'DELETE' });
                } catch (e) {
                    console.error(`Failed to delete user ${username}:`, e);
                }
            }
            showToast('Basic Auth users removed. Proceeding with Authelia setup.', 'success');
            await loadAuthStatus();
        }
    } catch (e) {
        console.error('Error checking Basic Auth status:', e);
    }
    
    document.querySelector('.auth-choice-section').style.display = 'none';
    document.getElementById('basicAuthSetupPanel').style.display = 'none';
    document.getElementById('autheliaSetupPanel').style.display = 'block';
    
    await loadAutheliaStatus();
}

// Hide Authelia setup panel
function hideAutheliaSetup() {
    document.getElementById('autheliaSetupPanel').style.display = 'none';
    document.querySelector('.auth-choice-section').style.display = 'block';
}

// Load Authelia status
async function loadAutheliaStatus() {
    const statusDisplay = document.getElementById('autheliaContainerStatus');
    const installSection = document.getElementById('autheliaInstallSection');
    const configSection = document.getElementById('autheliaConfigSection');
    
    statusDisplay.innerHTML = '<div class="loading">Checking status...</div>';
    
    try {
        const data = await fetchAPI('/api/security/authelia/status');
        
        if (data.installed) {
            installSection.style.display = 'none';
            configSection.style.display = 'block';
            
            statusDisplay.innerHTML = `
                <div class="status-row">
                    <span class="status-label">Status:</span>
                    <span class="status-value ${data.running ? 'running' : 'stopped'}">${data.status || 'Unknown'}</span>
                </div>
                <div class="status-row">
                    <span class="status-label">Health:</span>
                    <span class="status-value">${data.health || 'N/A'}</span>
                </div>
                <div class="status-row">
                    <span class="status-label">Image:</span>
                    <span class="status-value">${data.image || 'Unknown'}</span>
                </div>
                <div class="status-row">
                    <span class="status-label">Config:</span>
                    <span class="status-value">${data.config_path || 'Not found'}</span>
                </div>
            `;
            
            // Enable/disable action buttons
            document.getElementById('autheliaStartBtn').disabled = data.running;
            document.getElementById('autheliaStopBtn').disabled = !data.running;
        } else {
            installSection.style.display = 'block';
            configSection.style.display = 'none';
            statusDisplay.innerHTML = '<div class="text-muted">Authelia is not installed.</div>';
        }
    } catch (e) {
        statusDisplay.innerHTML = '<div class="text-error">Error: ' + e.message + '</div>';
        installSection.style.display = 'block';
        configSection.style.display = 'none';
    }
}

// Authelia container action
async function autheliaAction(action) {
    showToast(`${action.charAt(0).toUpperCase() + action.slice(1)}ing Authelia...`, 'info');
    
    try {
        const result = await fetchAPI(`/api/security/authelia/${action}`, { method: 'POST' });
        
        if (result.success) {
            showToast(`Authelia ${action}ed successfully`, 'success');
            await loadAutheliaStatus();
            await loadAuthStatus();
        } else {
            showToast(`Failed to ${action} Authelia: ${result.error || result.output}`, 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Install Authelia
async function installAuthelia() {
    // Check if Basic Auth has users
    try {
        const basicAuthData = await fetchAPI('/api/security/basicauth/users');
        if (basicAuthData.users && basicAuthData.users.length > 0) {
            if (!confirm(`⚠️ Basic Auth is configured with ${basicAuthData.users.length} user(s)!\n\nUsing both Basic Auth and Authelia together can cause conflicts.\n\nDo you want to remove all Basic Auth users and proceed with Authelia installation?`)) {
                return;
            }
            // Remove all Basic Auth users
            showToast('Removing Basic Auth users...', 'info');
            for (const username of basicAuthData.users) {
                try {
                    await fetchAPI(`/api/security/basicauth/user/${encodeURIComponent(username)}`, { method: 'DELETE' });
                } catch (e) {
                    console.error(`Failed to delete user ${username}:`, e);
                }
            }
            showToast('Basic Auth users removed.', 'success');
        }
    } catch (e) {
        console.error('Error checking Basic Auth status:', e);
    }
    
    if (!confirm('Auto-install Authelia?\n\nThis will:\n- Enable authelia in docker-compose.yaml\n- Create default configuration\n- Start the Authelia container\n\nYou will need to customize the configuration afterwards.')) return;
    
    showToast('Installing Authelia...', 'info');
    
    try {
        const result = await fetchAPI('/api/security/authelia/install', { method: 'POST' });
        
        if (result.success) {
            showToast('Authelia installed successfully', 'success');
            await loadAutheliaStatus();
            await loadAuthStatus();
        } else {
            showToast('Failed to install: ' + (result.error || result.message), 'error');
            
            // Show output if available
            if (result.output) {
                const outputEl = document.getElementById('authSetupOutput');
                outputEl.style.display = 'block';
                outputEl.querySelector('pre').textContent = result.output;
            }
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Configure Authelia
async function configureAuthelia() {
    const domain = document.getElementById('autheliaPortalDomain').value.trim();
    const email = document.getElementById('autheliaUserEmail').value.trim();
    const password = document.getElementById('autheliaUserPassword').value;
    
    if (!domain || !email || !password) {
        showToast('Please fill in all fields', 'error');
        return;
    }
    
    try {
        const result = await fetchAPI('/api/security/authelia/configure', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ domain, email, password })
        });
        
        if (result.success) {
            showToast('Authelia configured! Restarting...', 'success');
            await autheliaAction('restart');
        } else {
            showToast('Failed to configure: ' + (result.error || result.message), 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Copy Authelia nginx config
function copyAutheliaConfig() {
    const config = `# Inside server block, before location blocks:
include /etc/nginx/snippets/authelia-location.conf;

# Inside each location block you want to protect:
include /etc/nginx/snippets/authelia-authrequest.conf;`;
    
    navigator.clipboard.writeText(config).then(() => {
        showToast('Copied to clipboard!', 'success');
    }).catch(() => {
        showToast('Failed to copy', 'error');
    });
}

// Run full nginx-setup.sh script
async function runFullSetup() {
    if (!confirm('Run the full nginx-setup.sh script?\n\nThis will open an interactive terminal session to:\n- Install nginx, certbot, fail2ban, ufw\n- Configure SSL certificates\n- Set up reverse proxy sites\n- Configure security services\n\nNote: This requires terminal access on the server.')) {
        return;
    }
    
    showSetupOutput('To run the full setup script, execute this on your server:\n\nsudo bash Shellder/nginx-setup.sh\n\nOr use the terminal option below.');
    showToast('Run "sudo bash Shellder/nginx-setup.sh" on your server', 'info');
}

// Show setup output panel
function showSetupOutput(text) {
    const output = document.getElementById('setupWizardOutput');
    const content = document.getElementById('setupOutputContent');
    if (output && content) {
        output.style.display = 'block';
        content.textContent = text;
    }
}

// Append to setup output
function appendSetupOutput(text) {
    const content = document.getElementById('setupOutputContent');
    if (content) {
        content.textContent += '\n' + text;
        content.scrollTop = content.scrollHeight;
    }
}

// Clear setup output
function clearSetupOutput() {
    const output = document.getElementById('setupWizardOutput');
    if (output) {
        output.style.display = 'none';
    }
}

async function loadSecurityStatus() {
    try {
        const data = await fetchAPI('/api/security/status');
        
        // Update UFW status
        const ufwEl = document.getElementById('ufwStatus');
        const ufwIcon = document.getElementById('ufwStatusIcon');
        if (ufwEl && data.ufw) {
            if (data.ufw.installed) {
                ufwEl.textContent = data.ufw.active ? 'Active' : 'Inactive';
                ufwEl.className = 'stat-value ' + (data.ufw.active ? 'text-success' : 'text-warning');
                if (ufwIcon) ufwIcon.className = 'stat-icon ' + (data.ufw.active ? 'success' : 'warning');
            } else {
                ufwEl.textContent = 'Not Installed';
                ufwEl.className = 'stat-value text-muted';
            }
        }
        
        // Update Fail2Ban status
        const f2bEl = document.getElementById('fail2banStatus');
        const f2bIcon = document.getElementById('fail2banStatusIcon');
        if (f2bEl && data.fail2ban) {
            if (data.fail2ban.installed) {
                const banned = data.fail2ban.banned_count || 0;
                f2bEl.textContent = data.fail2ban.active ? `Active (${banned} banned)` : 'Inactive';
                f2bEl.className = 'stat-value ' + (data.fail2ban.active ? 'text-success' : 'text-warning');
                if (f2bIcon) f2bIcon.className = 'stat-icon ' + (data.fail2ban.active ? 'success' : 'warning');
            } else {
                f2bEl.textContent = 'Not Installed';
                f2bEl.className = 'stat-value text-muted';
            }
        }
        
        // Update Authelia status
        const authEl = document.getElementById('autheliaStatus');
        const authIcon = document.getElementById('autheliaStatusIcon');
        if (authEl && data.authelia) {
            if (data.authelia.installed) {
                authEl.textContent = data.authelia.active ? 'Running' : data.authelia.status || 'Stopped';
                authEl.className = 'stat-value ' + (data.authelia.active ? 'text-success' : 'text-warning');
                if (authIcon) authIcon.className = 'stat-icon ' + (data.authelia.active ? 'success' : 'warning');
            } else {
                authEl.textContent = 'Not Found';
                authEl.className = 'stat-value text-muted';
            }
        }
        
        // Update Basic Auth status
        const baEl = document.getElementById('basicAuthStatus');
        if (baEl && data.basic_auth) {
            baEl.textContent = data.basic_auth.user_count > 0 ? 
                `${data.basic_auth.user_count} users` : 'No users';
            baEl.className = 'stat-value ' + (data.basic_auth.user_count > 0 ? '' : 'text-muted');
        }
        
        // Update SSL cert count on nginx page
        if (data.ssl) {
            const sslEl = document.getElementById('sslCerts');
            if (sslEl) sslEl.textContent = data.ssl.count || 0;
        }
        
    } catch (e) {
        console.error('Failed to load security status:', e);
    }
}

// UFW Functions
async function loadUfwStatus() {
    const container = document.getElementById('ufwRules');
    if (!container) return;
    
    try {
        const data = await fetchAPI('/api/security/ufw/status');
        
        if (data.error) {
            container.innerHTML = `<div class="error-msg">${data.error}</div>`;
            return;
        }
        
        if (!data.active) {
            container.innerHTML = `
                <div class="info-msg">
                    <span class="status-badge status-inactive">⚠️ UFW is disabled</span>
                    <p style="margin-top: 10px;">Enable the firewall to protect your server.</p>
                </div>
            `;
            return;
        }
        
        // Show rules
        let html = '<div class="ufw-output"><pre>' + (data.output || 'No rules configured') + '</pre></div>';
        container.innerHTML = html;
        
    } catch (e) {
        container.innerHTML = `<div class="error-msg">Failed to load UFW status: ${e.message}</div>`;
    }
}

async function ufwAction(action) {
    const actionNames = { enable: 'Enabling', disable: 'Disabling', reload: 'Reloading' };
    showToast(`${actionNames[action] || action} UFW...`, 'info');
    
    try {
        const result = await fetchAPI(`/api/security/ufw/${action}`, {
            method: 'POST',
            force: true
        });
        
        if (result.success) {
            showToast(`UFW ${action} successful`, 'success');
            loadUfwStatus();
            loadSecurityStatus();
        } else {
            showToast(`UFW ${action} failed: ${result.output || 'Unknown error'}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function addUfwRule() {
    const type = document.getElementById('ufwRuleType').value;
    const port = document.getElementById('ufwRulePort').value.trim();
    const protocol = document.getElementById('ufwRuleProtocol').value;
    
    if (!port) {
        showToast('Port is required', 'warning');
        return;
    }
    
    try {
        const result = await fetchAPI('/api/security/ufw/rule', {
            method: 'POST',
            body: JSON.stringify({ type, port, protocol }),
            force: true
        });
        
        if (result.success) {
            showToast('Rule added successfully', 'success');
            document.getElementById('ufwRulePort').value = '';
            loadUfwStatus();
        } else {
            showToast(`Failed to add rule: ${result.output || 'Unknown error'}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

// Fail2Ban Functions
async function loadFail2banStatus() {
    const container = document.getElementById('fail2banJails');
    if (!container) return;
    
    try {
        const data = await fetchAPI('/api/security/fail2ban/status');
        
        if (data.error) {
            container.innerHTML = `<div class="error-msg">${data.error}</div>`;
            return;
        }
        
        if (!data.active) {
            container.innerHTML = `
                <div class="info-msg">
                    <span class="status-badge status-inactive">⚠️ Fail2Ban is not running</span>
                    <p style="margin-top: 10px;">Start fail2ban to protect against brute force attacks.</p>
                </div>
            `;
            return;
        }
        
        // Show jails
        if (data.jails && data.jails.length > 0) {
            container.innerHTML = data.jails.map(jail => `
                <div class="jail-item">
                    <div class="jail-header">
                        <span class="jail-name">🔒 ${jail.name}</span>
                        <span class="banned-count ${jail.currently_banned > 0 ? 'has-banned' : ''}">
                            ${jail.currently_banned || 0} banned
                        </span>
                    </div>
                    ${jail.banned_ips && jail.banned_ips.length > 0 ? `
                        <div class="banned-ips">
                            ${jail.banned_ips.map(ip => `
                                <span class="banned-ip" onclick="quickUnban('${ip}', '${jail.name}')">
                                    ${ip} <span class="unban-hint">click to unban</span>
                                </span>
                            `).join('')}
                        </div>
                    ` : ''}
                </div>
            `).join('');
        } else {
            container.innerHTML = '<div class="info-msg">No jails configured</div>';
        }
        
        // Update unban jail dropdown
        const jailSelect = document.getElementById('unbanJail');
        if (jailSelect && data.jails) {
            jailSelect.innerHTML = data.jails.map(j => 
                `<option value="${j.name}">${j.name}</option>`
            ).join('');
        }
        
    } catch (e) {
        container.innerHTML = `<div class="error-msg">Failed to load fail2ban status: ${e.message}</div>`;
    }
}

async function fail2banAction(action) {
    const actionNames = { start: 'Starting', stop: 'Stopping', restart: 'Restarting' };
    showToast(`${actionNames[action] || action} Fail2Ban...`, 'info');
    
    try {
        const result = await fetchAPI(`/api/security/fail2ban/${action}`, {
            method: 'POST',
            force: true
        });
        
        if (result.success) {
            showToast(`Fail2Ban ${action} successful`, 'success');
            setTimeout(() => {
                loadFail2banStatus();
                loadSecurityStatus();
            }, 2000);
        } else {
            showToast(`Fail2Ban ${action} failed: ${result.output || 'Unknown error'}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function unbanIp() {
    const ip = document.getElementById('unbanIp').value.trim();
    const jail = document.getElementById('unbanJail').value;
    
    if (!ip) {
        showToast('IP address is required', 'warning');
        return;
    }
    
    try {
        const result = await fetchAPI('/api/security/fail2ban/unban', {
            method: 'POST',
            body: JSON.stringify({ ip, jail }),
            force: true
        });
        
        if (result.success) {
            showToast(`${ip} unbanned from ${jail}`, 'success');
            document.getElementById('unbanIp').value = '';
            loadFail2banStatus();
        } else {
            showToast(`Failed to unban: ${result.output || 'Unknown error'}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

function quickUnban(ip, jail) {
    document.getElementById('unbanIp').value = ip;
    document.getElementById('unbanJail').value = jail;
    unbanIp();
}

// Authelia Functions
async function loadAutheliaStatus() {
    const container = document.getElementById('autheliaInfo');
    if (!container) return;
    
    try {
        const data = await fetchAPI('/api/security/authelia/status');
        
        if (!data.installed) {
            container.innerHTML = `
                <div class="info-msg">
                    <span class="status-badge status-inactive">⚠️ Authelia not found</span>
                    <p style="margin-top: 10px;">Authelia container is not running or not configured.</p>
                </div>
            `;
            return;
        }
        
        const statusClass = data.running ? 'success' : 'warning';
        container.innerHTML = `
            <div class="authelia-status">
                <div class="status-row">
                    <span>Status:</span>
                    <span class="status-badge status-${statusClass}">${data.status || 'unknown'}</span>
                </div>
                <div class="status-row">
                    <span>Health:</span>
                    <span>${data.health || 'N/A'}</span>
                </div>
                <div class="status-row">
                    <span>Image:</span>
                    <span class="text-muted">${data.image || 'N/A'}</span>
                </div>
                ${data.started_at ? `
                <div class="status-row">
                    <span>Started:</span>
                    <span>${new Date(data.started_at).toLocaleString()}</span>
                </div>
                ` : ''}
            </div>
        `;
        
    } catch (e) {
        container.innerHTML = `<div class="error-msg">Failed to load Authelia status: ${e.message}</div>`;
    }
}

async function autheliaAction(action) {
    const actionNames = { start: 'Starting', stop: 'Stopping', restart: 'Restarting' };
    showToast(`${actionNames[action] || action} Authelia...`, 'info');
    
    try {
        const result = await fetchAPI(`/api/security/authelia/${action}`, {
            method: 'POST',
            force: true
        });
        
        if (result.success) {
            showToast(`Authelia ${action} successful`, 'success');
            setTimeout(() => {
                loadAutheliaStatus();
                loadSecurityStatus();
            }, 2000);
        } else {
            showToast(`Authelia ${action} failed: ${result.output || 'Unknown error'}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function loadAutheliaLogs() {
    showToast('Loading Authelia logs...', 'info');
    try {
        const result = await fetchAPI('/api/containers/authelia/logs?lines=100');
        if (result.logs) {
            // Show in a modal or new tab
            const logWindow = window.open('', 'Authelia Logs', 'width=800,height=600');
            logWindow.document.write(`<pre style="background:#1a1a2e;color:#eee;padding:20px;font-family:monospace;">${result.logs}</pre>`);
        }
    } catch (e) {
        showToast(`Failed to load logs: ${e.message}`, 'error');
    }
}

// Basic Auth Functions
async function loadBasicAuthUsers() {
    const container = document.getElementById('basicAuthUsers');
    if (!container) return;
    
    try {
        const data = await fetchAPI('/api/security/basicauth/users');
        
        if (!data.path) {
            container.innerHTML = `
                <div class="info-msg">
                    <span class="status-badge status-inactive">ℹ️ No htpasswd file found</span>
                    <p style="margin-top: 10px;">Add a user to create the htpasswd file.</p>
                </div>
            `;
            return;
        }
        
        if (data.users && data.users.length > 0) {
            container.innerHTML = `
                <div class="htpasswd-path text-muted" style="margin-bottom: 10px;">
                    📁 ${data.path}
                </div>
                <div class="users-grid">
                    ${data.users.map(user => `
                        <div class="user-item">
                            <span class="user-name">👤 ${user}</span>
                            <button class="btn btn-danger btn-xs" onclick="deleteBasicAuthUser('${user}')">🗑️</button>
                        </div>
                    `).join('')}
                </div>
            `;
        } else {
            container.innerHTML = '<div class="info-msg">No users configured</div>';
        }
        
    } catch (e) {
        container.innerHTML = `<div class="error-msg">Failed to load users: ${e.message}</div>`;
    }
}

async function addBasicAuthUser() {
    const username = document.getElementById('htpasswdUsername').value.trim();
    const password = document.getElementById('htpasswdPassword').value;
    
    if (!username || !password) {
        showToast('Username and password are required', 'warning');
        return;
    }
    
    try {
        const result = await fetchAPI('/api/security/basicauth/user', {
            method: 'POST',
            body: JSON.stringify({ username, password }),
            force: true
        });
        
        if (result.success) {
            showToast(`User ${username} added/updated`, 'success');
            document.getElementById('htpasswdUsername').value = '';
            document.getElementById('htpasswdPassword').value = '';
            loadBasicAuthUsers();
            loadSecurityStatus();
        } else {
            showToast(`Failed to add user: ${result.output || 'Unknown error'}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function deleteBasicAuthUser(username) {
    if (!confirm(`Delete user "${username}"?`)) return;
    
    try {
        const result = await fetchAPI(`/api/security/basicauth/user/${username}`, {
            method: 'DELETE',
            force: true
        });
        
        if (result.success) {
            showToast(`User ${username} deleted`, 'success');
            loadBasicAuthUsers();
            loadSecurityStatus();
        } else {
            showToast(`Failed to delete user: ${result.output || 'Unknown error'}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

// SSL Certificate Functions
async function loadSslCertificates() {
    const container = document.getElementById('sslCertsList');
    if (!container) return;
    
    try {
        const data = await fetchAPI('/api/security/ssl/certificates');
        
        if (data.error) {
            container.innerHTML = `<div class="error-msg">${data.error}</div>`;
            return;
        }
        
        if (data.certificates && data.certificates.length > 0) {
            container.innerHTML = data.certificates.map(cert => {
                // Check if expiring soon (within 30 days)
                let expiryClass = '';
                let expiryIcon = '✅';
                if (cert.expiry) {
                    const expiryDate = new Date(cert.expiry);
                    const daysLeft = Math.ceil((expiryDate - new Date()) / (1000 * 60 * 60 * 24));
                    if (daysLeft < 0) {
                        expiryClass = 'expired';
                        expiryIcon = '❌';
                    } else if (daysLeft < 7) {
                        expiryClass = 'expiring-critical';
                        expiryIcon = '🔴';
                    } else if (daysLeft < 30) {
                        expiryClass = 'expiring-soon';
                        expiryIcon = '🟡';
                    }
                }
                
                return `
                    <div class="cert-item ${expiryClass}">
                        <div class="cert-header">
                            <span class="cert-name">🔒 ${cert.name}</span>
                            <button class="btn btn-warning btn-xs" onclick="renewCert('${cert.name}')">🔄 Renew</button>
                        </div>
                        <div class="cert-domains">
                            ${(cert.domains || []).map(d => `<span class="domain-badge">${d}</span>`).join('')}
                        </div>
                        <div class="cert-expiry ${expiryClass}">
                            ${expiryIcon} Expires: ${cert.expiry || 'Unknown'}
                        </div>
                    </div>
                `;
            }).join('');
        } else {
            container.innerHTML = '<div class="info-msg">No SSL certificates found. Use the Quick Setup above to create certificates.</div>';
        }
        
    } catch (e) {
        container.innerHTML = `<div class="error-msg">Failed to load certificates: ${e.message}</div>`;
    }
}

async function renewCert(domain) {
    showToast(`Renewing certificate for ${domain}...`, 'info');
    
    try {
        const result = await fetchAPI('/api/security/ssl/renew', {
            method: 'POST',
            body: JSON.stringify({ domain }),
            force: true
        });
        
        if (result.success) {
            showToast('Certificate renewed successfully', 'success');
            loadSslCertificates();
        } else {
            showToast(`Renewal failed: ${result.output || 'Unknown error'}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function renewAllCerts() {
    showToast('Renewing all certificates...', 'info');
    
    try {
        const result = await fetchAPI('/api/security/ssl/renew', {
            method: 'POST',
            force: true
        });
        
        if (result.success) {
            showToast('All certificates renewed successfully', 'success');
            loadSslCertificates();
        } else {
            showToast(`Renewal failed: ${result.output || 'Unknown error'}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

// Load security data when nginx page is shown
function loadSecurityData() {
    loadSecurityStatus();
    loadUfwStatus();
    loadFail2banStatus();
    loadAutheliaStatus();
    loadBasicAuthUsers();
    loadSslCertificates();
}

// =============================================================================
// SETUP & CONFIG MANAGER
// =============================================================================

let currentConfigPath = null;

// Tab management
function showSetupTab(tabName) {
    // Hide all tabs
    document.querySelectorAll('.setup-tab-content').forEach(tab => {
        tab.classList.remove('active');
    });
    document.querySelectorAll('.setup-tab').forEach(btn => {
        btn.classList.remove('active');
    });
    
    // Show selected tab
    const tabContent = document.getElementById(`setup-tab-${tabName}`);
    if (tabContent) tabContent.classList.add('active');
    
    // Highlight button
    document.querySelectorAll('.setup-tab').forEach(btn => {
        if (btn.textContent.toLowerCase().includes(tabName)) {
            btn.classList.add('active');
        }
    });
    
    // Load tab data
    switch(tabName) {
        case 'github':
            loadGitStatus();
            loadRecentCommits();
            loadChangedFiles();
            break;
        case 'configs':
            loadConfigFiles();
            break;
        case 'env':
            loadConfigVariablesStatus();  // New comprehensive config variables status
            break;
    }
}

// Load setup status overview
async function loadSetupStatus() {
    try {
        const data = await fetchAPI('/api/setup/status');
        
        // Update status card
        const statusEl = document.getElementById('setupStatus');
        const statusIcon = document.getElementById('setupStatusIcon');
        if (statusEl) {
            if (data.summary.setup_complete) {
                statusEl.textContent = 'Complete';
                statusEl.className = 'stat-value text-success';
                if (statusIcon) statusIcon.className = 'stat-icon success';
            } else {
                statusEl.textContent = 'Incomplete';
                statusEl.className = 'stat-value text-warning';
                if (statusIcon) statusIcon.className = 'stat-icon warning';
            }
        }
        
        // Update configs status
        const configsEl = document.getElementById('configsStatus');
        if (configsEl) {
            configsEl.textContent = `${data.summary.configs_present}/${data.summary.configs_present + data.summary.configs_missing}`;
        }
        
        // Load config variables status (separate API call for detailed sync info)
        loadConfigVarsQuickStatus();
        
        return data;
    } catch (e) {
        console.error('Failed to load setup status:', e);
    }
}

// Store config vars data for dropdown
let cachedConfigVarsData = null;

// Quick load of config variables count and sync status for the stat card
async function loadConfigVarsQuickStatus() {
    const countEl = document.getElementById('configVarsStatusCount');
    const syncLight = document.getElementById('configVarsSyncLight');
    
    if (!countEl) return;
    
    try {
        const data = await fetchAPI('/api/config/variables-status');
        cachedConfigVarsData = data;  // Cache for dropdown
        
        // Update count: configured/total (using new API format)
        const configured = data.summary.configured || 0;
        const total = data.summary.total || 0;
        countEl.textContent = `${configured}/${total}`;
        
        // Update sync light based on overall status
        if (syncLight) {
            const status = data.summary.overall_status;
            const mismatched = data.summary.mismatched || 0;
            const notConfigured = data.summary.not_configured || 0;
            
            if (status === 'mismatch' || mismatched > 0) {
                syncLight.className = 'sync-light mismatch';
                syncLight.title = `${mismatched} secret(s) have mismatched values - click to view`;
            } else if (status === 'incomplete' || notConfigured > 0) {
                syncLight.className = 'sync-light partial';
                syncLight.title = `${notConfigured} secret(s) still at default - must be configured`;
            } else if (status === 'synced') {
                syncLight.className = 'sync-light synced';
                syncLight.title = 'All secrets configured and synced across configs';
            } else {
                syncLight.className = 'sync-light synced';
                syncLight.title = 'Configuration OK';
            }
        }
    } catch (e) {
        console.error('Failed to load config vars status:', e);
        if (countEl) countEl.textContent = '-/-';
        if (syncLight) {
            syncLight.className = 'sync-light checking';
            syncLight.title = 'Failed to load status';
        }
    }
}

// Toggle config variables dropdown
function toggleConfigVarsDropdown(event) {
    event.stopPropagation();
    const dropdown = document.getElementById('configVarsDropdown');
    if (!dropdown) return;
    
    const isOpen = dropdown.classList.contains('show');
    
    // Close all other dropdowns first
    document.querySelectorAll('.stat-dropdown.show').forEach(d => d.classList.remove('show'));
    
    if (!isOpen) {
        dropdown.classList.add('show');
        populateConfigVarsDropdown();
    }
}

// Close dropdown when clicking outside
document.addEventListener('click', (e) => {
    if (!e.target.closest('.stat-card')) {
        document.querySelectorAll('.stat-dropdown.show').forEach(d => d.classList.remove('show'));
    }
});

// Populate the dropdown with config variables status
async function populateConfigVarsDropdown() {
    const content = document.getElementById('configVarsDropdownContent');
    if (!content) return;
    
    // Use cached data or fetch fresh
    let data = cachedConfigVarsData;
    if (!data) {
        content.innerHTML = '<div class="loading-small">Loading...</div>';
        try {
            data = await fetchAPI('/api/config/variables-status');
            cachedConfigVarsData = data;
        } catch (e) {
            content.innerHTML = '<div class="loading-small">Failed to load</div>';
            return;
        }
    }
    
    let html = '';
    
    // Summary row (using new API format)
    const synced = data.summary.synced || 0;
    const notConfigured = data.summary.not_configured || 0;
    const mismatched = data.summary.mismatched || 0;
    
    html += `
        <div class="dropdown-summary">
            <div class="dropdown-summary-item ok">✅ ${synced} synced</div>
            <div class="dropdown-summary-item warning">⚠️ ${notConfigured} unconfigured</div>
            <div class="dropdown-summary-item error">❌ ${mismatched} mismatched</div>
        </div>
    `;
    
    // Group variables by their category from the categories definition
    const varsByCategory = { 'database': [], 'secrets': [] };
    
    for (const [varName, varInfo] of Object.entries(data.variables || {})) {
        // Determine category based on variable name
        if (varName.startsWith('MYSQL')) {
            varsByCategory.database.push([varName, varInfo]);
        } else {
            varsByCategory.secrets.push([varName, varInfo]);
        }
    }
    
    // Show database secrets first
    if (varsByCategory.database.length > 0) {
        html += `
            <div class="dropdown-category">
                <div class="dropdown-category-title">🗄️ Database</div>
                <div class="dropdown-var-list">
        `;
        
        for (const [varName, varInfo] of varsByCategory.database) {
            let statusClass = 'empty';
            if (varInfo.sync_status === 'mismatch') statusClass = 'mismatch';
            else if (varInfo.sync_status === 'synced') statusClass = 'ok';
            else if (varInfo.sync_status === 'not_configured') statusClass = 'missing';
            
            html += `
                <div class="dropdown-var-item">
                    <span class="var-status ${statusClass}"></span>
                    <span class="var-name">${varInfo.label}</span>
                    <span class="var-value">${varInfo.is_configured ? '•••' : 'default'}</span>
                </div>
            `;
        }
        
        html += `</div></div>`;
    }
    
    // Show service secrets
    if (varsByCategory.secrets.length > 0) {
        html += `
            <div class="dropdown-category">
                <div class="dropdown-category-title">🔐 Secrets</div>
                <div class="dropdown-var-list">
        `;
        
        for (const [varName, varInfo] of varsByCategory.secrets) {
            let statusClass = 'empty';
            if (varInfo.sync_status === 'mismatch') statusClass = 'mismatch';
            else if (varInfo.sync_status === 'synced') statusClass = 'ok';
            else if (varInfo.sync_status === 'not_configured') statusClass = 'missing';
            
            html += `
                <div class="dropdown-var-item">
                    <span class="var-status ${statusClass}"></span>
                    <span class="var-name">${varInfo.label}</span>
                    <span class="var-value">${varInfo.is_configured ? '•••' : 'default'}</span>
                </div>
            `;
        }
        
        html += `</div></div>`;
    }
    
    content.innerHTML = html;
}

function truncateValue(val, maxLen = 30) {
    if (!val || val === '-') return val;
    const str = String(val);
    return str.length > maxLen ? str.substring(0, maxLen) + '...' : str;
}

// Navigate to Config Status tab
function goToConfigStatus(event) {
    event.stopPropagation();
    
    // Close dropdown
    document.querySelectorAll('.stat-dropdown.show').forEach(d => d.classList.remove('show'));
    
    // Navigate to setup page and show env tab (which is now Config Status)
    navigateTo('setup');
    setTimeout(() => {
        showSetupTab('env');
    }, 100);
}

// =============================================================================
// FLETCHLING MANAGEMENT
// =============================================================================

async function loadFletchlingStatus() {
    try {
        const data = await fetchAPI('/api/fletchling/status');
        
        // Update Docker Compose status
        const composeStatus = document.querySelector('#fletchling-compose-status .status-light');
        const composeDesc = document.querySelector('#fletchling-compose-status .status-desc');
        if (composeStatus) {
            composeStatus.className = 'status-light ' + (data.docker_compose.enabled ? 'success' : 'error');
            composeDesc.textContent = data.docker_compose.enabled 
                ? 'Service enabled in docker-compose.yaml'
                : 'Service commented out (disabled)';
        }
        
        // Update Config status
        const configStatus = document.querySelector('#fletchling-config-status .status-light');
        const configDesc = document.querySelector('#fletchling-config-status .status-desc');
        if (configStatus) {
            if (!data.config.file_exists) {
                configStatus.className = 'status-light error';
                configDesc.textContent = 'fletchling.toml not found';
            } else if (data.config.has_placeholder) {
                configStatus.className = 'status-light warning';
                configDesc.textContent = 'Project not configured (has placeholder)';
            } else if (data.config.project_configured) {
                configStatus.className = 'status-light success';
                configDesc.textContent = `Project: ${data.config.project_name}`;
                // Pre-fill the project name input
                const input = document.getElementById('fletchlingProjectName');
                if (input && !input.value) {
                    input.value = data.config.project_name || '';
                }
            } else {
                configStatus.className = 'status-light warning';
                configDesc.textContent = 'Configuration incomplete';
            }
        }
        
        // Update Container status
        const containerStatus = document.querySelector('#fletchling-container-status .status-light');
        const containerDesc = document.querySelector('#fletchling-container-status .status-desc');
        if (containerStatus) {
            if (data.container.running) {
                containerStatus.className = 'status-light success';
                containerDesc.textContent = `Running (${data.container.health})`;
            } else if (data.docker_compose.enabled) {
                containerStatus.className = 'status-light warning';
                containerDesc.textContent = 'Enabled but not running';
            } else {
                containerStatus.className = 'status-light error';
                containerDesc.textContent = 'Not running';
            }
        }
        
        // Update Nests Table status
        const nestsStatus = document.querySelector('#fletchling-nests-status .status-light');
        const nestsDesc = document.querySelector('#fletchling-nests-status .status-desc');
        if (nestsStatus) {
            if (data.database.nests_table_exists) {
                if (data.database.nests_count > 0) {
                    nestsStatus.className = 'status-light success';
                    nestsDesc.textContent = `${data.database.nests_count} nests (${data.database.active_nests} active)`;
                    
                    // Show stats section
                    const statsEl = document.getElementById('fletchlingStats');
                    if (statsEl) {
                        statsEl.style.display = 'block';
                        document.getElementById('totalNests').textContent = data.database.nests_count;
                        document.getElementById('activeNests').textContent = data.database.active_nests;
                    }
                } else {
                    nestsStatus.className = 'status-light warning';
                    nestsDesc.textContent = 'Table exists but empty - run OSM import';
                }
            } else {
                nestsStatus.className = 'status-light error';
                nestsDesc.textContent = 'Nests table not found in golbat DB';
            }
        }
        
        // Update OSM Park Data status
        const osmStatus = document.querySelector('#fletchling-osm-status .status-light');
        const osmDesc = document.querySelector('#fletchling-osm-status .status-desc');
        if (osmStatus) {
            if (data.osm_data && data.osm_data.parks_count > 0) {
                osmStatus.className = 'status-light success';
                osmDesc.textContent = `${data.osm_data.parks_count} park areas imported`;
            } else if (data.osm_data && data.osm_data.table_exists) {
                osmStatus.className = 'status-light warning';
                osmDesc.textContent = 'Table exists but no park data - run OSM import';
            } else {
                osmStatus.className = 'status-light error';
                osmDesc.textContent = 'OSM park data not imported';
            }
        }
        
        // Update Webhook status
        const webhookStatus = document.querySelector('#fletchling-webhook-status .status-light');
        const webhookDesc = document.querySelector('#fletchling-webhook-status .status-desc');
        if (webhookStatus) {
            webhookStatus.className = 'status-light ' + (data.golbat_webhook.configured ? 'success' : 'warning');
            webhookDesc.textContent = data.golbat_webhook.configured 
                ? 'Golbat configured to send data'
                : 'Webhook not configured in Golbat';
        }
        
        // Update step states based on status
        updateFletchlingSteps(data);
        
    } catch (e) {
        console.error('Failed to load Fletchling status:', e);
        showToast('Failed to load Fletchling status', 'error');
    }
}

function updateFletchlingSteps(data) {
    // Step 1: Enable
    const step1 = document.getElementById('fletchling-step-enable');
    if (step1 && data.docker_compose.enabled) {
        step1.classList.add('completed');
    }
    
    // Step 2: Config
    const step2 = document.getElementById('fletchling-step-config');
    if (step2 && data.config.project_configured) {
        step2.classList.add('completed');
    }
    
    // Step 3: Webhook
    const step3 = document.getElementById('fletchling-step-webhook');
    if (step3 && data.golbat_webhook.configured) {
        step3.classList.add('completed');
    }
    
    // Step 4: Running
    const step4 = document.getElementById('fletchling-step-start');
    if (step4 && data.container.running) {
        step4.classList.add('completed');
    }
}

async function enableFletchling() {
    try {
        showToast('Enabling Fletchling in docker-compose.yaml...', 'info');
        const result = await fetchAPI('/api/fletchling/enable', { method: 'POST' });
        
        if (result.success) {
            showToast(result.message, 'success');
            loadFletchlingStatus();
        } else {
            showToast(result.message || 'Failed to enable Fletchling', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

async function configureFletchling() {
    const projectName = document.getElementById('fletchlingProjectName').value.trim();
    
    if (!projectName) {
        showToast('Please enter your Koji project name', 'warning');
        return;
    }
    
    try {
        showToast('Configuring Fletchling...', 'info');
        const result = await fetchAPI('/api/fletchling/configure', {
            method: 'POST',
            body: JSON.stringify({ project_name: projectName })
        });
        
        if (result.success) {
            showToast(result.message, 'success');
            loadFletchlingStatus();
        } else {
            showToast(result.message || 'Failed to configure Fletchling', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

async function addFletchlingWebhook() {
    try {
        showToast('Adding Fletchling webhook to Golbat...', 'info');
        const result = await fetchAPI('/api/fletchling/add-webhook', { method: 'POST' });
        
        if (result.success) {
            showToast(result.message, 'success');
            loadFletchlingStatus();
        } else {
            showToast(result.message || 'Failed to add webhook', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

async function startFletchling() {
    try {
        showToast('Starting Fletchling containers...', 'info');
        const result = await fetchAPI('/api/fletchling/start', { method: 'POST' });
        
        if (result.success) {
            showToast(result.message, 'success');
            setTimeout(loadFletchlingStatus, 3000); // Wait for container to start
        } else {
            showToast(result.message || 'Failed to start Fletchling', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Import OSM park data for Fletchling nest detection
async function importFletchlingOSM() {
    const areaName = document.getElementById('fletchlingOSMArea')?.value?.trim();
    
    if (!areaName) {
        showToast('Please enter an area name that matches a Koji geofence', 'warning');
        return;
    }
    
    // Show progress indicator
    const progressEl = document.getElementById('osmImportProgress');
    if (progressEl) {
        progressEl.style.display = 'block';
        progressEl.querySelector('.progress-text').textContent = 'Starting OSM import...';
        progressEl.querySelector('.progress-fill').style.width = '10%';
    }
    
    showToast(`Importing OSM park data for "${areaName}"... This may take several minutes.`, 'info');
    
    try {
        const result = await fetchAPI('/api/fletchling/import-osm', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ area_name: areaName })
        });
        
        if (progressEl) {
            progressEl.querySelector('.progress-fill').style.width = '100%';
        }
        
        if (result.success) {
            showToast(result.message || 'OSM park data imported successfully!', 'success');
            if (progressEl) {
                progressEl.querySelector('.progress-text').textContent = result.message || 'Import complete!';
                setTimeout(() => { progressEl.style.display = 'none'; }, 3000);
            }
            setTimeout(loadFletchlingStatus, 1000);
        } else {
            showToast(result.message || 'OSM import failed', 'error');
            if (progressEl) {
                progressEl.querySelector('.progress-text').textContent = 'Import failed: ' + (result.message || 'Unknown error');
                progressEl.querySelector('.progress-fill').style.background = '#dc3545';
            }
        }
    } catch (e) {
        console.error('OSM import error:', e);
        showToast('Error: ' + e.message, 'error');
        if (progressEl) {
            progressEl.querySelector('.progress-text').textContent = 'Error: ' + e.message;
            progressEl.querySelector('.progress-fill').style.background = '#dc3545';
        }
    }
}

async function stopFletchling() {
    try {
        showToast('Stopping Fletchling containers...', 'info');
        const result = await fetchAPI('/api/fletchling/stop', { method: 'POST' });
        
        if (result.success) {
            showToast(result.message, 'success');
            loadFletchlingStatus();
        } else {
            showToast(result.message || 'Failed to stop Fletchling', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// =============================================================================
// FLETCHLING NEST MANAGEMENT
// =============================================================================

let nestCurrentPage = 1;
let nestTotalPages = 1;
let nestPageSize = 25;

// Load nest statistics and populate area filter
async function loadNestStats() {
    try {
        const data = await fetchAPI('/api/fletchling/nests/stats');
        
        if (data.success) {
            // Update stat cards
            document.getElementById('totalAreasCount').textContent = data.stats.total_areas || 0;
            document.getElementById('totalNestsCount').textContent = data.stats.total_nests || 0;
            document.getElementById('activeNestsCount').textContent = data.stats.active_nests || 0;
            document.getElementById('unknownNestsCount').textContent = data.stats.unknown_nests || 0;
            
            // Populate area filter dropdown
            const areaFilter = document.getElementById('nestAreaFilter');
            if (areaFilter && data.stats.areas) {
                areaFilter.innerHTML = '<option value="">All Areas</option>';
                data.stats.areas.forEach(area => {
                    const opt = document.createElement('option');
                    opt.value = area.name;
                    opt.textContent = `${area.name} (${area.nest_count} nests)`;
                    areaFilter.appendChild(opt);
                });
            }
            
            // Populate areas list
            renderAreasList(data.stats.areas || []);
        }
    } catch (e) {
        console.error('Failed to load nest stats:', e);
    }
}

// Render the monitored areas list
function renderAreasList(areas) {
    const container = document.getElementById('areasListContainer');
    if (!container) return;
    
    if (!areas || areas.length === 0) {
        container.innerHTML = `
            <div class="empty-state">
                <p>No monitored areas found.</p>
                <p>Run the OSM importer to import park data for your areas.</p>
            </div>
        `;
        return;
    }
    
    container.innerHTML = areas.map(area => `
        <div class="area-card">
            <div class="area-header">
                <h4>${escapeHtml(area.name)}</h4>
                <div class="area-actions">
                    <button class="btn btn-xs" onclick="reimportArea('${escapeHtml(area.name)}')" title="Re-import OSM data">
                        🔄 Re-import
                    </button>
                    <button class="btn btn-xs btn-danger" onclick="deleteArea('${escapeHtml(area.name)}')" title="Delete all nests in this area">
                        🗑️
                    </button>
                </div>
            </div>
            <div class="area-stats">
                <span class="area-stat">
                    <span class="stat-icon">🪹</span>
                    ${area.nest_count} nests
                </span>
                <span class="area-stat">
                    <span class="stat-icon">✅</span>
                    ${area.active_count || 0} active
                </span>
                <span class="area-stat">
                    <span class="stat-icon">❓</span>
                    ${area.unknown_count || 0} unknown
                </span>
            </div>
        </div>
    `).join('');
}

// Load nest list with filters and pagination
async function loadNestList(page = 1) {
    nestCurrentPage = page;
    const areaFilter = document.getElementById('nestAreaFilter')?.value || '';
    const showUnknownOnly = document.getElementById('showUnknownOnly')?.checked || false;
    const showActiveOnly = document.getElementById('showActiveOnly')?.checked || false;
    
    const tbody = document.getElementById('nestTableBody');
    if (tbody) {
        tbody.innerHTML = '<tr><td colspan="6" class="loading-row">Loading nests...</td></tr>';
    }
    
    try {
        const params = new URLSearchParams({
            page: page,
            limit: nestPageSize,
            area: areaFilter,
            unknown_only: showUnknownOnly,
            active_only: showActiveOnly
        });
        
        const data = await fetchAPI(`/api/fletchling/nests?${params}`);
        
        if (data.success) {
            renderNestTable(data.nests);
            nestTotalPages = data.total_pages || 1;
            updateNestPagination();
        } else {
            if (tbody) {
                tbody.innerHTML = `<tr><td colspan="6" class="error-row">${data.message || 'Failed to load nests'}</td></tr>`;
            }
        }
    } catch (e) {
        console.error('Failed to load nest list:', e);
        if (tbody) {
            tbody.innerHTML = '<tr><td colspan="6" class="error-row">Error loading nests</td></tr>';
        }
    }
}

// Render nest table rows
function renderNestTable(nests) {
    const tbody = document.getElementById('nestTableBody');
    if (!tbody) return;
    
    if (!nests || nests.length === 0) {
        tbody.innerHTML = '<tr><td colspan="6" class="empty-row">No nests found</td></tr>';
        return;
    }
    
    tbody.innerHTML = nests.map(nest => {
        const pokemonName = nest.pokemon_id > 0 ? getPokemonName(nest.pokemon_id) : '-';
        const pokemonClass = nest.pokemon_id > 0 ? 'active' : 'inactive';
        const isUnknown = nest.name === 'Unknown Nest' || !nest.name;
        const nameClass = isUnknown ? 'unknown-nest' : '';
        const lastUpdated = nest.updated ? formatRelativeTime(nest.updated) : 'Never';
        
        return `
            <tr class="${pokemonClass}">
                <td class="${nameClass}">${escapeHtml(nest.name || 'Unknown Nest')}</td>
                <td>${escapeHtml(nest.area_name || '-')}</td>
                <td>
                    ${nest.pokemon_id > 0 ? `
                        <span class="pokemon-badge">
                            <img src="https://raw.githubusercontent.com/PokeMiners/pogo_assets/master/Images/Pokemon/Addressable%20Assets/pm${nest.pokemon_id}.icon.png" 
                                 alt="${pokemonName}" width="24" height="24" onerror="this.style.display='none'">
                            #${nest.pokemon_id} ${pokemonName}
                        </span>
                    ` : '<span class="no-pokemon">No nest detected</span>'}
                </td>
                <td>${nest.pokemon_count || 0}</td>
                <td>${lastUpdated}</td>
                <td>
                    <button class="btn btn-xs" onclick="editNest(${nest.nest_id})" title="Edit">✏️</button>
                    <button class="btn btn-xs btn-danger" onclick="confirmDeleteNest(${nest.nest_id}, '${escapeHtml(nest.name || 'Unknown')}')" title="Delete">🗑️</button>
                </td>
            </tr>
        `;
    }).join('');
}

// Get Pokemon name from ID (basic lookup)
function getPokemonName(id) {
    const commonPokemon = {
        1: 'Bulbasaur', 4: 'Charmander', 7: 'Squirtle', 10: 'Caterpie', 13: 'Weedle',
        16: 'Pidgey', 19: 'Rattata', 21: 'Spearow', 23: 'Ekans', 25: 'Pikachu',
        27: 'Sandshrew', 29: 'Nidoran♀', 32: 'Nidoran♂', 35: 'Clefairy', 37: 'Vulpix',
        39: 'Jigglypuff', 41: 'Zubat', 43: 'Oddish', 46: 'Paras', 48: 'Venonat',
        50: 'Diglett', 52: 'Meowth', 54: 'Psyduck', 56: 'Mankey', 58: 'Growlithe',
        60: 'Poliwag', 63: 'Abra', 66: 'Machop', 69: 'Bellsprout', 72: 'Tentacool',
        74: 'Geodude', 77: 'Ponyta', 79: 'Slowpoke', 81: 'Magnemite', 84: 'Doduo',
        86: 'Seel', 88: 'Grimer', 90: 'Shellder', 92: 'Gastly', 95: 'Onix',
        96: 'Drowzee', 98: 'Krabby', 100: 'Voltorb', 102: 'Exeggcute', 104: 'Cubone',
        108: 'Lickitung', 109: 'Koffing', 111: 'Rhyhorn', 114: 'Tangela', 116: 'Horsea',
        118: 'Goldeen', 120: 'Staryu', 123: 'Scyther', 125: 'Electabuzz', 126: 'Magmar',
        127: 'Pinsir', 129: 'Magikarp', 133: 'Eevee', 138: 'Omanyte', 140: 'Kabuto',
        147: 'Dratini', 152: 'Chikorita', 155: 'Cyndaquil', 158: 'Totodile',
        161: 'Sentret', 163: 'Hoothoot', 165: 'Ledyba', 167: 'Spinarak', 170: 'Chinchou',
        177: 'Natu', 179: 'Mareep', 183: 'Marill', 187: 'Hoppip', 190: 'Aipom',
        191: 'Sunkern', 193: 'Yanma', 194: 'Wooper', 198: 'Murkrow', 200: 'Misdreavus',
        202: 'Wobbuffet', 203: 'Girafarig', 204: 'Pineco', 206: 'Dunsparce', 207: 'Gligar',
        209: 'Snubbull', 211: 'Qwilfish', 213: 'Shuckle', 214: 'Heracross', 215: 'Sneasel',
        216: 'Teddiursa', 218: 'Slugma', 220: 'Swinub', 222: 'Corsola', 223: 'Remoraid',
        225: 'Delibird', 226: 'Mantine', 227: 'Skarmory', 228: 'Houndour', 231: 'Phanpy',
        234: 'Stantler', 238: 'Smoochum', 239: 'Elekid', 240: 'Magby', 246: 'Larvitar'
    };
    return commonPokemon[id] || `Pokemon #${id}`;
}

// Update pagination controls
function updateNestPagination() {
    document.getElementById('nestPageInfo').textContent = `Page ${nestCurrentPage} of ${nestTotalPages}`;
    document.getElementById('nestPrevBtn').disabled = nestCurrentPage <= 1;
    document.getElementById('nestNextBtn').disabled = nestCurrentPage >= nestTotalPages;
    document.getElementById('nestLastBtn').disabled = nestCurrentPage >= nestTotalPages;
}

function nestPrevPage() {
    if (nestCurrentPage > 1) loadNestList(nestCurrentPage - 1);
}

function nestNextPage() {
    if (nestCurrentPage < nestTotalPages) loadNestList(nestCurrentPage + 1);
}

function nestLastPage() {
    loadNestList(nestTotalPages);
}

// Edit nest modal
async function editNest(nestId) {
    try {
        const data = await fetchAPI(`/api/fletchling/nests/${nestId}`);
        
        if (data.success && data.nest) {
            document.getElementById('editNestId').value = data.nest.nest_id;
            document.getElementById('editNestName').value = data.nest.name || '';
            document.getElementById('editNestPokemonId').value = data.nest.pokemon_id || 0;
            document.getElementById('editNestArea').value = data.nest.area_name || '';
            document.getElementById('editNestLat').value = data.nest.lat || '';
            document.getElementById('editNestLon').value = data.nest.lon || '';
            
            // Update pokemon preview
            updatePokemonPreview();
            
            openModal('editNestModal');
        } else {
            showToast(data.message || 'Failed to load nest details', 'error');
        }
    } catch (e) {
        showToast('Error loading nest: ' + e.message, 'error');
    }
}

// Update Pokemon preview when ID changes
function updatePokemonPreview() {
    const pokemonId = parseInt(document.getElementById('editNestPokemonId').value) || 0;
    const preview = document.getElementById('editNestPokemonPreview');
    
    if (pokemonId > 0) {
        preview.innerHTML = `
            <img src="https://raw.githubusercontent.com/PokeMiners/pogo_assets/master/Images/Pokemon/Addressable%20Assets/pm${pokemonId}.icon.png" 
                 alt="Pokemon #${pokemonId}" width="32" height="32" onerror="this.parentElement.textContent='#${pokemonId}'">
            <span>${getPokemonName(pokemonId)}</span>
        `;
    } else {
        preview.innerHTML = '<span class="no-pokemon">No nest</span>';
    }
}

// Save nest changes
async function saveNest() {
    const nestId = document.getElementById('editNestId').value;
    const name = document.getElementById('editNestName').value.trim();
    const pokemonId = parseInt(document.getElementById('editNestPokemonId').value) || 0;
    
    try {
        const result = await fetchAPI(`/api/fletchling/nests/${nestId}`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name, pokemon_id: pokemonId })
        });
        
        if (result.success) {
            showToast('Nest updated successfully', 'success');
            closeModal('editNestModal');
            loadNestList(nestCurrentPage);
            loadNestStats();
        } else {
            showToast(result.message || 'Failed to update nest', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Delete nest
function confirmDeleteNest(nestId, name) {
    if (confirm(`Are you sure you want to delete the nest "${name}"?\n\nThis cannot be undone.`)) {
        deleteNestById(nestId);
    }
}

async function deleteNest() {
    const nestId = document.getElementById('editNestId').value;
    if (confirm('Are you sure you want to delete this nest?\n\nThis cannot be undone.')) {
        await deleteNestById(nestId);
        closeModal('editNestModal');
    }
}

async function deleteNestById(nestId) {
    try {
        const result = await fetchAPI(`/api/fletchling/nests/${nestId}`, {
            method: 'DELETE'
        });
        
        if (result.success) {
            showToast('Nest deleted successfully', 'success');
            loadNestList(nestCurrentPage);
            loadNestStats();
        } else {
            showToast(result.message || 'Failed to delete nest', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// Add area modal
function showAddAreaModal() {
    document.getElementById('addAreaName').value = '';
    openModal('addAreaModal');
}

// Add monitored area and run OSM import
async function addMonitoredArea() {
    const areaName = document.getElementById('addAreaName').value.trim();
    const importMethod = document.querySelector('input[name="importMethod"]:checked').value;
    
    if (!areaName) {
        showToast('Please enter an area name', 'warning');
        return;
    }
    
    closeModal('addAreaModal');
    
    if (importMethod === 'osm') {
        // Run OSM import for the area
        document.getElementById('fletchlingOSMArea').value = areaName;
        await importFletchlingOSM();
    } else {
        showToast('Manual area addition coming soon. Use OSM import for now.', 'info');
    }
    
    // Reload stats
    loadNestStats();
    loadNestList();
}

// Re-import OSM data for an area
async function reimportArea(areaName) {
    if (confirm(`Re-import OSM park data for "${areaName}"?\n\nThis will fetch the latest park boundaries from OpenStreetMap.`)) {
        document.getElementById('fletchlingOSMArea').value = areaName;
        await importFletchlingOSM();
        loadNestStats();
        loadNestList();
    }
}

// Delete all nests in an area
async function deleteArea(areaName) {
    if (confirm(`Delete ALL nests in "${areaName}"?\n\nThis will remove all nest data for this area. You can re-import later.`)) {
        try {
            const result = await fetchAPI('/api/fletchling/areas/' + encodeURIComponent(areaName), {
                method: 'DELETE'
            });
            
            if (result.success) {
                showToast(`Deleted ${result.deleted_count || 0} nests from ${areaName}`, 'success');
                loadNestStats();
                loadNestList();
            } else {
                showToast(result.message || 'Failed to delete area', 'error');
            }
        } catch (e) {
            showToast('Error: ' + e.message, 'error');
        }
    }
}

// Format relative time
function formatRelativeTime(timestamp) {
    if (!timestamp) return 'Never';
    const date = new Date(timestamp);
    const now = new Date();
    const diffMs = now - date;
    const diffMins = Math.floor(diffMs / 60000);
    const diffHours = Math.floor(diffMins / 60);
    const diffDays = Math.floor(diffHours / 24);
    
    if (diffMins < 1) return 'Just now';
    if (diffMins < 60) return `${diffMins}m ago`;
    if (diffHours < 24) return `${diffHours}h ago`;
    if (diffDays < 7) return `${diffDays}d ago`;
    return date.toLocaleDateString();
}

// Add event listener for Pokemon ID input preview
document.addEventListener('DOMContentLoaded', function() {
    const pokemonIdInput = document.getElementById('editNestPokemonId');
    if (pokemonIdInput) {
        pokemonIdInput.addEventListener('input', updatePokemonPreview);
    }
});

async function restartGolbat() {
    try {
        showToast('Restarting Golbat to apply webhook changes...', 'info');
        const result = await fetchAPI('/api/containers/golbat/restart', { method: 'POST' });
        
        if (result.success) {
            showToast('Golbat restarted successfully', 'success');
        } else {
            showToast('Failed to restart Golbat', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

// =============================================================================
// PORACLE MANAGEMENT
// =============================================================================

async function loadPoracleStatus() {
    try {
        const data = await fetchAPI('/api/poracle/status');
        
        // Update Docker Compose status
        const composeStatus = document.querySelector('#poracle-compose-status .status-light');
        const composeDesc = document.querySelector('#poracle-compose-status .status-desc');
        if (composeStatus) {
            composeStatus.className = 'status-light ' + (data.docker_compose.enabled ? 'success' : 'error');
            composeDesc.textContent = data.docker_compose.enabled 
                ? 'Service enabled in docker-compose.yaml'
                : 'Service commented out (disabled)';
        }
        
        // Update Config status
        const configStatus = document.querySelector('#poracle-config-status .status-light');
        const configDesc = document.querySelector('#poracle-config-status .status-desc');
        if (configStatus) {
            if (!data.config.file_exists) {
                configStatus.className = 'status-light error';
                configDesc.textContent = 'Poracle/config/local.json not found';
            } else if (data.config.has_placeholder) {
                configStatus.className = 'status-light warning';
                configDesc.textContent = 'Database password not configured';
            } else {
                configStatus.className = 'status-light success';
                configDesc.textContent = 'Configuration file ready';
            }
        }
        
        // Update Container status
        const containerStatus = document.querySelector('#poracle-container-status .status-light');
        const containerDesc = document.querySelector('#poracle-container-status .status-desc');
        if (containerStatus) {
            containerStatus.className = 'status-light ' + (data.container.running ? 'success' : 'error');
            containerDesc.textContent = data.container.running ? 'Container running' : 'Container not running';
        }
        
        // Update Database status
        const dbStatus = document.querySelector('#poracle-database-status .status-light');
        const dbDesc = document.querySelector('#poracle-database-status .status-desc');
        if (dbStatus) {
            if (data.database.connected) {
                dbStatus.className = 'status-light success';
                dbDesc.textContent = `Database ready (${data.database.user_count || 0} users)`;
            } else {
                dbStatus.className = 'status-light error';
                dbDesc.textContent = data.database.error || 'Database not connected';
            }
        }
        
        // Update Discord status
        const discordStatus = document.querySelector('#poracle-discord-status .status-light');
        const discordDesc = document.querySelector('#poracle-discord-status .status-desc');
        if (discordStatus) {
            if (data.discord.enabled) {
                discordStatus.className = 'status-light ' + (data.discord.token_set ? 'success' : 'warning');
                discordDesc.textContent = data.discord.token_set ? 'Discord bot configured' : 'Token not set';
            } else {
                discordStatus.className = 'status-light neutral';
                discordDesc.textContent = 'Discord disabled';
            }
        }
        
        // Update Telegram status
        const telegramStatus = document.querySelector('#poracle-telegram-status .status-light');
        const telegramDesc = document.querySelector('#poracle-telegram-status .status-desc');
        if (telegramStatus) {
            if (data.telegram.enabled) {
                telegramStatus.className = 'status-light ' + (data.telegram.token_set ? 'success' : 'warning');
                telegramDesc.textContent = data.telegram.token_set ? 'Telegram bot configured' : 'Token not set';
            } else {
                telegramStatus.className = 'status-light neutral';
                telegramDesc.textContent = 'Telegram disabled';
            }
        }
        
        // Update Webhook status
        const webhookStatus = document.querySelector('#poracle-webhook-status .status-light');
        const webhookDesc = document.querySelector('#poracle-webhook-status .status-desc');
        if (webhookStatus) {
            webhookStatus.className = 'status-light ' + (data.golbat_webhook.configured ? 'success' : 'error');
            webhookDesc.textContent = data.golbat_webhook.configured 
                ? 'Golbat webhook configured'
                : 'Webhook not configured in Golbat';
        }
        
        // Show stats if container is running
        const statsSection = document.getElementById('poracleStats');
        if (statsSection && data.container.running && data.database.connected) {
            statsSection.style.display = 'block';
            document.getElementById('poracleUsers').textContent = data.database.user_count || 0;
            document.getElementById('poracleGeofences').textContent = data.geofences?.count || 0;
        }
        
        // Load recent logs if running
        if (data.container.running) {
            loadPoracleLogs();
        }
        
    } catch (e) {
        console.error('Error loading Poracle status:', e);
        // Set all status lights to error
        document.querySelectorAll('#poracleStatusGrid .status-light').forEach(el => {
            el.className = 'status-light error';
        });
    }
}

async function enablePoracle() {
    try {
        showToast('Enabling Poracle in docker-compose.yaml...', 'info');
        const result = await fetchAPI('/api/poracle/enable', { method: 'POST' });
        
        if (result.success) {
            showToast(result.message, 'success');
            loadPoracleStatus();
        } else {
            showToast(result.message || 'Failed to enable Poracle', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

async function configurePoracleDatabase() {
    try {
        showToast('Configuring Poracle database settings...', 'info');
        const result = await fetchAPI('/api/poracle/configure-database', { method: 'POST' });
        
        if (result.success) {
            showToast(result.message, 'success');
            loadPoracleStatus();
        } else {
            showToast(result.message || 'Failed to configure database', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

async function configurePoracleDiscord() {
    const token = document.getElementById('poracleDiscordToken').value.trim();
    const adminId = document.getElementById('poracleDiscordAdmin').value.trim();
    
    if (!token) {
        showToast('Please enter your Discord bot token', 'warning');
        return;
    }
    
    try {
        showToast('Configuring Discord bot...', 'info');
        const result = await fetchAPI('/api/poracle/configure-discord', {
            method: 'POST',
            body: JSON.stringify({ token, admin_id: adminId })
        });
        
        if (result.success) {
            showToast(result.message, 'success');
            document.getElementById('poracleDiscordToken').value = '';
            loadPoracleStatus();
        } else {
            showToast(result.message || 'Failed to configure Discord', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

async function configurePoracleTelegram() {
    const token = document.getElementById('poracleTelegramToken').value.trim();
    const adminId = document.getElementById('poracleTelegramAdmin').value.trim();
    
    if (!token) {
        showToast('Please enter your Telegram bot token', 'warning');
        return;
    }
    
    try {
        showToast('Configuring Telegram bot...', 'info');
        const result = await fetchAPI('/api/poracle/configure-telegram', {
            method: 'POST',
            body: JSON.stringify({ token, admin_id: adminId })
        });
        
        if (result.success) {
            showToast(result.message, 'success');
            document.getElementById('poracleTelegramToken').value = '';
            loadPoracleStatus();
        } else {
            showToast(result.message || 'Failed to configure Telegram', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

async function addPoracleWebhook() {
    try {
        showToast('Adding Poracle webhook to Golbat...', 'info');
        const result = await fetchAPI('/api/poracle/add-webhook', { method: 'POST' });
        
        if (result.success) {
            showToast(result.message + ' (Restart Golbat to apply)', 'success');
            loadPoracleStatus();
        } else {
            showToast(result.message || 'Failed to add webhook', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

async function importPoracleGeofences() {
    try {
        showToast('Importing geofences from Koji...', 'info');
        const result = await fetchAPI('/api/poracle/import-geofences', { method: 'POST' });
        
        if (result.success) {
            showToast(result.message, 'success');
            loadPoracleStatus();
        } else {
            showToast(result.message || 'Failed to import geofences', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

async function startPoracle() {
    try {
        showToast('Starting Poracle container...', 'info');
        const result = await fetchAPI('/api/poracle/start', { method: 'POST' });
        
        if (result.success) {
            showToast(result.message, 'success');
            setTimeout(loadPoracleStatus, 3000); // Wait for container to start
        } else {
            showToast(result.message || 'Failed to start Poracle', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

async function stopPoracle() {
    try {
        showToast('Stopping Poracle container...', 'info');
        const result = await fetchAPI('/api/poracle/stop', { method: 'POST' });
        
        if (result.success) {
            showToast(result.message, 'success');
            loadPoracleStatus();
        } else {
            showToast(result.message || 'Failed to stop Poracle', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

async function restartPoracle() {
    try {
        showToast('Restarting Poracle container...', 'info');
        const result = await fetchAPI('/api/poracle/restart', { method: 'POST' });
        
        if (result.success) {
            showToast(result.message, 'success');
            setTimeout(loadPoracleStatus, 3000);
        } else {
            showToast(result.message || 'Failed to restart Poracle', 'error');
        }
    } catch (e) {
        showToast('Error: ' + e.message, 'error');
    }
}

async function loadPoracleLogs() {
    const logsEl = document.getElementById('poracleLogsPreview');
    if (!logsEl) return;
    
    try {
        const data = await fetchAPI('/api/container/poracle/logs?lines=20');
        logsEl.textContent = data.logs || 'No logs available';
    } catch (e) {
        logsEl.textContent = 'Failed to load Poracle logs';
    }
}

function togglePasswordVisibility(inputId) {
    const input = document.getElementById(inputId);
    if (input) {
        input.type = input.type === 'password' ? 'text' : 'password';
    }
}

// =============================================================================
// GITHUB MANAGER
// =============================================================================

async function loadGitStatus() {
    const container = document.getElementById('gitRepoStatus');
    if (!container) return;
    
    try {
        const data = await fetchAPI('/api/github/status');
        
        // Update stat card
        const gitStatusEl = document.getElementById('gitStatus');
        const gitStatusIcon = document.getElementById('gitStatusIcon');
        if (gitStatusEl) {
            if (data.behind > 0) {
                gitStatusEl.textContent = `${data.behind} behind`;
                gitStatusEl.className = 'stat-value text-warning';
                if (gitStatusIcon) gitStatusIcon.className = 'stat-icon warning';
            } else {
                gitStatusEl.textContent = 'Up to date';
                gitStatusEl.className = 'stat-value text-success';
                if (gitStatusIcon) gitStatusIcon.className = 'stat-icon success';
            }
        }
        
        if (!data.is_repo) {
            container.innerHTML = '<div class="info-msg">Not a git repository</div>';
            return;
        }
        
        container.innerHTML = `
            <div class="git-info">
                <div class="git-row">
                    <span class="git-label">Branch:</span>
                    <span class="git-value">${data.branch || 'unknown'}</span>
                </div>
                <div class="git-row">
                    <span class="git-label">Commit:</span>
                    <span class="git-value git-commit">${data.commit_short || 'unknown'}</span>
                </div>
                <div class="git-row">
                    <span class="git-label">Message:</span>
                    <span class="git-value">${data.commit_message || 'unknown'}</span>
                </div>
                <div class="git-row">
                    <span class="git-label">Date:</span>
                    <span class="git-value">${data.commit_date ? new Date(data.commit_date).toLocaleString() : 'unknown'}</span>
                </div>
                <div class="git-row">
                    <span class="git-label">Remote:</span>
                    <span class="git-value git-remote">${data.remote_url || 'none'}</span>
                </div>
                ${data.behind > 0 ? `
                <div class="git-update-notice">
                    <span class="update-icon">⬇️</span>
                    <span>${data.behind} update(s) available</span>
                </div>
                ` : ''}
                ${data.has_changes ? `
                <div class="git-changes-notice">
                    <span class="changes-icon">📝</span>
                    <span>Local changes detected</span>
                </div>
                ` : ''}
            </div>
        `;
        
    } catch (e) {
        container.innerHTML = `<div class="error-msg">Failed to load git status: ${e.message}</div>`;
    }
}

async function loadRecentCommits() {
    const container = document.getElementById('recentCommits');
    if (!container) return;
    
    try {
        const data = await fetchAPI('/api/github/commits?limit=5');
        
        if (data.commits && data.commits.length > 0) {
            container.innerHTML = data.commits.map((commit, idx) => `
                <div class="commit-item ${idx === 0 ? 'current' : ''}">
                    <div class="commit-header">
                        <span class="commit-hash">${commit.short_hash}</span>
                        <span class="commit-date">${new Date(commit.date).toLocaleString()}</span>
                    </div>
                    <div class="commit-message">${commit.message}</div>
                    <div class="commit-author">by ${commit.author}</div>
                </div>
            `).join('');
        } else {
            container.innerHTML = '<div class="info-msg">No commits found</div>';
        }
        
    } catch (e) {
        container.innerHTML = `<div class="error-msg">Failed to load commits: ${e.message}</div>`;
    }
}

async function loadChangedFiles() {
    const card = document.getElementById('changedFilesCard');
    const container = document.getElementById('changedFiles');
    const badge = document.getElementById('changesCount');
    if (!container || !card) return;
    
    try {
        const data = await fetchAPI('/api/github/changes');
        
        if (data.changes && data.changes.length > 0) {
            card.style.display = 'block';
            if (badge) badge.textContent = `${data.count} files`;
            
            container.innerHTML = data.changes.map(change => `
                <div class="change-item change-${change.type}">
                    <span class="change-status">${change.status}</span>
                    <span class="change-path">${change.path}</span>
                </div>
            `).join('');
        } else {
            card.style.display = 'none';
        }
        
    } catch (e) {
        card.style.display = 'none';
    }
}

async function gitPullOnly() {
    showToast('Pulling latest changes...', 'info');
    
    try {
        const result = await fetchAPI('/api/github/pull', {
            method: 'POST',
            force: true
        });
        
        if (result.success) {
            showToast('Pull successful! ' + (result.stashed ? '(Local changes preserved)' : ''), 'success');
            loadGitStatus();
            loadRecentCommits();
            loadChangedFiles();
        } else {
            showToast(`Pull failed: ${result.error}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function gitPullAndRestart() {
    showToast('Pulling and restarting Shellder...', 'info');
    
    try {
        const result = await fetchAPI('/api/github/pull-restart', {
            method: 'POST',
            force: true
        });
        
        if (result.success) {
            showToast('Pull and restart complete! Reloading page in 5 seconds...', 'success');
            setTimeout(() => location.reload(), 5000);
        } else {
            showToast(`Failed: ${result.error}`, 'error');
            console.log('Pull restart steps:', result.steps);
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function restartShellder() {
    showToast('Restarting Shellder service...', 'info');
    
    try {
        const result = await fetchAPI('/api/debug/restart', {
            method: 'POST',
            force: true
        });
        
        if (result.success) {
            showToast('Restarting... Page will reload in 5 seconds', 'success');
            setTimeout(() => location.reload(), 5000);
        } else {
            showToast(`Restart failed: ${result.error || 'Unknown error'}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

// =============================================================================
// CONFIG FILES MANAGER
// =============================================================================

async function loadConfigFiles() {
    const container = document.getElementById('configFilesList');
    if (!container) return;
    
    try {
        const data = await fetchAPI('/api/setup/status');
        
        // Group by category
        const categories = {
            'core': { name: 'Core Configuration', files: [] },
            'scanner': { name: 'Scanner Services', files: [] },
            'frontend': { name: 'Frontend', files: [] },
            'database': { name: 'Database', files: [] },
            'optional': { name: 'Optional Services', files: [] }
        };
        
        for (const [path, info] of Object.entries(data.configs)) {
            const category = info.category || 'optional';
            if (categories[category]) {
                categories[category].files.push({ path, ...info });
            }
        }
        
        let html = '';
        for (const [catId, cat] of Object.entries(categories)) {
            if (cat.files.length === 0) continue;
            
            html += `
                <div class="config-category">
                    <h4 class="category-title">${cat.name}</h4>
                    <div class="config-items">
                        ${cat.files.map(file => `
                            <div class="config-item ${file.exists ? '' : 'missing'} ${file.critical ? 'critical' : ''}">
                                <div class="config-status">
                                    ${file.exists ? '✅' : '❌'}
                                </div>
                                <div class="config-info">
                                    <div class="config-name">${file.name}</div>
                                    <div class="config-path">${file.path}</div>
                                    <div class="config-desc">${file.description}</div>
                                </div>
                                <div class="config-actions">
                                    ${file.exists ? `
                                        <button class="btn btn-sm" onclick="editConfigFile('${file.path}')">📝 Edit</button>
                                    ` : file.has_template ? `
                                        <button class="btn btn-sm btn-primary" onclick="createConfigFromTemplate('${file.path}')">➕ Create</button>
                                    ` : `
                                        <span class="text-muted">No template</span>
                                    `}
                                </div>
                            </div>
                        `).join('')}
                    </div>
                </div>
            `;
        }
        
        container.innerHTML = html || '<div class="info-msg">No config files defined</div>';
        
    } catch (e) {
        container.innerHTML = `<div class="error-msg">Failed to load config files: ${e.message}</div>`;
    }
}

// Config editor state
let currentConfigSchema = null;
let configEditorMode = 'form'; // 'form' or 'raw'

async function editConfigFile(path) {
    const panel = document.getElementById('configEditorPanel');
    const title = document.getElementById('configEditorTitle');
    const pathLabel = document.getElementById('configEditorPath');
    const formEditor = document.getElementById('configFormEditor');
    const rawEditor = document.getElementById('configRawEditor');
    const rawContent = document.getElementById('configEditorContent');
    const fieldsContainer = document.getElementById('configFieldsContainer');
    const statusEl = document.getElementById('configEditorStatus');
    
    if (!panel) return;
    
    currentConfigPath = path;
    configEditorMode = 'form';
    
    // Reset UI
    panel.style.display = 'block';
    formEditor.style.display = 'block';
    rawEditor.style.display = 'none';
    document.getElementById('toggleRawBtn').textContent = '📄 Raw Mode';
    
    const configInfo = REQUIRED_CONFIGS_INFO[path] || { name: path };
    title.textContent = `📝 ${configInfo.name || path}`;
    pathLabel.textContent = path;
    fieldsContainer.innerHTML = '<div class="loading">Loading...</div>';
    statusEl.textContent = '';
    
    try {
        // First, try to get schema for form-based editing
        const schemaResponse = await fetch(`/api/config/schema/${encodeURIComponent(path)}`);
        const schemaData = await schemaResponse.json();
        
        // Also load the raw content
        const fileData = await fetchAPI(`/api/config/file?path=${encodeURIComponent(path)}`);
        rawContent.value = fileData.content || '';
        
        if (schemaData.has_schema) {
            currentConfigSchema = schemaData;
            renderConfigForm(schemaData);
            statusEl.textContent = fileData.is_template ? '⚠️ From template - save to create file' : `✅ File exists`;
        } else {
            // No schema - show raw editor
            currentConfigSchema = null;
            fieldsContainer.innerHTML = `
                <div class="no-schema-notice">
                    <p>📝 This config file doesn't have a structured editor.</p>
                    <p>Use Raw Mode to edit directly.</p>
                    <button class="btn btn-primary btn-sm" onclick="toggleRawEditor()">Open Raw Editor</button>
                </div>
            `;
            statusEl.textContent = fileData.is_template ? '⚠️ From template' : '✅ File exists';
        }
        
        // Show webhooks section for Golbat config
        const webhooksSection = document.getElementById('webhooksSection');
        if (webhooksSection) {
            if (path === 'unown/golbat_config.toml') {
                webhooksSection.style.display = 'block';
                loadWebhooks();
            } else {
                webhooksSection.style.display = 'none';
            }
        }
        
        // Scroll to editor
        panel.scrollIntoView({ behavior: 'smooth' });
        
    } catch (e) {
        fieldsContainer.innerHTML = `<div class="error-msg">Error loading config: ${e.message}</div>`;
    }
}

function renderConfigForm(schemaData) {
    const container = document.getElementById('configFieldsContainer');
    const values = schemaData.current_values || {};
    const sharedFields = schemaData.shared_fields || {};
    
    // Add legend for shared fields
    let legendHtml = '';
    const usedSharedKeys = new Set();
    for (const fieldPath of Object.keys(sharedFields)) {
        usedSharedKeys.add(sharedFields[fieldPath].key);
    }
    
    if (usedSharedKeys.size > 0) {
        legendHtml = `
            <div class="shared-fields-legend">
                <div class="legend-title">🔗 Shared Field Indicators</div>
                <div class="legend-items">
                    ${Array.from(usedSharedKeys).map(key => {
                        const info = schemaData.all_shared_definitions[key];
                        if (!info) return '';
                        return `
                            <div class="legend-item">
                                <span class="shared-indicator" style="background: ${info.color};"></span>
                                <span class="legend-label">${info.label}</span>
                                <span class="legend-count">(${info.configs.length} configs)</span>
                            </div>
                        `;
                    }).join('')}
                </div>
                <div class="legend-hint">💡 Fields with indicators are shared across multiple config files. Use "Sync All" to update all configs at once.</div>
            </div>
        `;
    }
    
    let html = legendHtml;
    for (const [sectionKey, section] of Object.entries(schemaData.sections)) {
        // Navigate nested path for section keys like 'db.dragonite'
        let sectionValues = values;
        for (const part of sectionKey.split('.')) {
            sectionValues = sectionValues?.[part] || {};
        }
        
        html += `
            <div class="config-section" id="config-section-${sectionKey}">
                <div class="config-section-header" onclick="toggleConfigSection('${sectionKey}')">
                    <h4>${section.title}</h4>
                    ${section.desc ? `<span class="section-desc">${section.desc}</span>` : ''}
                    <span class="config-section-toggle">▼</span>
                </div>
                <div class="config-section-fields">
                    ${Object.entries(section.fields).map(([fieldKey, field]) => {
                        const currentValue = sectionValues[fieldKey] ?? field.default ?? '';
                        const sharedInfo = sharedFields[`${sectionKey}.${fieldKey}`] || null;
                        return renderConfigField(sectionKey, fieldKey, field, currentValue, sharedInfo);
                    }).join('')}
                </div>
            </div>
        `;
    }
    
    container.innerHTML = html;
}

function renderConfigField(section, key, field, value, sharedInfo = null) {
    const inputId = `config-${section}-${key}`;
    let inputHtml = '';
    
    // Check if this is an optional field using default (commented out in config)
    const isUsingDefault = field.optional && (value === undefined || value === null || value === '');
    const displayValue = isUsingDefault ? '' : value;
    const placeholderText = field.default !== undefined ? `Default: ${field.default}` : '';
    
    // Optional field indicator
    const optionalBadge = field.optional ? `<span class="optional-badge" title="Optional - leave empty to use default">optional</span>` : '';
    const usingDefaultBadge = isUsingDefault ? `<span class="using-default-badge" title="Currently commented out, using default value">using default</span>` : '';
    
    if (field.type === 'checkbox') {
        const isChecked = isUsingDefault ? field.default : value;
        inputHtml = `
            <label class="checkbox-label">
                <input type="checkbox" id="${inputId}" ${isChecked ? 'checked' : ''} data-optional="${field.optional || false}" data-default="${field.default}">
                <span>Enabled</span>
                ${usingDefaultBadge}
            </label>
        `;
    } else if (field.type === 'password') {
        inputHtml = `
            <div class="input-with-action">
                <input type="password" id="${inputId}" value="${escapeHtml(String(displayValue))}" placeholder="${placeholderText}" data-optional="${field.optional || false}" data-default="${field.default || ''}">
                <button class="btn btn-xs" onclick="toggleFieldVisibility('${inputId}')" title="Show/Hide">👁️</button>
                <button class="btn btn-xs" onclick="generateFieldValue('${inputId}')" title="Generate random">🎲</button>
                ${sharedInfo ? `<button class="btn btn-xs btn-sync" onclick="syncSharedField('${inputId}', '${sharedInfo.key}')" title="Sync to ${sharedInfo.total_configs} configs" style="background: ${sharedInfo.color}22; border-color: ${sharedInfo.color};">🔄 Sync All</button>` : ''}
            </div>
        `;
    } else if (field.type === 'number') {
        inputHtml = `
            <div class="input-with-action">
                <input type="number" id="${inputId}" value="${isUsingDefault ? '' : displayValue}" placeholder="${placeholderText}" style="flex:1;" data-optional="${field.optional || false}" data-default="${field.default || 0}">
                ${usingDefaultBadge}
                ${sharedInfo ? `<button class="btn btn-xs btn-sync" onclick="syncSharedField('${inputId}', '${sharedInfo.key}')" title="Sync to ${sharedInfo.total_configs} configs" style="background: ${sharedInfo.color}22; border-color: ${sharedInfo.color};">🔄 Sync All</button>` : ''}
            </div>
        `;
    } else {
        inputHtml = `
            <div class="input-with-action">
                <input type="text" id="${inputId}" value="${escapeHtml(String(displayValue))}" placeholder="${placeholderText}" style="flex:1;" data-optional="${field.optional || false}" data-default="${field.default || ''}">
                ${usingDefaultBadge}
                ${sharedInfo ? `<button class="btn btn-xs btn-sync" onclick="syncSharedField('${inputId}', '${sharedInfo.key}')" title="Sync to ${sharedInfo.total_configs} configs" style="background: ${sharedInfo.color}22; border-color: ${sharedInfo.color};">🔄 Sync All</button>` : ''}
            </div>
        `;
    }
    
    // Shared field indicator
    let sharedIndicator = '';
    if (sharedInfo) {
        const otherConfigs = sharedInfo.other_configs.map(c => c.split('/').pop()).join(', ');
        sharedIndicator = `
            <div class="shared-field-badge" style="border-color: ${sharedInfo.color}; color: ${sharedInfo.color};" title="Also in: ${otherConfigs}">
                <span class="shared-indicator" style="background: ${sharedInfo.color};"></span>
                <span class="shared-label">${sharedInfo.label}</span>
                <span class="shared-count">${sharedInfo.total_configs} configs</span>
            </div>
        `;
    }
    
    return `
        <div class="config-field ${sharedInfo ? 'has-shared' : ''} ${field.optional ? 'is-optional' : ''} ${isUsingDefault ? 'using-default' : ''}">
            <div class="config-field-info">
                <div class="config-field-label-row">
                    <span class="config-field-label">${field.label}</span>
                    ${optionalBadge}
                    ${sharedIndicator}
                </div>
                <div class="config-field-desc">${field.desc}</div>
            </div>
            <div class="config-field-input">
                ${inputHtml}
            </div>
        </div>
    `;
}

// Sync a shared field value across all configs
async function syncSharedField(inputId, sharedKey) {
    const input = document.getElementById(inputId);
    if (!input) return;
    
    const value = input.type === 'checkbox' ? input.checked : input.value;
    
    if (!value && input.type !== 'checkbox') {
        showToast('Please enter a value before syncing', 'warning');
        return;
    }
    
    // Confirm sync
    const confirmed = confirm(`Sync this value to ALL configs that use "${sharedKey}"?\n\nThis will update multiple config files.`);
    if (!confirmed) return;
    
    showToast('Syncing to all configs...', 'info');
    
    try {
        const result = await fetchAPI('/api/config/sync-field', {
            method: 'POST',
            body: JSON.stringify({
                shared_key: sharedKey,
                value: value,
                source_config: currentConfigPath
            }),
            force: true
        });
        
        if (result.success) {
            const successCount = result.results.filter(r => r.status === 'success').length;
            const skipCount = result.results.filter(r => r.status === 'skipped').length;
            const errorCount = result.results.filter(r => r.status === 'error').length;
            
            let message = `Synced to ${successCount} configs`;
            if (skipCount > 0) message += `, ${skipCount} skipped`;
            if (errorCount > 0) message += `, ${errorCount} errors`;
            
            showToast(message, errorCount > 0 ? 'warning' : 'success');
            
            // Show details in console
            console.log('Sync results:', result.results);
            
            // Refresh config list
            loadConfigFiles();
            loadSetupStatus();
        } else {
            showToast(`Sync failed: ${result.error}`, 'error');
        }
    } catch (e) {
        showToast(`Sync error: ${e.message}`, 'error');
    }
}

function toggleConfigSection(sectionKey) {
    const section = document.getElementById(`config-section-${sectionKey}`);
    if (section) {
        section.classList.toggle('collapsed');
    }
}

function toggleFieldVisibility(inputId) {
    const input = document.getElementById(inputId);
    if (input) {
        input.type = input.type === 'password' ? 'text' : 'password';
    }
}

function generateFieldValue(inputId) {
    const input = document.getElementById(inputId);
    if (!input) return;
    
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    const value = Array.from(crypto.getRandomValues(new Uint8Array(24)))
        .map(b => chars[b % chars.length]).join('');
    
    input.value = value;
    input.type = 'text';
    showToast('Generated random value', 'success');
}

function toggleRawEditor() {
    const formEditor = document.getElementById('configFormEditor');
    const rawEditor = document.getElementById('configRawEditor');
    const toggleBtn = document.getElementById('toggleRawBtn');
    
    if (configEditorMode === 'form') {
        // Switch to raw mode - first collect form values and update raw content
        if (currentConfigSchema) {
            updateRawFromForm();
        }
        formEditor.style.display = 'none';
        rawEditor.style.display = 'block';
        toggleBtn.textContent = '📋 Form Mode';
        configEditorMode = 'raw';
    } else {
        formEditor.style.display = 'block';
        rawEditor.style.display = 'none';
        toggleBtn.textContent = '📄 Raw Mode';
        configEditorMode = 'form';
    }
}

function updateRawFromForm() {
    if (!currentConfigSchema) return;
    
    const values = collectFormValues();
    const rawContent = document.getElementById('configEditorContent');
    
    if (currentConfigSchema.format === 'json') {
        rawContent.value = JSON.stringify(values, null, 2);
    } else if (currentConfigSchema.format === 'toml') {
        // Generate TOML
        let toml = '# Generated by Shellder Config Editor\\n\\n';
        for (const [sectionKey, sectionValues] of Object.entries(values)) {
            toml += `[${sectionKey}]\\n`;
            for (const [key, value] of Object.entries(sectionValues)) {
                if (typeof value === 'string') {
                    toml += `${key} = "${value}"\\n`;
                } else if (typeof value === 'boolean') {
                    toml += `${key} = ${value}\\n`;
                } else {
                    toml += `${key} = ${value}\\n`;
                }
            }
            toml += '\\n';
        }
        rawContent.value = toml;
    }
}

function collectFormValues() {
    if (!currentConfigSchema) return {};
    
    const values = {};
    for (const [sectionKey, section] of Object.entries(currentConfigSchema.sections)) {
        // Create nested structure for section keys like 'db.dragonite'
        const parts = sectionKey.split('.');
        let current = values;
        for (let i = 0; i < parts.length; i++) {
            if (i === parts.length - 1) {
                // Last part - create the section object
                current[parts[i]] = current[parts[i]] || {};
                current = current[parts[i]];
            } else {
                // Intermediate part - navigate or create
                current[parts[i]] = current[parts[i]] || {};
                current = current[parts[i]];
            }
        }
        
        for (const [fieldKey, field] of Object.entries(section.fields)) {
            const input = document.getElementById(`config-${sectionKey}-${fieldKey}`);
            if (input) {
                const isOptional = input.dataset.optional === 'true';
                
                if (field.type === 'checkbox') {
                    // For optional checkboxes, skip if matches default
                    const checked = input.checked;
                    if (isOptional && checked === (field.default === true)) {
                        // Skip - using default
                        continue;
                    }
                    current[fieldKey] = checked;
                } else if (field.type === 'number') {
                    const numValue = input.value.trim();
                    // For optional numbers, skip if empty (using default)
                    if (isOptional && numValue === '') {
                        continue;
                    }
                    current[fieldKey] = parseFloat(numValue) || 0;
                } else {
                    const strValue = input.value;
                    // For optional strings, skip if empty (using default)
                    if (isOptional && strValue === '') {
                        continue;
                    }
                    current[fieldKey] = strValue;
                }
            }
        }
    }
    return values;
}

async function saveConfigFile() {
    if (!currentConfigPath) {
        showToast('No file selected', 'warning');
        return;
    }
    
    showToast('Saving...', 'info');
    
    try {
        let result;
        
        if (configEditorMode === 'form' && currentConfigSchema) {
            // Save from form
            const values = collectFormValues();
            result = await fetchAPI('/api/config/structured', {
                method: 'POST',
                body: JSON.stringify({
                    path: currentConfigPath,
                    values: values
                }),
                force: true
            });
        } else {
            // Save raw content
            const editor = document.getElementById('configEditorContent');
            result = await fetchAPI('/api/config/file', {
            method: 'POST',
            body: JSON.stringify({
                path: currentConfigPath,
                content: editor.value
            }),
            force: true
        });
        }
        
        if (result.success) {
            showToast(`${currentConfigPath} saved successfully`, 'success');
            loadConfigFiles();
            loadSetupStatus();
        } else {
            showToast(`Save failed: ${result.error}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

function closeConfigEditor() {
    const panel = document.getElementById('configEditorPanel');
    if (panel) panel.style.display = 'none';
    currentConfigPath = null;
    currentConfigSchema = null;
    
    // Hide webhooks section
    const webhooksSection = document.getElementById('webhooksSection');
    if (webhooksSection) webhooksSection.style.display = 'none';
}


// =============================================================================
// GOLBAT WEBHOOK MANAGEMENT
// =============================================================================

let availableWebhookTypes = [];

async function loadWebhooks() {
    const list = document.getElementById('webhooksList');
    if (!list) return;
    
    list.innerHTML = '<div class="loading">Loading webhooks...</div>';
    
    try {
        const data = await fetchAPI('/api/config/golbat/webhooks');
        availableWebhookTypes = data.available_types || [];
        
        if (!data.webhooks || data.webhooks.length === 0) {
            list.innerHTML = `
                <div class="webhooks-empty">
                    <div class="empty-icon">📭</div>
                    <div class="empty-text">No webhooks configured</div>
                    <div class="empty-hint">Click "Add Webhook" to send data to external services like Poracle</div>
                </div>
            `;
            return;
        }
        
        list.innerHTML = data.webhooks.map((webhook, index) => renderWebhookCard(webhook, index)).join('');
    } catch (e) {
        list.innerHTML = `<div class="error-msg">Error loading webhooks: ${e.message}</div>`;
    }
}

function renderWebhookCard(webhook, index) {
    const url = webhook.url || '';
    const types = webhook.types || [];
    const areas = webhook.areas || [];
    
    // Determine service name from URL
    let serviceName = 'Webhook';
    let serviceIcon = '🔔';
    if (url.includes('poracle')) {
        serviceName = 'Poracle';
        serviceIcon = '📢';
    } else if (url.includes('fletchling')) {
        serviceName = 'Fletchling';
        serviceIcon = '🐦';
    }
    
    const typeBadges = types.map(t => {
        const typeInfo = availableWebhookTypes.find(at => at.id === t) || { label: t };
        return `<span class="webhook-type-badge">${typeInfo.label}</span>`;
    }).join('');
    
    const areaText = areas.length > 0 
        ? `<div class="webhook-areas">📍 Areas: ${areas.join(', ')}</div>` 
        : '';
    
    return `
        <div class="webhook-card">
            <div class="webhook-card-header">
                <span class="webhook-service">${serviceIcon} ${serviceName}</span>
                <div class="webhook-actions">
                    <button class="btn btn-xs" onclick="editWebhook(${index})" title="Edit">✏️</button>
                    <button class="btn btn-xs btn-danger" onclick="deleteWebhook(${index})" title="Delete">🗑️</button>
                </div>
            </div>
            <div class="webhook-url">
                <code>${escapeHtml(url)}</code>
            </div>
            <div class="webhook-types">
                ${typeBadges}
            </div>
            ${areaText}
        </div>
    `;
}

function showWebhookModal(editIndex = -1) {
    const modal = document.getElementById('webhookModal');
    const title = document.getElementById('webhookModalTitle');
    const indexInput = document.getElementById('webhookEditIndex');
    const urlInput = document.getElementById('webhookUrl');
    const areasInput = document.getElementById('webhookAreas');
    const typesGrid = document.getElementById('webhookTypesGrid');
    
    // Reset
    indexInput.value = editIndex;
    urlInput.value = '';
    areasInput.value = '';
    
    // Render type checkboxes
    typesGrid.innerHTML = availableWebhookTypes.map(type => `
        <label class="webhook-type-checkbox">
            <input type="checkbox" name="webhookType" value="${type.id}">
            <span class="type-label">${type.label}</span>
            <span class="type-desc">${type.desc}</span>
        </label>
    `).join('');
    
    if (editIndex >= 0) {
        title.textContent = '✏️ Edit Webhook';
        // Load existing webhook data
        fetchAPI('/api/config/golbat/webhooks').then(data => {
            const webhook = data.webhooks[editIndex];
            if (webhook) {
                urlInput.value = webhook.url || '';
                areasInput.value = (webhook.areas || []).join(', ');
                
                // Check the types
                (webhook.types || []).forEach(t => {
                    const checkbox = typesGrid.querySelector(`input[value="${t}"]`);
                    if (checkbox) checkbox.checked = true;
                });
            }
        });
    } else {
        title.textContent = '🔔 Add Webhook';
    }
    
    modal.classList.add('active');
}

function closeWebhookModal() {
    document.getElementById('webhookModal').classList.remove('active');
}

function applyWebhookPreset(preset) {
    const urlInput = document.getElementById('webhookUrl');
    const typesGrid = document.getElementById('webhookTypesGrid');
    
    // Uncheck all first
    typesGrid.querySelectorAll('input[type="checkbox"]').forEach(cb => cb.checked = false);
    
    switch (preset) {
        case 'poracle':
            urlInput.value = 'http://poracle:3030';
            ['pokemon', 'pokemon_iv', 'pokemon_no_iv', 'gym', 'raid', 'quest', 'invasion', 'weather'].forEach(t => {
                const cb = typesGrid.querySelector(`input[value="${t}"]`);
                if (cb) cb.checked = true;
            });
            break;
        case 'pokemon-only':
            ['pokemon', 'pokemon_iv', 'pokemon_no_iv'].forEach(t => {
                const cb = typesGrid.querySelector(`input[value="${t}"]`);
                if (cb) cb.checked = true;
            });
            break;
        case 'raids-only':
            ['raid', 'gym'].forEach(t => {
                const cb = typesGrid.querySelector(`input[value="${t}"]`);
                if (cb) cb.checked = true;
            });
            break;
        case 'fletchling':
            urlInput.value = 'http://fletchling:9042/webhook';
            const pokemonIv = typesGrid.querySelector('input[value="pokemon_iv"]');
            if (pokemonIv) pokemonIv.checked = true;
            break;
    }
    
    showToast(`Applied ${preset} preset`, 'info');
}

async function saveWebhook() {
    const indexInput = document.getElementById('webhookEditIndex');
    const urlInput = document.getElementById('webhookUrl');
    const areasInput = document.getElementById('webhookAreas');
    const typesGrid = document.getElementById('webhookTypesGrid');
    
    const editIndex = parseInt(indexInput.value);
    const url = urlInput.value.trim();
    
    // Collect selected types
    const types = [];
    typesGrid.querySelectorAll('input[type="checkbox"]:checked').forEach(cb => {
        types.push(cb.value);
    });
    
    // Parse areas
    const areas = areasInput.value.split(',')
        .map(a => a.trim())
        .filter(a => a.length > 0);
    
    if (!url) {
        showToast('Please enter a webhook URL', 'warning');
        return;
    }
    
    if (types.length === 0) {
        showToast('Please select at least one data type', 'warning');
        return;
    }
    
    showToast('Saving webhook...', 'info');
    
    try {
        let result;
        const payload = { url, types, areas };
        
        if (editIndex >= 0) {
            result = await fetchAPI(`/api/config/golbat/webhooks/${editIndex}`, {
                method: 'PUT',
                body: JSON.stringify(payload)
            });
        } else {
            result = await fetchAPI('/api/config/golbat/webhooks', {
                method: 'POST',
                body: JSON.stringify(payload)
            });
        }
        
        if (result.success) {
            showToast('✅ Webhook saved! Restart Golbat to apply changes.', 'success');
            closeWebhookModal();
            loadWebhooks();
        } else {
            showToast(`❌ Error: ${result.error}`, 'error');
        }
    } catch (e) {
        showToast(`❌ Error: ${e.message}`, 'error');
    }
}

function editWebhook(index) {
    showWebhookModal(index);
}

async function deleteWebhook(index) {
    if (!confirm('Delete this webhook? This cannot be undone.')) return;
    
    showToast('Deleting webhook...', 'info');
    
    try {
        const result = await fetchAPI(`/api/config/golbat/webhooks/${index}`, {
            method: 'DELETE'
        });
        
        if (result.success) {
            showToast('✅ Webhook deleted! Restart Golbat to apply changes.', 'success');
            loadWebhooks();
        } else {
            showToast(`❌ Error: ${result.error}`, 'error');
        }
    } catch (e) {
        showToast(`❌ Error: ${e.message}`, 'error');
    }
}

// Config file info lookup (for display names)
const REQUIRED_CONFIGS_INFO = {
    '.env': { name: 'Environment Variables' },
    'docker-compose.yaml': { name: 'Docker Compose' },
    'unown/dragonite_config.toml': { name: 'Dragonite Config' },
    'unown/golbat_config.toml': { name: 'Golbat Config' },
    'unown/rotom_config.json': { name: 'Rotom Config' },
    'reactmap/local.json': { name: 'ReactMap Config' },
    'mysql_data/mariadb.cnf': { name: 'MariaDB Config' },
};

async function createConfigFromTemplate(path) {
    showToast(`Creating ${path} from template...`, 'info');
    
    try {
        const result = await fetchAPI('/api/config/create-from-template', {
            method: 'POST',
            body: JSON.stringify({ path }),
            force: true
        });
        
        if (result.success) {
            showToast(`${path} created successfully`, 'success');
            loadConfigFiles();
            loadSetupStatus();
            editConfigFile(path);  // Open for editing
        } else {
            showToast(`Failed: ${result.error}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

// =============================================================================
// CONFIG VARIABLES STATUS
// =============================================================================

async function loadConfigVariablesStatus() {
    const container = document.getElementById('configVarsCategories');
    if (!container) return;
    
    container.innerHTML = '<div class="loading">Loading configuration status...</div>';
    
    try {
        const data = await fetchAPI('/api/config/variables-status');
        
        // Update summary stats (using new API format)
        const totalEl = document.getElementById('configVarsTotal');
        const configuredEl = document.getElementById('configVarsConfigured');
        const missingEl = document.getElementById('configVarsMissing');
        const syncedEl = document.getElementById('configVarsSynced');
        const mismatchedEl = document.getElementById('configVarsMismatched');
        
        if (totalEl) totalEl.textContent = data.summary.total || 0;
        if (configuredEl) configuredEl.textContent = data.summary.configured || 0;
        if (missingEl) missingEl.textContent = data.summary.not_configured || 0;
        if (syncedEl) syncedEl.textContent = data.summary.synced || 0;
        if (mismatchedEl) mismatchedEl.textContent = data.summary.mismatched || 0;
        
        // Group variables into categories
        const dbVars = [];
        const secretVars = [];
        
        for (const [varName, varInfo] of Object.entries(data.variables || {})) {
            if (varName.startsWith('MYSQL')) {
                dbVars.push([varName, varInfo]);
            } else {
                secretVars.push([varName, varInfo]);
            }
        }
        
        let html = '';
        
        // Database category
        if (dbVars.length > 0) {
            const configuredCount = dbVars.filter(([_, v]) => v.is_configured).length;
            const mismatchCount = dbVars.filter(([_, v]) => v.sync_status === 'mismatch').length;
            const notConfiguredCount = dbVars.filter(([_, v]) => v.sync_status === 'not_configured').length;
            
            html += `
                <div class="config-var-category" data-category="database">
                    <div class="config-var-category-header" onclick="toggleConfigCategory('database')">
                        <h4>🗄️ Database Credentials</h4>
                        <div class="category-stats">
                            <span class="stat ok">${configuredCount}/${dbVars.length} set</span>
                            ${notConfiguredCount > 0 ? `<span class="stat warn">${notConfiguredCount} unconfigured</span>` : ''}
                            ${mismatchCount > 0 ? `<span class="stat error">${mismatchCount} mismatch</span>` : ''}
                        </div>
                    </div>
                    <div class="config-var-category-body show" id="category-body-database">
            `;
            
            for (const [varName, varInfo] of dbVars) {
                html += renderConfigVarItem(varName, varInfo);
            }
            
            html += '</div></div>';
        }
        
        // Service Secrets category
        if (secretVars.length > 0) {
            const configuredCount = secretVars.filter(([_, v]) => v.is_configured).length;
            const mismatchCount = secretVars.filter(([_, v]) => v.sync_status === 'mismatch').length;
            const notConfiguredCount = secretVars.filter(([_, v]) => v.sync_status === 'not_configured').length;
            
            html += `
                <div class="config-var-category" data-category="secrets">
                    <div class="config-var-category-header" onclick="toggleConfigCategory('secrets')">
                        <h4>🔐 Service Secrets</h4>
                        <div class="category-stats">
                            <span class="stat ok">${configuredCount}/${secretVars.length} set</span>
                            ${notConfiguredCount > 0 ? `<span class="stat warn">${notConfiguredCount} unconfigured</span>` : ''}
                            ${mismatchCount > 0 ? `<span class="stat error">${mismatchCount} mismatch</span>` : ''}
                        </div>
                    </div>
                    <div class="config-var-category-body show" id="category-body-secrets">
            `;
            
            for (const [varName, varInfo] of secretVars) {
                html += renderConfigVarItem(varName, varInfo);
            }
            
            html += '</div></div>';
        }
        
        container.innerHTML = html;
        
    } catch (e) {
        console.error('Failed to load config variables status:', e);
        container.innerHTML = `<div class="error-message">Failed to load: ${e.message}</div>`;
    }
}

function renderConfigVarItem(varName, varInfo) {
    // Determine status indicator
    let statusClass = 'empty';
    let statusTitle = 'Not configured';
    
    if (varInfo.sync_status === 'synced') {
        statusClass = 'synced';
        statusTitle = 'Configured and synced across all configs';
    } else if (varInfo.sync_status === 'mismatch') {
        statusClass = 'mismatch';
        statusTitle = 'Values do not match across config files';
    } else if (varInfo.sync_status === 'not_configured') {
        statusClass = 'missing';
        statusTitle = 'Still at default placeholder - must be configured';
    }
    
    // Files where this variable is used
    const configFiles = Object.keys(varInfo.configs || {}).filter(f => varInfo.configs[f].status === 'ok');
    const sharedBadge = configFiles.length > 1 ? `<span class="shared-badge" title="Used in ${configFiles.length} configs">🔗 ${configFiles.length} files</span>` : '';
    
    let html = `
        <div class="config-var-item" data-var="${varName}">
            <div class="config-var-status ${statusClass}" title="${statusTitle}"></div>
            <div class="config-var-label">
                ${varInfo.label || varName}
                ${sharedBadge}
            </div>
            <div class="config-var-value secret">
                ${varInfo.is_configured ? '••••••••' : '<span class="empty">(default)</span>'}
            </div>
    `;
    
    // Show sync details for mismatched or not_configured variables (expanded)
    if (varInfo.sync_status === 'mismatch' || (varInfo.sync_status === 'not_configured' && Object.keys(varInfo.configs || {}).length > 0)) {
        html += `
            <div class="config-var-sync-details">
                <strong>${varInfo.sync_status === 'mismatch' ? '⚠️ Values don\'t match:' : '📋 Config files using this secret:'}</strong>
                ${Object.entries(varInfo.configs || {}).map(([file, info]) => {
                    const statusIcon = info.is_default ? '⏸️' : (info.status === 'ok' ? '✅' : '❌');
                    const valueText = info.is_default ? 'default' : (info.status === 'ok' ? '•••' : info.status);
                    return `
                        <div class="sync-row">
                            <span class="sync-file">${file}</span>
                            <span class="sync-value">${statusIcon} ${valueText}</span>
                        </div>
                    `;
                }).join('')}
                ${varInfo.sync_status === 'mismatch' ? `
                    <button class="btn btn-xs btn-warning" style="margin-top: 8px;" 
                            onclick="syncConfigVariable('${varName}')">
                        🔄 Sync All to Match
                    </button>
                ` : ''}
            </div>
        `;
    }
    
    html += `</div>`;
    return html;
}

function getStatusTitle(status) {
    const titles = {
        'synced': 'All configs have matching values',
        'mismatch': 'Values differ across configs - click to see details',
        'set': 'Value is configured',
        'missing': 'Required value is not set',
        'empty': 'Optional value not set'
    };
    return titles[status] || '';
}

function truncateValue(val) {
    if (!val) return '';
    const str = String(val);
    return str.length > 30 ? str.substring(0, 30) + '...' : str;
}

function toggleConfigCategory(catKey) {
    const body = document.getElementById(`category-body-${catKey}`);
    if (body) {
        body.style.display = body.style.display === 'none' ? 'block' : 'none';
    }
}

async function syncConfigVariable(varName) {
    // Get the .env value and sync it to all configs
    try {
        const response = await fetch('/api/config/variables-status');
        const data = await response.json();
        
        if (!data.shared_sync[varName]) {
            showToast('Variable not found', 'error');
            return;
        }
        
        // Get the value from .env as the source of truth
        const envValue = data.shared_sync[varName].values['.env'];
        if (!envValue) {
            showToast('No value in .env to sync from', 'warning');
            return;
        }
        
        showToast(`Syncing ${varName} across all configs...`, 'info');
        
        // Use the existing sync endpoint
        const syncResponse = await fetch('/api/config/sync-field', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                shared_key: varName.toLowerCase().replace(/_/g, '_'),
                value: envValue,
                source_config: '.env'
            })
        });
        
        if (syncResponse.ok) {
            showToast(`${varName} synced successfully!`, 'success');
            loadConfigVariablesStatus();
        } else {
            const err = await syncResponse.json();
            showToast(`Sync failed: ${err.error}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

// =============================================================================
// ENVIRONMENT VARIABLES MANAGER (Legacy)
// =============================================================================

async function loadEnvVars() {
    const container = document.getElementById('envVarsList');
    if (!container) return;
    
    try {
        const data = await fetchAPI('/api/config/env');
        
        // Group by category
        const categories = {
            'system': { name: '🖥️ System', vars: [] },
            'database': { name: '🗄️ Database', vars: [] },
            'api': { name: '🔑 API Secrets', vars: [] },
            'custom': { name: '📋 Custom', vars: [] }
        };
        
        for (const [name, info] of Object.entries(data.variables)) {
            const category = info.category || 'custom';
            if (categories[category]) {
                categories[category].vars.push({ name, ...info });
            }
        }
        
        let html = '';
        for (const [catId, cat] of Object.entries(categories)) {
            if (cat.vars.length === 0) continue;
            
            html += `
                <div class="env-category">
                    <h4 class="category-title">${cat.name}</h4>
                    <div class="env-items">
                        ${cat.vars.map(v => `
                            <div class="env-item ${v.missing ? 'missing' : ''} ${v.is_secret ? 'secret' : ''}">
                                <div class="env-info">
                                    <div class="env-name">${v.name}</div>
                                    <div class="env-desc">${v.description}</div>
                                </div>
                                <div class="env-value">
                                    <input type="${v.is_secret ? 'password' : 'text'}" 
                                           class="form-input env-input" 
                                           id="env-${v.name}"
                                           value="${v.value || ''}"
                                           placeholder="${v.missing ? 'Not set' : ''}">
                                    ${v.is_secret ? `
                                        <button class="btn btn-xs" onclick="toggleEnvVisibility('${v.name}')">👁️</button>
                                    ` : ''}
                                </div>
                            </div>
                        `).join('')}
                    </div>
                </div>
            `;
        }
        
        container.innerHTML = html || '<div class="info-msg">No environment file found</div>';
        
    } catch (e) {
        container.innerHTML = `<div class="error-msg">Failed to load environment variables: ${e.message}</div>`;
    }
}

function toggleEnvVisibility(name) {
    const input = document.getElementById(`env-${name}`);
    if (input) {
        input.type = input.type === 'password' ? 'text' : 'password';
    }
}

async function saveEnvVars() {
    // Collect all env values
    const variables = {};
    document.querySelectorAll('.env-input').forEach(input => {
        const name = input.id.replace('env-', '');
        const value = input.value;
        if (value) {
            variables[name] = value;
        }
    });
    
    if (Object.keys(variables).length === 0) {
        showToast('No changes to save', 'info');
        return;
    }
    
    showToast('Saving environment variables...', 'info');
    
    try {
        const result = await fetchAPI('/api/config/env', {
            method: 'POST',
            body: JSON.stringify({ variables }),
            force: true
        });
        
        if (result.success) {
            showToast(`Saved ${result.updated.length} variables. Restart containers for changes to take effect.`, 'success');
            loadEnvVars();
            loadSetupStatus();
        } else {
            showToast(`Save failed: ${result.error}`, 'error');
        }
    } catch (e) {
        showToast(`Error: ${e.message}`, 'error');
    }
}

// =============================================================================
// SETUP SCRIPTS
// =============================================================================

// =============================================================================
// INTERACTIVE TERMINAL FOR SCRIPTS (xterm.js)
// =============================================================================

let terminal = null;
let terminalFitAddon = null;
let currentSessionId = null;

async function runSetupScript(script) {
    const terminalCard = document.getElementById('scriptTerminalCard');
    const terminalTitle = document.getElementById('scriptTerminalTitle');
    const terminalContainer = document.getElementById('terminalContainer');
    const terminalStatus = document.getElementById('terminalStatus');
    
    if (!terminalCard || !terminalContainer) {
        showToast('Terminal container not found', 'error');
        return;
    }
    
    // Show terminal card
    terminalCard.style.display = 'block';
    terminalTitle.textContent = `🖥️ Running: ${script}`;
    terminalStatus.textContent = 'Connecting...';
    terminalStatus.className = 'terminal-status connecting';
    
    // Scroll to terminal
    terminalCard.scrollIntoView({ behavior: 'smooth' });
    
    // Initialize xterm.js if not already done
    if (!terminal) {
        terminal = new Terminal({
            cursorBlink: true,
            cursorStyle: 'block',
            fontSize: 14,
            fontFamily: '"JetBrains Mono", "Fira Code", monospace',
            theme: {
                background: '#1a1d23',
                foreground: '#e4e4e7',
                cursor: '#f59e0b',
                cursorAccent: '#1a1d23',
                selectionBackground: '#3b82f6',
                black: '#1a1d23',
                red: '#ef4444',
                green: '#22c55e',
                yellow: '#f59e0b',
                blue: '#3b82f6',
                magenta: '#a855f7',
                cyan: '#06b6d4',
                white: '#e4e4e7',
                brightBlack: '#4b5563',
                brightRed: '#f87171',
                brightGreen: '#4ade80',
                brightYellow: '#fbbf24',
                brightBlue: '#60a5fa',
                brightMagenta: '#c084fc',
                brightCyan: '#22d3ee',
                brightWhite: '#ffffff'
            },
            scrollback: 5000,
            convertEol: true
        });
        
        terminalFitAddon = new FitAddon.FitAddon();
        terminal.loadAddon(terminalFitAddon);
        terminal.open(terminalContainer);
        terminalFitAddon.fit();
        
        // Handle terminal input
        terminal.onData((data) => {
            if (currentSessionId) {
                sendTerminalInput(data);
            }
        });
        
        // Handle resize
        window.addEventListener('resize', () => {
            if (terminalFitAddon) {
                terminalFitAddon.fit();
                if (currentSessionId) {
                    resizeTerminal();
                }
            }
        });
    } else {
        terminal.clear();
        terminalFitAddon.fit();
    }
    
    // Start terminal session
    try {
        showToast(`Starting interactive terminal for ${script}...`, 'info');
        
        const result = await fetchAPI(`/api/terminal/start/${script}`, {
            method: 'POST',
            force: true
        });
        
        if (result.success) {
            currentSessionId = result.session_id;
            terminalStatus.textContent = 'Connected';
            terminalStatus.className = 'terminal-status connected';
            terminal.writeln('\x1b[32m✓ Terminal session started\x1b[0m');
            terminal.writeln('\x1b[90m─────────────────────────────────────────\x1b[0m');
            terminal.writeln('');
            
            // Send initial resize
            resizeTerminal();
            
            // Focus terminal
            terminal.focus();
        } else {
            terminalStatus.textContent = 'Failed';
            terminalStatus.className = 'terminal-status error';
            terminal.writeln(`\x1b[31m✗ Error: ${result.error}\x1b[0m`);
            if (result.path) {
                terminal.writeln(`\x1b[90mPath: ${result.path}\x1b[0m`);
            }
            showToast(`Failed to start ${script}: ${result.error}`, 'error');
        }
        
    } catch (e) {
        terminalStatus.textContent = 'Error';
        terminalStatus.className = 'terminal-status error';
        terminal.writeln(`\x1b[31m✗ Error: ${e.message}\x1b[0m`);
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function sendTerminalInput(data) {
    if (!currentSessionId) return;
    
    try {
        await fetch(`/api/terminal/input/${currentSessionId}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ data: data })
        });
    } catch (e) {
        console.error('Failed to send input:', e);
    }
}

async function resizeTerminal() {
    if (!currentSessionId || !terminal) return;
    
    try {
        await fetch(`/api/terminal/resize/${currentSessionId}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ 
                cols: terminal.cols, 
                rows: terminal.rows 
            })
        });
    } catch (e) {
        console.error('Failed to resize:', e);
    }
}

async function stopTerminalSession() {
    if (!currentSessionId) return;
    
    try {
        await fetch(`/api/terminal/stop/${currentSessionId}`, { method: 'POST' });
        showToast('Terminal session stopped', 'info');
    } catch (e) {
        console.error('Failed to stop session:', e);
    }
    
    currentSessionId = null;
    const terminalStatus = document.getElementById('terminalStatus');
    if (terminalStatus) {
        terminalStatus.textContent = 'Stopped';
        terminalStatus.className = 'terminal-status disconnected';
    }
}

function closeTerminal() {
    stopTerminalSession();
    const terminalCard = document.getElementById('scriptTerminalCard');
    if (terminalCard) {
        terminalCard.style.display = 'none';
    }
    
    // Refresh setup status
        loadSetupStatus();
        loadConfigFiles();
}

// Handle terminal output from WebSocket
function setupTerminalOutputListener() {
    if (typeof socket !== 'undefined' && socket) {
        socket.on('terminal_output', (data) => {
            if (!terminal) return;
            if (currentSessionId && data.session_id !== currentSessionId) return;
            
            if (data.data) {
                terminal.write(data.data);
            }
            
            if (data.ended) {
                const terminalStatus = document.getElementById('terminalStatus');
                if (terminalStatus) {
                    terminalStatus.textContent = 'Session Ended';
                    terminalStatus.className = 'terminal-status disconnected';
                }
                currentSessionId = null;
                showToast('Script completed', 'success');
                
                // Refresh status
                loadSetupStatus();
                loadConfigFiles();
            }
        });
    }
}

// Initialize terminal output listener when socket connects
if (typeof socket !== 'undefined' && socket) {
    socket.on('connect', () => {
        setupTerminalOutputListener();
    });
    setupTerminalOutputListener();
}

function closeScriptOutput() {
    const card = document.getElementById('scriptOutputCard');
    if (card) card.style.display = 'none';
}

// Load setup page data
function loadSetupPage() {
    loadSetupStatus();
    loadGitStatus();
    loadRecentCommits();
    loadChangedFiles();
}

// =============================================================================
// SITE AVAILABILITY CHECK - 3-LEVEL COMPREHENSIVE
// =============================================================================

async function checkSiteAvailability() {
    SHELLDER_DEBUG.info('SITES', 'checkSiteAvailability called');
    const container = document.getElementById('siteAvailability');
    if (!container) {
        SHELLDER_DEBUG.error('SITES', 'siteAvailability element not found!');
        return;
    }
    
    container.innerHTML = '<div class="loading">Checking sites (3-level check)...</div>';
    
    try {
        SHELLDER_DEBUG.debug('SITES', 'Fetching /api/sites/check...');
        const data = await fetchAPI('/api/sites/check', { force: true });
        SHELLDER_DEBUG.info('SITES', 'Response received', data?.summary);
        
        // Check for errors
        if (data.error) {
            console.error('[SITES] API error:', data.error);
            container.innerHTML = `<div class="error-msg">Error: ${data.error}</div>`;
            return;
        }
        
        // Update dashboard card
        const healthEl = document.getElementById('siteHealth');
        const iconEl = document.getElementById('siteHealthIcon');
        if (healthEl && data.summary) {
            healthEl.textContent = `${data.summary.healthy}/${data.summary.total}`;
        }
        if (iconEl && data.summary) {
            iconEl.textContent = data.summary.healthy === data.summary.total ? '✅' : 
                                 data.summary.running === data.summary.total ? '🟡' : '⚠️';
        }
        
        // Render site list with 3-level checks
        if (data.sites && data.sites.length > 0) {
            container.innerHTML = data.sites.map(site => {
                const checks = site.checks || {};
                const details = site.details || {};
                
                // Determine overall status icon
                let statusIcon = '❓';
                let statusClass = 'unknown';
                switch (site.status) {
                    case 'healthy':
                        statusIcon = '✅';
                        statusClass = 'healthy';
                        break;
                    case 'running':
                        statusIcon = '🟢';
                        statusClass = 'running';
                        break;
                    case 'partial':
                        statusIcon = '🟡';
                        statusClass = 'partial';
                        break;
                    case 'backend_down':
                        statusIcon = '🔴';
                        statusClass = 'backend-down';
                        break;
                    case 'unreachable':
                        statusIcon = '🌐❌';
                        statusClass = 'unreachable';
                        break;
                    case 'offline':
                        statusIcon = '⬛';
                        statusClass = 'offline';
                        break;
                    case 'error':
                        statusIcon = '❌';
                        statusClass = 'error';
                        break;
                }
                
                // Generate check indicators
                const nginxCheck = checks.nginx_enabled ? 
                    '<span class="check-indicator check-ok" title="Nginx site enabled">📁✓</span>' :
                    '<span class="check-indicator check-na" title="No Nginx config">📁-</span>';
                
                const portCheck = checks.port_available ?
                    `<span class="check-indicator check-ok" title="Port ${details.backend_port || '?'} responding">🔌✓</span>` :
                    `<span class="check-indicator check-fail" title="Port ${details.backend_port || '?'} not responding">🔌✗</span>`;
                
                let domainCheck = '';
                if (checks.domain_accessible === true) {
                    domainCheck = `<span class="check-indicator check-ok" title="Domain accessible: ${details.domain || 'N/A'}">🌐✓</span>`;
                } else if (checks.domain_accessible === false) {
                    domainCheck = `<span class="check-indicator check-fail" title="Domain unreachable: ${site.error || 'Connection failed'}">🌐✗</span>`;
                } else {
                    domainCheck = '<span class="check-indicator check-na" title="No domain configured">🌐-</span>';
                }
                
                // Domain display
                const domainDisplay = details.domain ? 
                    `<a href="${details.ssl ? 'https' : 'http'}://${details.domain}" target="_blank" class="site-domain">${details.domain}</a>` :
                    `<span class="site-port">:${details.backend_port || '?'}</span>`;
                
                return `
                    <div class="site-check-item site-status-${statusClass}">
                        <div class="site-check-main">
                            <span class="site-check-icon">${statusIcon}</span>
                            <span class="site-check-name">${site.display_name || site.name}</span>
                            ${domainDisplay}
                        </div>
                        <div class="site-check-levels">
                            ${nginxCheck}
                            ${portCheck}
                            ${domainCheck}
                        </div>
                        ${site.error && site.status !== 'healthy' ? `<div class="site-check-error">${site.error}</div>` : ''}
                    </div>
                `;
            }).join('');
            
            // Add legend
            container.innerHTML += `
                <div class="site-check-legend">
                    <span title="Nginx config enabled">📁 Nginx</span>
                    <span title="Backend port responding">🔌 Port</span>
                    <span title="Domain/URL accessible">🌐 Domain</span>
                </div>
            `;
            
            SHELLDER_DEBUG.info('SITES', `Rendered ${data.sites.length} sites`);
        } else {
            container.innerHTML = '<div class="no-data">No sites or services detected</div>';
        }
    } catch (e) {
        SHELLDER_DEBUG.error('SITES', `Exception: ${e.message}`);
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

// =============================================================================
// DISK HEALTH MONITORING
// =============================================================================

let diskHealthRefreshInterval = null;

async function loadDiskHealth() {
    try {
        const data = await fetchAPI('/api/disk/health');
        
        if (data.error) {
            SHELLDER_DEBUG.error('DISK', 'Failed to get disk health', data);
            return;
        }
        
        // Update badge in header
        const badge = document.getElementById('diskHealthStatus');
        if (badge) {
            badge.textContent = `💾 ${data.usage.percent}%`;
            badge.className = 'badge badge-' + (data.status === 'healthy' ? 'success' : 
                                                data.status === 'warning' ? 'warning' : 'danger');
        }
        
        // Update percent display
        const percentEl = document.getElementById('diskHealthPercent');
        if (percentEl) percentEl.textContent = `${data.usage.percent}%`;
        
        // Update usage bar
        const usageBar = document.getElementById('diskUsageBar');
        if (usageBar) {
            usageBar.style.width = data.usage.percent + '%';
            usageBar.className = 'resource-bar disk' + (
                data.status === 'emergency' || data.status === 'critical' ? ' critical' :
                data.status === 'warning' ? ' warning' : ''
            );
        }
        
        // Update stats
        const usedEl = document.getElementById('diskHealthUsed');
        const totalEl = document.getElementById('diskHealthTotal');
        const freeEl = document.getElementById('diskHealthFree');
        if (usedEl) usedEl.textContent = data.usage.used;
        if (totalEl) totalEl.textContent = data.usage.total;
        if (freeEl) freeEl.textContent = data.usage.free;
        
        // Handle growth warning
        const growthWarning = document.getElementById('diskGrowthWarning');
        const growthMessage = document.getElementById('diskGrowthMessage');
        if (growthWarning && growthMessage) {
            if (data.growth_warning) {
                growthWarning.style.display = 'flex';
                growthMessage.textContent = data.growth_warning.message;
            } else {
                growthWarning.style.display = 'none';
            }
        }
        
        // Show/hide alert banner
        const alertBanner = document.getElementById('diskAlertBanner');
        const alertMessage = document.getElementById('diskAlertMessage');
        if (alertBanner && alertMessage) {
            if (data.status === 'critical' || data.status === 'emergency') {
                alertBanner.style.display = 'flex';
                alertBanner.className = 'alert-banner alert-' + (data.status === 'emergency' ? 'critical' : 'warning');
                alertMessage.textContent = data.message;
            } else {
                alertBanner.style.display = 'none';
            }
        }
        
        SHELLDER_DEBUG.info('DISK', 'Disk health loaded', { 
            status: data.status, 
            percent: data.usage.percent,
            free: data.usage.free 
        });
        
    } catch (e) {
        SHELLDER_DEBUG.error('DISK', 'Failed to load disk health', e);
    }
}

function hideDiskAlert() {
    const banner = document.getElementById('diskAlertBanner');
    if (banner) banner.style.display = 'none';
}

function showDiskHealthPanel() {
    const card = document.getElementById('diskHealthCard');
    if (card) {
        card.scrollIntoView({ behavior: 'smooth' });
        card.style.animation = 'pulse-card 0.5s 3';
    }
}

async function scanLargeFiles() {
    const resultsDiv = document.getElementById('diskScanResults');
    if (!resultsDiv) return;
    
    resultsDiv.style.display = 'block';
    resultsDiv.innerHTML = '<div class="loading">🔍 Scanning for large files (100MB+)...</div>';
    
    try {
        const data = await fetchAPI('/api/disk/large-files?min_size_mb=100&max_results=15');
        
        if (data.error) {
            resultsDiv.innerHTML = `<div class="cleanup-result error">Error: ${data.error}</div>`;
            return;
        }
        
        if (!data.files || data.files.length === 0) {
            resultsDiv.innerHTML = `
                <div class="no-bloat-found">
                    <div class="icon">✅</div>
                    <div>No files over 100MB found!</div>
                </div>
            `;
            return;
        }
        
        let html = `
            <div class="disk-scan-header">
                <span class="disk-scan-title">🔍 Large Files Found</span>
                <span class="disk-scan-total">Total: ${data.total_size_human}</span>
            </div>
        `;
        
        for (const file of data.files) {
            html += `
                <div class="large-file-item">
                    <div class="file-info">
                        <div class="file-path">${escapeHtml(file.path)}</div>
                        <div class="file-modified">Modified: ${new Date(file.modified).toLocaleString()}</div>
                    </div>
                    <span class="file-size">${file.size_human}</span>
                    <div class="file-actions">
                        <button class="btn-delete" onclick="deleteFile('${escapeHtml(file.path)}')" title="Delete file">🗑️ Delete</button>
                    </div>
                </div>
            `;
        }
        
        resultsDiv.innerHTML = html;
        showToast(`Found ${data.count} large files totaling ${data.total_size_human}`, 'info');
        
    } catch (e) {
        resultsDiv.innerHTML = `<div class="cleanup-result error">Error: ${e.message}</div>`;
        SHELLDER_DEBUG.error('DISK', 'Failed to scan large files', e);
    }
}

async function detectBloat() {
    const resultsDiv = document.getElementById('diskScanResults');
    if (!resultsDiv) return;
    
    resultsDiv.style.display = 'block';
    resultsDiv.innerHTML = '<div class="loading">🗑️ Detecting known bloat sources...</div>';
    
    try {
        const data = await fetchAPI('/api/disk/bloat');
        
        if (data.error) {
            resultsDiv.innerHTML = `<div class="cleanup-result error">Error: ${data.error}</div>`;
            return;
        }
        
        if (!data.bloat_sources || data.bloat_sources.length === 0) {
            resultsDiv.innerHTML = `
                <div class="no-bloat-found">
                    <div class="icon">✅</div>
                    <div>No bloat detected! System is clean.</div>
                </div>
            `;
            return;
        }
        
        let html = `
            <div class="disk-scan-header">
                <span class="disk-scan-title">🗑️ Bloat Sources Detected</span>
                <span class="disk-scan-total">Total: ${data.total_bloat_human} recoverable</span>
            </div>
        `;
        
        for (const source of data.bloat_sources) {
            const safeLabel = source.safe ? '(Safe)' : '⚠️ (May have side effects)';
            html += `
                <div class="bloat-item">
                    <div class="bloat-info">
                        <div class="bloat-name">${escapeHtml(source.name)}</div>
                        <div class="bloat-description">${escapeHtml(source.description)} ${safeLabel}</div>
                    </div>
                    <span class="bloat-severity ${source.severity}">${source.severity}</span>
                    <span class="bloat-size">${source.total_size_human}</span>
                    <div class="bloat-actions">
                        <button class="btn-cleanup" onclick="cleanupBloat('${source.id}', ${source.safe})" 
                                title="Clean up ${source.name}">
                            🧹 Clean
                        </button>
                    </div>
                </div>
            `;
        }
        
        resultsDiv.innerHTML = html;
        showToast(`Found ${data.bloat_sources.length} bloat sources totaling ${data.total_bloat_human}`, 'warning');
        
    } catch (e) {
        resultsDiv.innerHTML = `<div class="cleanup-result error">Error: ${e.message}</div>`;
        SHELLDER_DEBUG.error('DISK', 'Failed to detect bloat', e);
    }
}

async function cleanupBloat(sourceId, isSafe) {
    if (!isSafe) {
        if (!confirm(`This cleanup is marked as potentially unsafe and may have side effects. Are you sure you want to proceed?`)) {
            return;
        }
    }
    
    showToast(`🧹 Cleaning up ${sourceId}...`, 'info');
    
    try {
        const data = await fetchAPI('/api/disk/cleanup', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ source_id: sourceId, force: !isSafe })
        });
        
        if (data.error) {
            showToast(`❌ Cleanup failed: ${data.error}`, 'error');
            return;
        }
        
        showToast(`✅ Cleaned ${data.source_name}: freed ${data.freed}!`, 'success');
        
        // Refresh disk health and bloat detection
        await loadDiskHealth();
        await detectBloat();
        
    } catch (e) {
        showToast(`❌ Cleanup failed: ${e.message}`, 'error');
        SHELLDER_DEBUG.error('DISK', 'Cleanup failed', e);
    }
}

async function cleanupAllSafe() {
    showToast('🧹 Running quick cleanup on all safe sources...', 'info');
    
    try {
        const data = await fetchAPI('/api/disk/cleanup-all', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ include_unsafe: false })
        });
        
        if (data.error) {
            showToast(`❌ Cleanup failed: ${data.error}`, 'error');
            return;
        }
        
        if (data.total_freed_bytes > 0) {
            showToast(`✅ Quick cleanup complete! Freed ${data.total_freed}`, 'success');
        } else {
            showToast('No bloat to clean up - system is already clean!', 'info');
        }
        
        // Show results
        const resultsDiv = document.getElementById('diskScanResults');
        if (resultsDiv && data.results && data.results.length > 0) {
            resultsDiv.style.display = 'block';
            let html = `
                <div class="disk-scan-header">
                    <span class="disk-scan-title">🧹 Cleanup Results</span>
                    <span class="disk-scan-total">Total freed: ${data.total_freed}</span>
                </div>
            `;
            
            for (const result of data.results) {
                if (result.skipped) {
                    html += `
                        <div class="bloat-item" style="opacity: 0.6;">
                            <div class="bloat-info">
                                <div class="bloat-name">${escapeHtml(result.source_name)}</div>
                                <div class="bloat-description">Skipped: ${result.reason}</div>
                            </div>
                        </div>
                    `;
                } else {
                    html += `
                        <div class="bloat-item">
                            <div class="bloat-info">
                                <div class="bloat-name">${escapeHtml(result.source_name)}</div>
                                <div class="bloat-description">Cleaned successfully</div>
                            </div>
                            <span class="bloat-size" style="color: var(--success);">-${result.freed}</span>
                        </div>
                    `;
                }
            }
            
            resultsDiv.innerHTML = html;
        }
        
        // Refresh disk health
        await loadDiskHealth();
        
    } catch (e) {
        showToast(`❌ Cleanup failed: ${e.message}`, 'error');
        SHELLDER_DEBUG.error('DISK', 'Quick cleanup failed', e);
    }
}

async function deleteFile(filepath) {
    if (!confirm(`Are you sure you want to permanently delete:\n\n${filepath}\n\nThis cannot be undone!`)) {
        return;
    }
    
    showToast(`🗑️ Deleting file...`, 'info');
    
    try {
        const data = await fetchAPI('/api/disk/delete-file', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ path: filepath })
        });
        
        if (data.error) {
            showToast(`❌ Delete failed: ${data.error}`, 'error');
            return;
        }
        
        showToast(`✅ Deleted! Freed ${data.size_freed}`, 'success');
        
        // Refresh disk health and file scan
        await loadDiskHealth();
        await scanLargeFiles();
        
    } catch (e) {
        showToast(`❌ Delete failed: ${e.message}`, 'error');
        SHELLDER_DEBUG.error('DISK', 'File delete failed', e);
    }
}

// Start disk health monitoring on dashboard
function startDiskHealthMonitoring() {
    // Initial load
    loadDiskHealth();
    
    // Refresh every 60 seconds
    if (diskHealthRefreshInterval) clearInterval(diskHealthRefreshInterval);
    diskHealthRefreshInterval = setInterval(loadDiskHealth, 60000);
}

// Initialize disk health on dashboard load
if (document.getElementById('systemResourcesCard')) {
    startSystemResourcesMonitoring();
}

// Combined System Resources functions
function loadSystemResources() {
    loadDiskHealth();
    loadMemoryHealth();
}

function startSystemResourcesMonitoring() {
    loadSystemResources();
    // Refresh every 30 seconds
    setInterval(loadSystemResources, 30000);
}

function showResourceTab(tab) {
    // Hide all content
    document.querySelectorAll('.resource-content').forEach(el => el.style.display = 'none');
    // Deactivate all tabs
    document.querySelectorAll('.resource-tab').forEach(el => el.classList.remove('active'));
    
    // Show selected content
    const contentId = 'resource' + tab.charAt(0).toUpperCase() + tab.slice(1);
    const content = document.getElementById(contentId);
    if (content) content.style.display = 'block';
    
    // Activate selected tab
    const tabEl = document.getElementById('tab' + tab.charAt(0).toUpperCase() + tab.slice(1));
    if (tabEl) tabEl.classList.add('active');
    
    // Load processes if switching to that tab
    if (tab === 'processes') {
        loadProcessList();
    }
}

// =============================================================================
// MEMORY MANAGER
// =============================================================================

let memoryHealthRefreshInterval = null;
let currentProcessSort = 'memory';

async function loadMemoryHealth() {
    try {
        const data = await fetchAPI('/api/memory/health');
        
        if (data.error) {
            SHELLDER_DEBUG.error('MEMORY', 'Failed to get memory health', data);
            return;
        }
        
        // Update badge in header
        const badge = document.getElementById('memoryHealthStatus');
        if (badge) {
            badge.textContent = `🧠 ${data.ram.percent}%`;
            badge.className = 'badge badge-' + (data.status === 'healthy' ? 'success' : 
                                                data.status === 'warning' ? 'warning' : 'danger');
        }
        
        // Update RAM percent
        const ramPercent = document.getElementById('ramPercent');
        if (ramPercent) ramPercent.textContent = `${data.ram.percent}%`;
        
        // Update RAM bar
        const ramBar = document.getElementById('ramUsageBar');
        if (ramBar) {
            ramBar.style.width = data.ram.percent + '%';
            ramBar.className = 'resource-bar memory' + (
                data.status === 'emergency' || data.status === 'critical' ? ' critical' :
                data.status === 'warning' ? ' warning' : ''
            );
        }
        
        // Update RAM stats
        const ramUsed = document.getElementById('ramUsed');
        const ramTotal = document.getElementById('ramTotal');
        const ramAvailable = document.getElementById('ramAvailable');
        if (ramUsed) ramUsed.textContent = data.ram.used;
        if (ramTotal) ramTotal.textContent = data.ram.total;
        if (ramAvailable) ramAvailable.textContent = data.ram.available;
        
        // Update Swap percent
        const swapPercent = document.getElementById('swapPercent');
        if (swapPercent) swapPercent.textContent = `${data.swap.percent}%`;
        
        // Update Swap bar
        const swapBar = document.getElementById('swapUsageBar');
        if (swapBar) {
            swapBar.style.width = data.swap.percent + '%';
        }
        
        // Update Swap stats
        const swapUsed = document.getElementById('swapUsed');
        const swapTotal = document.getElementById('swapTotal');
        if (swapUsed) swapUsed.textContent = data.swap.used;
        if (swapTotal) swapTotal.textContent = data.swap.total;
        
        // Update clearable cache
        const clearable = document.getElementById('memoryClearable');
        if (clearable) clearable.textContent = data.clearable_cache;
        
        SHELLDER_DEBUG.info('MEMORY', 'Memory health loaded', {
            status: data.status,
            percent: data.ram.percent,
            available: data.ram.available
        });
        
    } catch (e) {
        SHELLDER_DEBUG.error('MEMORY', 'Failed to load memory health', e);
    }
}

async function showProcessList() {
    // Just switch to processes tab
    showResourceTab('processes');
}

async function loadProcessList(sortBy = currentProcessSort) {
    const container = document.getElementById('processListContainer');
    if (!container) return;
    
    currentProcessSort = sortBy;
    
    // Update sort button states
    document.getElementById('sortMemory')?.classList.toggle('active', sortBy === 'memory');
    document.getElementById('sortCpu')?.classList.toggle('active', sortBy === 'cpu');
    
    container.innerHTML = '<div class="loading">Loading processes...</div>';
    
    try {
        const data = await fetchAPI(`/api/memory/processes?sort=${sortBy}&limit=12`);
        
        if (data.error) {
            container.innerHTML = `<div class="cleanup-result error">Error: ${data.error}</div>`;
            return;
        }
        
        let html = '';
        
        for (const proc of data.processes) {
            const isProtected = isProtectedProcess(proc.name);
            const uptimeStr = formatUptime(proc.uptime);
            
            html += `
                <div class="process-item">
                    <div class="process-info">
                        <div class="process-name">${escapeHtml(proc.name)}</div>
                        <div class="process-details">
                            <span>PID: ${proc.pid}</span>
                            <span>${uptimeStr}</span>
                        </div>
                    </div>
                    <div class="process-stats">
                        <div class="process-stat">
                            <span class="process-stat-value memory">${proc.memory_percent}%</span>
                            <span class="process-stat-label">RAM</span>
                        </div>
                        <div class="process-stat">
                            <span class="process-stat-value cpu">${proc.cpu_percent}%</span>
                            <span class="process-stat-label">CPU</span>
                        </div>
                    </div>
                    <div class="process-actions">
                        ${isProtected ? 
                            '<span class="process-protected">🔒</span>' :
                            `<button class="btn-process-kill" onclick="killProcess(${proc.pid}, '${escapeHtml(proc.name)}')" title="Kill process">Kill</button>`
                        }
                    </div>
                </div>
            `;
        }
        
        container.innerHTML = html || '<div class="no-data">No processes found</div>';
        
    } catch (e) {
        container.innerHTML = `<div class="cleanup-result error">Error: ${e.message}</div>`;
        SHELLDER_DEBUG.error('MEMORY', 'Failed to load processes', e);
    }
}

function isProtectedProcess(name) {
    const protectedNames = [
        'systemd', 'init', 'sshd', 'dockerd', 'containerd', 'shellder',
        'kworker', 'migration', 'ksoftirqd', 'kthreadd', 'rcu_sched',
        'watchdog', 'kauditd', 'kswapd', 'login', 'bash', 'sh', 'zsh'
    ];
    const lowerName = name.toLowerCase();
    return protectedNames.some(p => lowerName.includes(p));
}

function formatUptime(seconds) {
    if (seconds < 60) return `${seconds}s`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
    return `${Math.floor(seconds / 86400)}d`;
}

async function killProcess(pid, name) {
    if (!confirm(`Are you sure you want to kill process "${name}" (PID ${pid})?\n\nThis may cause data loss if the process is doing important work.`)) {
        return;
    }
    
    showToast(`Killing process ${name}...`, 'info');
    
    try {
        const data = await fetchAPI(`/api/memory/process/${pid}/kill`, { method: 'POST' });
        
        if (data.error) {
            showToast(`❌ Failed: ${data.error}`, 'error');
            return;
        }
        
        showToast(`✅ Killed ${data.name}, freed ~${data.memory_freed_percent}% memory`, 'success');
        
        // Refresh process list and memory health
        await loadProcessList();
        await loadMemoryHealth();
        
    } catch (e) {
        showToast(`❌ Failed: ${e.message}`, 'error');
        SHELLDER_DEBUG.error('MEMORY', 'Kill process failed', e);
    }
}

async function clearMemoryCache() {
    showToast('🧹 Clearing memory cache...', 'info');
    
    try {
        const data = await fetchAPI('/api/memory/clear-cache', { method: 'POST' });
        
        if (data.error) {
            showToast(`❌ Failed: ${data.error}`, 'error');
            return;
        }
        
        showToast(`✅ Cache cleared! Freed ${data.freed}`, 'success');
        
        // Show result in container
        const container = document.getElementById('processListContainer');
        if (container) {
            container.style.display = 'block';
            container.innerHTML = `
                <div class="memory-cleanup-result success">
                    <strong>✅ Memory Cache Cleared</strong><br>
                    Freed: ${data.freed}<br>
                    Memory usage: ${data.memory_before}% → ${data.memory_after}%
                </div>
            `;
        }
        
        // Refresh memory health
        await loadMemoryHealth();
        
    } catch (e) {
        showToast(`❌ Failed: ${e.message}`, 'error');
        SHELLDER_DEBUG.error('MEMORY', 'Clear cache failed', e);
    }
}

async function emergencyMemoryCleanup() {
    if (!confirm('⚠️ EMERGENCY MEMORY CLEANUP\n\nThis will kill the top memory-consuming processes (up to 3) to free memory.\n\nThis may cause:\n- Service interruptions\n- Data loss\n- Unexpected behavior\n\nOnly use if system is unresponsive!\n\nContinue?')) {
        return;
    }
    
    showToast('🚨 Emergency cleanup running...', 'warning');
    
    try {
        const data = await fetchAPI('/api/memory/kill-high-memory', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ target_percent: 70, max_kills: 3 })
        });
        
        if (data.error) {
            showToast(`❌ Failed: ${data.error}`, 'error');
            return;
        }
        
        if (data.killed && data.killed.length > 0) {
            const killedNames = data.killed.map(k => k.name).join(', ');
            showToast(`🚨 Killed ${data.killed.length} processes: ${killedNames}`, 'warning');
            
            // Show result
            const container = document.getElementById('processListContainer');
            if (container) {
                container.style.display = 'block';
                let html = `
                    <div class="memory-cleanup-result warning">
                        <strong>🚨 Emergency Cleanup Complete</strong><br>
                        Memory: ${data.memory_before}% → ${data.memory_after}%<br>
                        Freed: ~${data.total_freed_percent.toFixed(1)}%<br><br>
                        <strong>Processes killed:</strong><br>
                `;
                for (const killed of data.killed) {
                    html += `• ${killed.name} (PID ${killed.pid}) - ${killed.memory_percent}%<br>`;
                }
                html += '</div>';
                container.innerHTML = html;
            }
        } else {
            showToast(`Memory already at ${data.memory_after}%, no action needed`, 'info');
        }
        
        // Refresh memory health
        await loadMemoryHealth();
        
    } catch (e) {
        showToast(`❌ Failed: ${e.message}`, 'error');
        SHELLDER_DEBUG.error('MEMORY', 'Emergency cleanup failed', e);
    }
}

// Memory health monitoring is now handled by startSystemResourcesMonitoring()

// =============================================================================
// STACK SETUP WIZARD
// =============================================================================

let wizardStatus = null;
let wizardStarted = false;
let portCheckResult = null;  // Track port check results
let detectedResources = null;
let generatedPasswords = null;

// Start the wizard - called when user clicks Start Wizard button
async function startWizard() {
    wizardStarted = true;
    
    // Hide start prompt, show wizard content
    const startPrompt = document.getElementById('wizardStartPrompt');
    const wizardContent = document.getElementById('wizardContent');
    if (startPrompt) startPrompt.style.display = 'none';
    if (wizardContent) wizardContent.style.display = 'block';
    
    showToast('Starting Setup Wizard...', 'info');
    await refreshWizardStatus();
}

async function refreshWizardStatus() {
    const progressText = document.getElementById('wizardProgressText');
    if (progressText) progressText.textContent = 'Checking...';
    
    try {
        const response = await fetch('/api/wizard/status');
        if (!response.ok) throw new Error('Failed to get wizard status');
        wizardStatus = await response.json();
        updateWizardUI();
        showToast('Status refreshed', 'success');
    } catch (e) {
        console.error('Failed to refresh wizard status:', e);
        if (progressText) progressText.textContent = 'Error loading status';
        showToast('Failed to check setup status: ' + e.message, 'error');
    }
}

function updateWizardUI() {
    if (!wizardStatus) return;
    
    // Update progress bar
    const progressFill = document.getElementById('wizardProgressFill');
    const progressText = document.getElementById('wizardProgressText');
    if (progressFill) progressFill.style.width = `${wizardStatus.overall_progress}%`;
    if (progressText) progressText.textContent = `${wizardStatus.overall_progress}% Complete`;
    
    // Update Docker step
    updateStepStatus('docker', wizardStatus.steps.docker?.complete, 
        wizardStatus.steps.docker?.complete ? 'Docker is running' : 'Docker not installed or not running');
    
    // Update ports step - preserve check result if already checked
    if (portCheckResult !== null) {
        updateStepStatus('ports', portCheckResult.success, portCheckResult.message);
    } else {
        updateStepStatus('ports', false, 'Click to check');
    }
    
    // Update resources step
    updateStepStatus('resources', detectedResources !== null,
        detectedResources ? `${detectedResources.ram_gb}GB RAM, ${detectedResources.cpu_cores} cores` : 'Click to detect');
    
    // Update Chrome step
    const chromeStep = wizardStatus.steps.chrome;
    if (chromeStep) {
        let chromeDetails = '';
        if (!chromeStep.installed) {
            chromeDetails = 'Not installed';
        } else if (!chromeStep.version_match) {
            chromeDetails = `v${chromeStep.version || '?'} (need ${chromeStep.required_version})`;
        } else if (!chromeStep.updates_disabled) {
            chromeDetails = `v${chromeStep.version} - updates not disabled`;
        } else {
            chromeDetails = `v${chromeStep.version} ✓`;
        }
        updateStepStatus('chrome', chromeStep.complete, chromeDetails);
    }
    
    // Update other steps
    updateStepStatus('configs', wizardStatus.steps.config_files?.complete,
        wizardStatus.steps.config_files?.complete ? 'Config files ready' : 'Configs need to be copied');
    
    updateStepStatus('passwords', wizardStatus.steps.passwords?.complete,
        wizardStatus.steps.passwords?.complete ? 'Passwords configured' : 'Passwords not set');
    
    updateStepStatus('mariadb', wizardStatus.steps.mariadb_setup?.complete,
        wizardStatus.steps.mariadb_setup?.complete ? 'Databases ready' : 
        (wizardStatus.steps.mariadb_setup?.databases_created ? 'Needs optimization' : 'Needs setup'));
    
    updateStepStatus('logging', wizardStatus.steps.docker_logging?.complete,
        wizardStatus.steps.docker_logging?.complete ? 'Log rotation enabled' : 'Not configured');
    
    updateStepStatus('start', wizardStatus.steps.database?.complete,
        wizardStatus.steps.database?.complete ? 'Stack is running' : 'Not started');
    
    // Enable start button if prerequisites are met
    const startBtn = document.getElementById('startStackBtn');
    if (startBtn) {
        startBtn.disabled = !wizardStatus.ready_to_start;
    }
}

function updateStepStatus(stepName, complete, details) {
    const statusEl = document.getElementById(`step-${stepName}-status`);
    const detailsEl = document.getElementById(`step-${stepName}-details`);
    const cardEl = document.getElementById(`wizard-step-${stepName}`);
    
    if (statusEl) statusEl.textContent = complete ? '✅' : '⏳';
    if (detailsEl) detailsEl.textContent = details || '';
    if (cardEl) {
        cardEl.classList.remove('complete', 'pending');
        cardEl.classList.add(complete ? 'complete' : 'pending');
    }
}

// =============================================================================
// CHROME SETUP PANEL
// =============================================================================

async function showChromeSetupPanel() {
    // Remove existing panel if any
    closeChromeSetupPanel();
    
    // Fetch current Chrome status
    let chromeStatus = null;
    try {
        chromeStatus = await fetchAPI('/api/stack/chrome/check');
    } catch (e) {
        showToast('Failed to check Chrome status: ' + e.message, 'error');
        return;
    }
    
    const installed = chromeStatus.installed;
    const versionMatch = chromeStatus.version_match;
    const updatesDisabled = chromeStatus.updates_disabled;
    const currentVersion = chromeStatus.version || 'Not installed';
    const requiredVersion = chromeStatus.required_version || '125.0.6422.141';
    
    const html = `
        <div id="chromeSetupPanel" class="wizard-popout-panel">
            <div class="popout-header">
                <h3>🌐 Google Chrome Setup</h3>
                <button class="btn btn-sm" onclick="closeChromeSetupPanel()">✕ Close</button>
            </div>
            <div class="popout-body">
                <div class="chrome-status-grid" style="display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin-bottom: 1.5rem;">
                    <div class="status-item">
                        <strong>Current Version:</strong>
                        <span class="${installed ? (versionMatch ? 'text-success' : 'text-warning') : 'text-danger'}">${currentVersion}</span>
                    </div>
                    <div class="status-item">
                        <strong>Required Version:</strong>
                        <span>${requiredVersion}</span>
                    </div>
                    <div class="status-item">
                        <strong>Version Match:</strong>
                        <span class="${versionMatch ? 'text-success' : 'text-danger'}">${versionMatch ? '✅ Yes' : '❌ No'}</span>
                    </div>
                    <div class="status-item">
                        <strong>Updates Disabled:</strong>
                        <span class="${updatesDisabled ? 'text-success' : 'text-warning'}">${updatesDisabled ? '✅ Yes' : '⚠️ No'}</span>
                    </div>
                </div>
                
                <div class="chrome-info-box" style="background: var(--bg-tertiary); padding: 1rem; border-radius: 8px; margin-bottom: 1.5rem;">
                    <h4 style="margin: 0 0 0.5rem 0;">ℹ️ Why specific Chrome version?</h4>
                    <p style="margin: 0; font-size: 0.9rem; color: var(--text-secondary);">
                        Scanner tools require ChromeDriver compatibility. Version ${requiredVersion} is tested and 
                        verified to work with the scanning components. Auto-updates must be disabled to prevent
                        Chrome from updating and breaking ChromeDriver compatibility.
                    </p>
                </div>
                
                <div class="chrome-actions" style="display: flex; flex-direction: column; gap: 1rem;">
                    ${!installed || !versionMatch ? `
                        <div class="action-card" style="background: var(--bg-secondary); padding: 1rem; border-radius: 8px; border-left: 4px solid var(--accent-color);">
                            <h4 style="margin: 0 0 0.5rem 0;">📥 Install Chrome ${requiredVersion}</h4>
                            <p style="margin: 0 0 1rem 0; font-size: 0.9rem; color: var(--text-secondary);">
                                ${installed ? 'Replace current version with required version.' : 'Download and install the required Chrome version.'}
                            </p>
                            <button class="btn btn-primary" onclick="installChromeVersion()" id="installChromeBtn">
                                ${installed ? '🔄 Replace Chrome' : '📥 Install Chrome'}
                            </button>
                        </div>
                    ` : ''}
                    
                    ${installed && versionMatch && !updatesDisabled ? `
                        <div class="action-card" style="background: var(--bg-secondary); padding: 1rem; border-radius: 8px; border-left: 4px solid var(--warning-color);">
                            <h4 style="margin: 0 0 0.5rem 0;">🔒 Disable Chrome Updates</h4>
                            <p style="margin: 0 0 1rem 0; font-size: 0.9rem; color: var(--text-secondary);">
                                Prevent Chrome from auto-updating to maintain scanner compatibility.
                            </p>
                            <button class="btn btn-warning" onclick="disableChromeUpdates()" id="disableUpdatesBtn">
                                🔒 Disable Updates
                            </button>
                        </div>
                    ` : ''}
                    
                    ${installed && versionMatch && updatesDisabled ? `
                        <div class="action-card" style="background: var(--bg-secondary); padding: 1rem; border-radius: 8px; border-left: 4px solid var(--success-color);">
                            <h4 style="margin: 0 0 0.5rem 0;">✅ Chrome Setup Complete</h4>
                            <p style="margin: 0; font-size: 0.9rem; color: var(--text-secondary);">
                                Chrome ${requiredVersion} is installed and updates are disabled. Scanner is ready!
                            </p>
                        </div>
                    ` : ''}
                </div>
                
                <div id="chromeOutputContainer" style="margin-top: 1.5rem; display: none;">
                    <h4 style="margin: 0 0 0.5rem 0;">📋 Installation Output</h4>
                    <pre id="chromeOutput" style="background: var(--bg-tertiary); padding: 1rem; border-radius: 8px; max-height: 300px; overflow-y: auto; font-size: 0.85rem; white-space: pre-wrap;"></pre>
                </div>
            </div>
            <div class="popout-footer">
                <button class="btn btn-secondary btn-sm" onclick="refreshChromeStatus()">🔄 Refresh Status</button>
                <a href="${chromeStatus.download_url}" target="_blank" class="btn btn-outline btn-sm" style="text-decoration: none;">
                    📥 Manual Download
                </a>
            </div>
        </div>
    `;
    
    // Insert after the wizard steps grid
    const stepsGrid = document.querySelector('.wizard-steps-grid');
    if (stepsGrid) {
        stepsGrid.insertAdjacentHTML('afterend', html);
    } else {
        const wizardContent = document.getElementById('wizardContent');
        if (wizardContent) {
            wizardContent.insertAdjacentHTML('beforeend', html);
        }
    }
    
    document.getElementById('chromeSetupPanel')?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function closeChromeSetupPanel() {
    const panel = document.getElementById('chromeSetupPanel');
    if (panel) panel.remove();
}

async function refreshChromeStatus() {
    closeChromeSetupPanel();
    await refreshWizardStatus();
    showChromeSetupPanel();
}

async function installChromeVersion() {
    const btn = document.getElementById('installChromeBtn');
    const outputContainer = document.getElementById('chromeOutputContainer');
    const output = document.getElementById('chromeOutput');
    
    if (btn) btn.disabled = true;
    if (btn) btn.innerHTML = '⏳ Installing...';
    if (outputContainer) outputContainer.style.display = 'block';
    if (output) output.textContent = 'Starting Chrome installation...\n';
    
    try {
        const result = await fetchAPI('/api/stack/chrome/install', { method: 'POST' });
        
        if (output) {
            output.textContent = '';
            if (result.steps) {
                result.steps.forEach(step => {
                    output.textContent += `${step.status === 'completed' ? '✅' : '❌'} ${step.name}\n`;
                });
            }
            output.textContent += '\n' + (result.output || '');
            
            if (result.version_installed) {
                output.textContent += `\n\n✅ Chrome ${result.version_installed} installed successfully!`;
            }
        }
        
        if (result.success) {
            showToast(`Chrome ${result.version_installed} installed successfully!`, 'success');
            
            // Automatically disable updates after installation
            if (output) output.textContent += '\n\nDisabling Chrome updates...';
            await disableChromeUpdates();
        } else {
            showToast('Chrome installation failed: ' + (result.error || 'Unknown error'), 'error');
            if (btn) btn.innerHTML = '❌ Failed - Retry';
            if (btn) btn.disabled = false;
        }
        
    } catch (e) {
        showToast('Chrome installation failed: ' + e.message, 'error');
        if (output) output.textContent += '\n\n❌ Error: ' + e.message;
        if (btn) btn.innerHTML = '❌ Failed - Retry';
        if (btn) btn.disabled = false;
    }
}

async function disableChromeUpdates() {
    const btn = document.getElementById('disableUpdatesBtn');
    const outputContainer = document.getElementById('chromeOutputContainer');
    const output = document.getElementById('chromeOutput');
    
    if (btn) btn.disabled = true;
    if (btn) btn.innerHTML = '⏳ Disabling...';
    if (outputContainer) outputContainer.style.display = 'block';
    if (output) output.textContent += '\n\nDisabling Chrome updates...\n';
    
    try {
        const result = await fetchAPI('/api/stack/chrome/disable-updates', { method: 'POST' });
        
        if (output && result.steps) {
            result.steps.forEach(step => {
                output.textContent += `${step.status === 'completed' ? '✅' : '❌'} ${step.name}\n`;
            });
        }
        
        if (result.success) {
            showToast('Chrome updates disabled successfully!', 'success');
            if (output) output.textContent += '\n✅ ' + (result.message || 'Updates disabled');
            
            // Refresh the panel to show completion state
            setTimeout(() => {
                refreshChromeStatus();
                refreshWizardStatus();
            }, 1000);
        } else {
            showToast('Failed to disable updates: ' + (result.error || 'Unknown error'), 'error');
            if (btn) btn.innerHTML = '❌ Failed - Retry';
            if (btn) btn.disabled = false;
        }
        
    } catch (e) {
        showToast('Failed to disable updates: ' + e.message, 'error');
        if (output) output.textContent += '\n❌ Error: ' + e.message;
        if (btn) btn.innerHTML = '❌ Failed - Retry';
        if (btn) btn.disabled = false;
    }
}

async function runWizardStep(step) {
    showWizardOutput(`Running: ${step}...`, true);
    
    try {
        switch(step) {
            case 'docker':
                await runDockerInstall();
                break;
            case 'ports':
                await checkPortsStep();
                break;
            case 'resources':
                await detectResourcesStep();
                break;
            case 'configs':
                await copyConfigsStep();
                break;
            case 'passwords':
                await generatePasswordsStep();
                break;
            case 'mariadb':
            case 'mariadb_setup':
                await mariadbSetupStep();
                break;
            case 'logging':
                await configureLoggingStep();
                break;
            case 'start':
                await startStackStep();
                break;
        }
        
        // Refresh status after any step
        await refreshWizardStatus();
        
    } catch (e) {
        appendWizardOutput(`\n❌ Error: ${e.message}`, 'error');
        showToast(`Step failed: ${e.message}`, 'error');
    }
}

async function runDockerInstall() {
    appendWizardOutput('Checking Docker installation...\\n');
    
    const response = await fetch('/api/wizard/status');
    const status = await response.json();
    
    if (status.steps.docker?.complete) {
        appendWizardOutput('✅ Docker is already installed and running!\\n', 'success');
        return;
    }
    
    appendWizardOutput('⚠️ Docker needs to be installed.\\n', 'warning');
    appendWizardOutput('\\nTo install Docker, run this in your terminal:\\n\\n');
    appendWizardOutput('  curl -fsSL https://get.docker.com | sudo sh\\n', 'code');
    appendWizardOutput('  sudo systemctl enable docker\\n', 'code');
    appendWizardOutput('  sudo systemctl start docker\\n', 'code');
    appendWizardOutput('\\nOr use the Quick Actions below to run the full setup script.\\n');
}

async function checkPortsStep() {
    appendWizardOutput('Checking required ports...\\n');
    
    const response = await fetch('/api/wizard/check-ports');
    if (!response.ok) throw new Error('Failed to check ports');
    const data = await response.json();
    
    appendWizardOutput('\\n┌────────┬─────────────────────┬────────────┐\\n');
    appendWizardOutput('│ Port   │ Service             │ Status     │\\n');
    appendWizardOutput('├────────┼─────────────────────┼────────────┤\\n');
    
    for (const [port, info] of Object.entries(data.ports)) {
        const status = info.available ? '✅ Free' : `❌ ${info.process || 'In Use'}`;
        appendWizardOutput(`│ ${port.toString().padEnd(6)} │ ${info.service.padEnd(19)} │ ${status.padEnd(10)} │\\n`);
    }
    
    appendWizardOutput('└────────┴─────────────────────┴────────────┘\\n');
    
    if (data.all_available) {
        appendWizardOutput('\\n✅ All required ports are available!\\n', 'success');
        portCheckResult = { success: true, message: 'All ports free' };
        updateStepStatus('ports', true, 'All ports free');
    } else {
        appendWizardOutput('\\n⚠️ Some ports are in use. Stop conflicting services first.\\n', 'warning');
        portCheckResult = { success: false, message: 'Port conflicts detected' };
        updateStepStatus('ports', false, 'Port conflicts detected');
    }
}

async function detectResourcesStep() {
    appendWizardOutput('Detecting system resources...\\n');
    
    const response = await fetch('/api/wizard/detect-resources');
    if (!response.ok) throw new Error('Failed to detect resources');
    detectedResources = await response.json();
    
    appendWizardOutput('\\n┌─────────────────────────────────────────────┐\\n');
    appendWizardOutput('│           DETECTED SYSTEM RESOURCES          │\\n');
    appendWizardOutput('├─────────────────────────────────────────────┤\\n');
    appendWizardOutput(`│  RAM:         ${detectedResources.ram_gb} GB                          │\\n`);
    appendWizardOutput(`│  CPU Cores:   ${detectedResources.cpu_cores}                             │\\n`);
    appendWizardOutput(`│  Storage:     ${detectedResources.storage_type.toUpperCase()}                          │\\n`);
    appendWizardOutput('└─────────────────────────────────────────────┘\\n');
    
    appendWizardOutput('\\nRecommended MariaDB Settings:\\n');
    for (const [key, value] of Object.entries(detectedResources.recommended)) {
        appendWizardOutput(`  ${key}: ${value}\\n`);
    }
    
    updateStepStatus('resources', true, `${detectedResources.ram_gb}GB RAM, ${detectedResources.cpu_cores} cores`);
    appendWizardOutput('\\n✅ Resources detected successfully!\\n', 'success');
}

async function copyConfigsStep() {
    appendWizardOutput('Copying configuration files from examples...\\n');
    
    const response = await fetch('/api/wizard/copy-configs', { method: 'POST' });
    if (!response.ok) throw new Error('Failed to copy configs');
    const data = await response.json();
    
    if (data.copied.length > 0) {
        appendWizardOutput('\\n✅ Copied files:\\n', 'success');
        for (const file of data.copied) {
            appendWizardOutput(`  • ${file}\\n`);
        }
    } else {
        appendWizardOutput('\\nℹ️ All config files already exist.\\n', 'info');
    }
    
    if (data.errors.length > 0) {
        appendWizardOutput('\\n⚠️ Errors:\\n', 'warning');
        for (const err of data.errors) {
            appendWizardOutput(`  • ${err.file}: ${err.error}\\n`);
        }
    }
    
    updateStepStatus('configs', true, 'Config files ready');
}

async function generatePasswordsStep() {
    // Just toggle the password panel - don't use the wizard output
    togglePasswordPanel();
}

// Password panel state - using comprehensive secrets API
let currentSecretsData = null;
let secretFieldChoices = {};

async function togglePasswordPanel() {
    const panel = document.getElementById('passwordPanel');
    
    if (panel.style.display === 'none') {
        // Load and show
        showToast('Loading secrets configuration...', 'info');
        
        try {
            const response = await fetch('/api/secrets/list');
            if (!response.ok) throw new Error('Failed to load secrets');
            currentSecretsData = await response.json();
            
            renderSecretsPanel(currentSecretsData);
            panel.style.display = 'block';
            
            // Scroll panel into view
            panel.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        } catch (e) {
            showToast('Failed to load secrets: ' + e.message, 'error');
        }
    } else {
        closePasswordPanel();
    }
}

function closePasswordPanel() {
    document.getElementById('passwordPanel').style.display = 'none';
}

function renderSecretsPanel(data) {
    const statusEl = document.getElementById('passwordPanelStatus');
    const container = document.getElementById('passwordFieldsContainer');
    
    secretFieldChoices = {};
    
    // Count status
    const secrets = data.secrets;
    const defaultCount = Object.values(secrets).filter(s => s.is_default || !s.has_value).length;
    const configuredCount = Object.values(secrets).filter(s => s.has_value && !s.is_default).length;
    
    // Set status message
    if (defaultCount === Object.keys(secrets).length) {
        statusEl.className = 'popout-status warning';
        statusEl.innerHTML = '⚠️ All secrets need configuration. Generate secure values below.';
    } else if (defaultCount > 0) {
        statusEl.className = 'popout-status warning';
        statusEl.innerHTML = `⚠️ ${defaultCount} secrets need attention. ${configuredCount} configured.`;
    } else {
        statusEl.className = 'popout-status success';
        statusEl.innerHTML = '✅ All secrets configured! You can keep or regenerate them.';
    }
    
    // Group by category
    const categories = data.categories;
    const byCategory = {};
    for (const [key, info] of Object.entries(secrets)) {
        const cat = info.category || 'other';
        if (!byCategory[cat]) byCategory[cat] = [];
        byCategory[cat].push({ key, ...info });
    }
    
    // Sort categories
    const sortedCategories = Object.entries(categories).sort((a, b) => a[1].order - b[1].order);
    
    // Build HTML
    let html = `
        <div class="secrets-legend">
            <small>🔵 Database Credentials | 🔑 API Secrets | Target Files: each secret syncs to multiple config files</small>
        </div>
    `;
    
    for (const [catKey, catInfo] of sortedCategories) {
        const fields = byCategory[catKey] || [];
        if (fields.length === 0) continue;
        
        html += `<div class="secrets-category">
            <h4>${catInfo.label}</h4>
            <div class="secrets-fields">`;
        
        for (const info of fields) {
            const key = info.key;
            const hasGoodValue = info.has_value && !info.is_default;
            const currentValue = info.current_value || '';
            
            // Initialize choice - store current value for editing
            secretFieldChoices[key] = {
                mode: hasGoodValue ? 'keep' : 'generate',
                custom: '',
                currentValue: currentValue,
                length: info.generate_length || 32
            };
            
            const statusIcon = hasGoodValue ? '✅' : info.has_value ? '⚠️' : '❌';
            const maskedValue = currentValue ? '•'.repeat(Math.min(currentValue.length, 20)) : '';
            
            // Build target files display
            const targetFiles = info.target_files || [];
            const targetNames = targetFiles.map(f => {
                // Convert file path to friendly name
                if (f.includes('dragonite')) return 'Dragonite';
                if (f.includes('golbat')) return 'Golbat';
                if (f.includes('rotom')) return 'Rotom';
                if (f.includes('reactmap')) return 'ReactMap';
                if (f.includes('koji')) return 'Koji';
                if (f.includes('poracle')) return 'Poracle';
                if (f === '.env') return '.env';
                return f.split('/').pop();
            });
            const targetDisplay = targetNames.join(', ');
            const targetTooltip = targetFiles.join('\\n');
            
            html += `
                <div class="password-field-item" id="pwd-row-${key}" style="border-left: 3px solid ${info.color}">
                    <div class="field-info">
                        <div class="field-label">${info.label}</div>
                        <small class="field-desc" title="${info.desc}">${info.desc}</small>
                        <small class="target-count" title="${targetTooltip}">📄 ${targetDisplay}</small>
                    </div>
                    <div class="field-controls">
                        <select id="pwd-mode-${key}" onchange="onSecretModeChange('${key}')">
                            ${hasGoodValue ? '<option value="keep">Keep</option>' : ''}
                            <option value="generate" ${!hasGoodValue ? 'selected' : ''}>Generate</option>
                            <option value="custom">Custom</option>
                        </select>
                        ${hasGoodValue ? `
                        <span class="current-value-display" id="pwd-display-${key}" onclick="editCurrentSecret('${key}')" title="Click to edit">
                            <span class="masked-value" id="pwd-masked-${key}">${maskedValue}</span>
                            <button type="button" class="btn btn-xs show-btn" onclick="event.stopPropagation(); toggleSecretVisibility('${key}')" title="Show/Hide">👁</button>
                        </span>
                        ` : ''}
                        <input type="text" 
                               id="pwd-input-${key}" 
                               placeholder="${hasGoodValue ? '' : 'Auto-generate'}"
                               ${hasGoodValue ? 'style="display:none;"' : ''}
                               ${secretFieldChoices[key].mode !== 'custom' ? 'disabled' : ''}
                               class="secret-input ${hasGoodValue ? 'has-value' : info.is_default ? 'is-weak' : ''}"
                               oninput="onSecretInput('${key}')"
                               autocomplete="off"
                               spellcheck="false"
                        >
                        <div class="field-actions">
                            <button class="btn btn-xs" onclick="generateSingleSecret('${key}')" title="Generate random">🎲</button>
                            <span class="status-icon">${statusIcon}</span>
                        </div>
                    </div>
                </div>
            `;
        }
        
        html += '</div></div>';
    }
    
    container.innerHTML = html;
}

function onSecretModeChange(key) {
    const mode = document.getElementById(`pwd-mode-${key}`).value;
    const input = document.getElementById(`pwd-input-${key}`);
    const display = document.getElementById(`pwd-display-${key}`);
    
    secretFieldChoices[key].mode = mode;
    
    if (mode === 'custom') {
        input.disabled = false;
        input.style.display = '';
        input.value = secretFieldChoices[key].custom || '';
        input.placeholder = 'Enter value...';
        input.focus();
        if (display) display.style.display = 'none';
    } else if (mode === 'keep') {
        input.disabled = true;
        input.style.display = 'none';
        input.value = '';
        if (display) display.style.display = '';
    } else { // generate
        input.disabled = true;
        input.style.display = '';
        input.value = '';
        input.placeholder = 'Auto-generate';
        if (display) display.style.display = 'none';
    }
}

function toggleSecretVisibility(key) {
    const masked = document.getElementById(`pwd-masked-${key}`);
    const currentValue = secretFieldChoices[key]?.currentValue || '';
    
    if (masked.dataset.visible === 'true') {
        masked.textContent = '•'.repeat(Math.min(currentValue.length, 20));
        masked.dataset.visible = 'false';
    } else {
        masked.textContent = currentValue;
        masked.dataset.visible = 'true';
    }
}

function editCurrentSecret(key) {
    const select = document.getElementById(`pwd-mode-${key}`);
    const input = document.getElementById(`pwd-input-${key}`);
    const display = document.getElementById(`pwd-display-${key}`);
    const currentValue = secretFieldChoices[key]?.currentValue || '';
    
    // Switch to custom mode with current value
    select.value = 'custom';
    secretFieldChoices[key].mode = 'custom';
    secretFieldChoices[key].custom = currentValue;
    
    input.disabled = false;
    input.style.display = '';
    input.value = currentValue;
    input.focus();
    input.select();
    
    if (display) display.style.display = 'none';
}

function onSecretInput(key) {
    const input = document.getElementById(`pwd-input-${key}`);
    secretFieldChoices[key].custom = input.value;
}

async function generateSingleSecret(key) {
    const input = document.getElementById(`pwd-input-${key}`);
    const select = document.getElementById(`pwd-mode-${key}`);
    
    // Generate random alphanumeric string
    const length = secretFieldChoices[key]?.length || 32;
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    const newValue = Array.from(crypto.getRandomValues(new Uint8Array(length)))
        .map(b => chars[b % chars.length]).join('');
    
    // Set to custom mode with generated value
    select.value = 'custom';
    input.disabled = false;
    input.type = document.getElementById('showPasswordsCheckbox')?.checked ? 'text' : 'password';
    input.value = newValue;
    input.classList.add('has-value');
    secretFieldChoices[key] = { mode: 'custom', custom: newValue, length };
    
    const label = currentSecretsData?.secrets[key]?.label || key;
    showToast(`Generated new value for ${label}`, 'success');
}

async function generateAllPasswords() {
    // Generate all using backend API for consistency
    try {
        const response = await fetch('/api/secrets/generate', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ secrets: Object.keys(secretFieldChoices) })
        });
        
        if (!response.ok) throw new Error('Failed to generate');
        const data = await response.json();
        
        for (const [key, value] of Object.entries(data.generated)) {
            const input = document.getElementById(`pwd-input-${key}`);
            const select = document.getElementById(`pwd-mode-${key}`);
            
            if (input && select) {
                select.value = 'custom';
                input.disabled = false;
                input.type = document.getElementById('showPasswordsCheckbox')?.checked ? 'text' : 'password';
                input.value = value;
                input.classList.add('has-value');
                secretFieldChoices[key] = { 
                    mode: 'custom', 
                    custom: value, 
                    length: currentSecretsData?.secrets[key]?.generate_length || 32 
                };
            }
        }
        
        showToast('Generated all new secrets', 'success');
    } catch (e) {
        showToast('Failed to generate: ' + e.message, 'error');
    }
}

function togglePasswordVisibility() {
    const show = document.getElementById('showPasswordsCheckbox')?.checked;
    document.querySelectorAll('.password-field-item input').forEach(input => {
        input.type = show ? 'text' : 'password';
    });
}

async function applyPasswordChoices() {
    const secretsToApply = {};
    
    // Collect values to apply
    for (const [key, choice] of Object.entries(secretFieldChoices)) {
        if (choice.mode === 'custom' && choice.custom) {
            secretsToApply[key] = choice.custom;
        } else if (choice.mode === 'generate') {
            // Generate a new value
            const length = choice.length || 32;
            const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
            secretsToApply[key] = Array.from(crypto.getRandomValues(new Uint8Array(length)))
                .map(b => chars[b % chars.length]).join('');
        }
        // 'keep' mode secrets are not included - they stay unchanged
    }
    
    if (Object.keys(secretsToApply).length === 0) {
        showToast('No secrets to apply (all set to keep)', 'info');
        return;
    }
    
    showToast('Applying secrets to all config files...', 'info');
    
    try {
        // Apply secrets to ALL target files
        const response = await fetch('/api/secrets/apply', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ secrets: secretsToApply })
        });
        
        if (!response.ok) throw new Error('Failed to apply secrets');
        const result = await response.json();
        
        // Show detailed results in wizard output
        showWizardOutput('', true);
        appendWizardOutput('═'.repeat(60) + '\\n');
        appendWizardOutput('  🔐 SECRETS APPLIED - COPY THESE VALUES NOW!\\n');
        appendWizardOutput('═'.repeat(60) + '\\n\\n');
        
        for (const [key, value] of Object.entries(secretsToApply)) {
            appendWizardOutput(`${key}=${value}\\n`);
        }
        
        appendWizardOutput('\\n' + '─'.repeat(60) + '\\n');
        appendWizardOutput('📁 FILES UPDATED:\\n');
        
        let totalUpdated = 0;
        for (const secretResult of result.results) {
            if (secretResult.targets_updated > 0) {
                appendWizardOutput(`\\n${secretResult.label}:\\n`);
                for (const detail of secretResult.details) {
                    if (detail.status === 'success') {
                        appendWizardOutput(`  ✅ ${detail.file}\\n`, 'success');
                        totalUpdated++;
                    } else if (detail.status === 'error') {
                        appendWizardOutput(`  ❌ ${detail.file}: ${detail.reason}\\n`, 'error');
                    }
                }
            }
        }
        
        appendWizardOutput('\\n' + '═'.repeat(60) + '\\n');
        appendWizardOutput(`\\n✅ Updated ${totalUpdated} config files total\\n`, 'success');
        appendWizardOutput('\\n⚠️ Save these credentials securely!\\n', 'warning');
        appendWizardOutput('Restart containers to apply: docker compose up -d\\n');
        
        closePasswordPanel();
        updateStepStatus('passwords', true, `${Object.keys(secretsToApply).length} secrets applied`);
        showToast(`✅ Applied ${Object.keys(secretsToApply).length} secrets to ${totalUpdated} files!`, 'success');
        await refreshWizardStatus();
        
    } catch (e) {
        showToast(`Failed to apply secrets: ${e.message}`, 'error');
    }
}

async function mariadbSetupStep() {
    appendWizardOutput('Loading MariaDB status...\\n');
    
    try {
        const response = await fetch('/api/mariadb/status');
        if (!response.ok) throw new Error('Failed to load MariaDB status');
        const status = await response.json();
        
        // Show current status
        appendWizardOutput('\\n━━━━━━ MariaDB Status ━━━━━━\\n');
        
        if (status.container.running) {
            appendWizardOutput('✓ Database container is running\\n', 'success');
            if (status.container.version) {
                appendWizardOutput(`  Version: ${status.container.version}\\n`);
            }
        } else {
            appendWizardOutput('⚠️ Database container not running\\n', 'warning');
            appendWizardOutput('  Start the stack first, or run only the database container\\n');
        }
        
        if (status.container.accessible) {
            appendWizardOutput('✓ Database connection verified\\n', 'success');
        }
        
        // Get credentials
        const credResponse = await fetch('/api/mariadb/credentials');
        const credentials = await credResponse.json();
        
        // Show the setup panel
        showMariaDBSetupPanel(status, credentials);
        
    } catch (e) {
        appendWizardOutput(`\\n❌ Error: ${e.message}\\n`, 'error');
    }
}

function showMariaDBSetupPanel(status, credentials) {
    // Remove existing panel if present
    let panel = document.getElementById('mariadbSetupPanel');
    if (panel) panel.remove();
    
    // Build databases status HTML
    let dbStatusHtml = '';
    const databases = ['dragonite', 'golbat', 'reactmap', 'koji', 'poracle'];
    for (const db of databases) {
        const dbInfo = status.databases[db] || { exists: false };
        const statusIcon = dbInfo.exists ? '✅' : '⚪';
        const sizeInfo = dbInfo.size ? ` (${dbInfo.size})` : '';
        dbStatusHtml += `<span class="db-status-item">${statusIcon} ${db}${sizeInfo}</span>`;
    }
    
    const html = `
        <div id="mariadbSetupPanel" class="wizard-popout-panel" style="margin-top: 15px;">
            <div class="popout-header">
                <h4>🗄️ MariaDB Setup</h4>
                <button class="btn btn-sm" onclick="closeMariaDBSetupPanel()">✖ Close</button>
            </div>
            <div class="popout-body">
                <p class="popout-hint">Configure MariaDB databases and users for Aegis AIO stack.</p>
                
                <!-- Status Section -->
                <div class="mariadb-status-section">
                    <div class="status-row">
                        <span class="status-label">Container:</span>
                        <span class="status-value ${status.container.running ? 'status-ok' : 'status-warn'}">
                            ${status.container.running ? '🟢 Running' : '🔴 Not Running'}
                        </span>
                    </div>
                    <div class="status-row">
                        <span class="status-label">Connection:</span>
                        <span class="status-value ${status.container.accessible ? 'status-ok' : 'status-warn'}">
                            ${status.container.accessible ? '🟢 Accessible' : '🟡 Not tested'}
                        </span>
                    </div>
                    <div class="status-row">
                        <span class="status-label">Databases:</span>
                        <div class="db-status-grid">${dbStatusHtml}</div>
                    </div>
                </div>
                
                <!-- Credentials Form -->
                <div class="config-fields-form" style="margin-top: 15px;">
                    <h5 style="margin-bottom: 10px;">Database Credentials</h5>
                    
                    <div class="config-field-item">
                        <label class="field-label">Root Username</label>
                        <div class="field-description">MariaDB root user (usually 'root')</div>
                        <input type="text" id="mariadb-root-user" class="form-input" 
                               value="root" placeholder="root" readonly>
                    </div>
                    
                    <div class="config-field-item">
                        <label class="field-label">Root Password</label>
                        <div class="field-description">From password setup step (MYSQL_ROOT_PASSWORD)</div>
                        <input type="text" id="mariadb-root-password" class="form-input" 
                               value="${credentials.root_password || ''}" 
                               placeholder="Set in Passwords step">
                    </div>
                    
                    <div class="config-field-item">
                        <label class="field-label">Application Username</label>
                        <div class="field-description">Username for Aegis services (Dragonite, Golbat, etc.)</div>
                        <input type="text" id="mariadb-db-user" class="form-input" 
                               value="${credentials.db_user || 'dbuser'}" placeholder="dbuser">
                    </div>
                    
                    <div class="config-field-item">
                        <label class="field-label">Application Password</label>
                        <div class="field-description">From password setup step (MYSQL_PASSWORD)</div>
                        <input type="text" id="mariadb-db-password" class="form-input" 
                               value="${credentials.db_password || ''}" 
                               placeholder="Set in Passwords step">
                    </div>
                    
                    <h5 style="margin: 15px 0 10px 0;">Databases to Create</h5>
                    <div class="databases-checkboxes">
                        ${databases.map(db => `
                            <label class="checkbox-item">
                                <input type="checkbox" id="mariadb-db-${db}" checked 
                                       ${status.databases[db]?.exists ? 'disabled' : ''}>
                                <span>${db}</span>
                                ${status.databases[db]?.exists ? '<span class="exists-badge">exists</span>' : ''}
                            </label>
                        `).join('')}
                    </div>
                </div>
                
                <!-- Optimization Section -->
                <div class="optimization-section" style="margin-top: 15px; padding: 10px; background: var(--bg-tertiary); border-radius: var(--radius-md);">
                    <h5 style="margin-bottom: 10px;">⚡ Performance Optimization</h5>
                    <p style="font-size: 0.85em; opacity: 0.8; margin-bottom: 10px;">
                        Optimize MariaDB based on your system resources (run "Detect Resources" first)
                    </p>
                    <button class="btn btn-secondary btn-sm" onclick="applyMariaDBOptimization()">
                        📊 Apply Optimized Settings
                    </button>
                </div>
                
                <!-- Test Connection -->
                <div style="margin-top: 15px;">
                    <p style="font-size: 0.85em; opacity: 0.8; margin-bottom: 8px;">
                        Test connection directly to localhost:3306
                    </p>
                    <button class="btn btn-secondary" onclick="testMariaDBConnection('root')">
                        🔌 Test Root (localhost:3306)
                    </button>
                    <button class="btn btn-secondary" onclick="testMariaDBConnection('user')">
                        🔌 Test User (localhost:3306)
                    </button>
                </div>
            </div>
            <div class="popout-footer">
                <button class="btn btn-secondary" onclick="closeMariaDBSetupPanel()">Cancel</button>
                <button class="btn btn-success" onclick="runMariaDBSetup()">
                    🚀 Setup Databases & Users
                </button>
            </div>
        </div>
    `;
    
    // Insert after the wizard steps grid
    const stepsGrid = document.querySelector('.wizard-steps-grid');
    if (stepsGrid) {
        stepsGrid.insertAdjacentHTML('afterend', html);
    } else {
        const wizardContent = document.getElementById('wizardContent');
        if (wizardContent) {
            wizardContent.insertAdjacentHTML('beforeend', html);
        }
    }
    
    document.getElementById('mariadbSetupPanel')?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function closeMariaDBSetupPanel() {
    const panel = document.getElementById('mariadbSetupPanel');
    if (panel) panel.remove();
}

async function testMariaDBConnection(type) {
    const rootPass = document.getElementById('mariadb-root-password')?.value || '';
    const dbUser = document.getElementById('mariadb-db-user')?.value || '';
    const dbPass = document.getElementById('mariadb-db-password')?.value || '';
    
    const user = type === 'root' ? 'root' : dbUser;
    const password = type === 'root' ? rootPass : dbPass;
    
    if (!password) {
        showToast(`Please enter ${type === 'root' ? 'root' : 'user'} password first`, 'warning');
        return;
    }
    
    showToast(`Testing ${type} connection to localhost:3306...`, 'info');
    appendWizardOutput(`\\nTesting ${type} connection to localhost:3306...\\n`);
    
    try {
        const response = await fetch('/api/mariadb/test-connection', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ 
                user, 
                password,
                host: 'localhost',
                port: 3306
            })
        });
        
        const data = await response.json();
        
        if (data.success) {
            const typeLabel = type.charAt(0).toUpperCase() + type.slice(1);
            appendWizardOutput(`✅ ${typeLabel} connection successful!\\n`, 'success');
            appendWizardOutput(`   Host: ${data.details.host || 'localhost'}:${data.details.port || 3306}\\n`);
            if (data.details.version) {
                appendWizardOutput(`   Version: ${data.details.version}\\n`);
            }
            if (data.details.method) {
                appendWizardOutput(`   Method: ${data.details.method}\\n`);
            }
            if (data.details.note) {
                appendWizardOutput(`   ℹ️ ${data.details.note}\\n`, 'info');
            }
            showToast('Connection successful!', 'success');
        } else {
            appendWizardOutput(`❌ Connection failed: ${data.message}\\n`, 'error');
            if (data.details?.port_open === false) {
                appendWizardOutput('   Port 3306 is not open. Is MariaDB running?\\n', 'warning');
            }
            showToast(`Connection failed: ${data.message}`, 'error');
        }
    } catch (e) {
        appendWizardOutput(`❌ Error: ${e.message}\\n`, 'error');
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function runMariaDBSetup() {
    const rootPass = document.getElementById('mariadb-root-password')?.value || '';
    const dbUser = document.getElementById('mariadb-db-user')?.value || '';
    const dbPass = document.getElementById('mariadb-db-password')?.value || '';
    
    if (!rootPass) {
        showToast('Root password is required', 'error');
        return;
    }
    
    if (!dbUser || !dbPass) {
        showToast('Application username and password are required', 'error');
        return;
    }
    
    // Get selected databases
    const databases = ['dragonite', 'golbat', 'reactmap', 'koji', 'poracle'].filter(db => {
        const checkbox = document.getElementById(`mariadb-db-${db}`);
        return checkbox && (checkbox.checked || checkbox.disabled);
    });
    
    showToast('Running MariaDB setup...', 'info');
    appendWizardOutput('\\n━━━━━━ Running MariaDB Setup ━━━━━━\\n');
    
    try {
        const response = await fetch('/api/mariadb/setup', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                root_password: rootPass,
                db_user: dbUser,
                db_password: dbPass,
                databases: databases
            })
        });
        
        const data = await response.json();
        
        // Show steps
        for (const step of data.steps || []) {
            appendWizardOutput(`${step}\\n`, 'success');
        }
        
        // Show errors
        for (const error of data.errors || []) {
            appendWizardOutput(`❌ ${error}\\n`, 'error');
        }
        
        if (data.success) {
            appendWizardOutput('\\n✅ MariaDB setup complete!\\n', 'success');
            showToast('MariaDB setup complete!', 'success');
            updateStepStatus('mariadb', true, 'Databases ready');
            closeMariaDBSetupPanel();
            await refreshWizardStatus();
        } else {
            appendWizardOutput('\\n⚠️ Setup completed with errors\\n', 'warning');
            showToast('Setup completed with some errors', 'warning');
        }
        
    } catch (e) {
        appendWizardOutput(`❌ Error: ${e.message}\\n`, 'error');
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function applyMariaDBOptimization() {
    if (!detectedResources) {
        showToast('Please run "Detect Resources" step first', 'warning');
        appendWizardOutput('⚠️ Please run "Detect Resources" first.\\n', 'warning');
        return;
    }
    
    appendWizardOutput('\\nApplying optimized MariaDB settings...\\n');
    
    const settings = {
        'innodb_buffer_pool_size': detectedResources.recommended.innodb_buffer_pool_size,
        'innodb_buffer_pool_instances': detectedResources.recommended.innodb_buffer_pool_instances,
        'innodb_read_io_threads': detectedResources.recommended.innodb_io_threads,
        'innodb_write_io_threads': detectedResources.recommended.innodb_io_threads,
        'max_connections': detectedResources.recommended.max_connections,
        'tmp_table_size': detectedResources.recommended.tmp_table_size,
        'max_heap_table_size': detectedResources.recommended.tmp_table_size
    };
    
    try {
        const response = await fetch('/api/wizard/apply-mariadb-config', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ settings })
        });
        
        if (!response.ok) throw new Error('Failed to apply MariaDB config');
        
        appendWizardOutput('Applied settings:\\n');
        for (const [key, value] of Object.entries(settings)) {
            appendWizardOutput(`  ${key} = ${value}\\n`);
        }
        
        appendWizardOutput('\\n✅ MariaDB configuration optimized!\\n', 'success');
        showToast('MariaDB optimization applied', 'success');
    } catch (e) {
        appendWizardOutput(`❌ Error: ${e.message}\\n`, 'error');
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function configureLoggingStep() {
    appendWizardOutput('Loading Docker logging configuration...\\n');
    
    try {
        const response = await fetch('/api/docker/logging/config');
        if (!response.ok) throw new Error('Failed to load config');
        const data = await response.json();
        
        // Show current status
        if (data.exists) {
            appendWizardOutput('✓ /etc/docker/daemon.json exists\\n', 'success');
        } else {
            appendWizardOutput('⚠️ /etc/docker/daemon.json does not exist (will be created)\\n', 'warning');
        }
        
        if (data.docker_running) {
            appendWizardOutput('✓ Docker service is running\\n', 'success');
        } else {
            appendWizardOutput('⚠️ Docker service is not running\\n', 'warning');
        }
        
        // Get current/default values
        const merged = data.merged || data.defaults;
        const logOpts = merged['log-opts'] || {};
        
        // Show form panel
        showDockerLoggingPanel(merged, logOpts, data.docker_running);
        
    } catch (e) {
        appendWizardOutput(`\\n❌ Error: ${e.message}\\n`, 'error');
    }
}

function showDockerLoggingPanel(config, logOpts, dockerRunning) {
    // Check if panel already exists
    let panel = document.getElementById('dockerLoggingPanel');
    if (panel) {
        panel.remove();
    }
    
    // Create the panel
    const html = `
        <div id="dockerLoggingPanel" class="wizard-popout-panel" style="margin-top: 15px;">
            <div class="popout-header">
                <h4>🐳 Docker Logging Configuration</h4>
                <button class="btn btn-sm" onclick="closeDockerLoggingPanel()">✖ Close</button>
            </div>
            <div class="popout-body">
                <p class="popout-hint">Configure Docker log rotation to prevent disk space issues. These settings apply to all containers.</p>
                
                <div class="config-fields-form">
                    <div class="config-field-item">
                        <label class="field-label">Log Driver</label>
                        <div class="field-description">The logging driver for containers (json-file recommended)</div>
                        <select id="docker-log-driver" class="form-input">
                            <option value="json-file" ${config['log-driver'] === 'json-file' ? 'selected' : ''}>json-file (recommended)</option>
                            <option value="local" ${config['log-driver'] === 'local' ? 'selected' : ''}>local</option>
                            <option value="journald" ${config['log-driver'] === 'journald' ? 'selected' : ''}>journald</option>
                            <option value="syslog" ${config['log-driver'] === 'syslog' ? 'selected' : ''}>syslog</option>
                            <option value="none" ${config['log-driver'] === 'none' ? 'selected' : ''}>none (disable logging)</option>
                        </select>
                    </div>
                    
                    <div class="config-field-item">
                        <label class="field-label">Max Log Size</label>
                        <div class="field-description">Maximum size of each log file before rotation (e.g., 50m, 100m, 1g)</div>
                        <input type="text" id="docker-log-max-size" class="form-input" 
                               value="${logOpts['max-size'] || '100m'}" placeholder="100m">
                    </div>
                    
                    <div class="config-field-item">
                        <label class="field-label">Max Log Files</label>
                        <div class="field-description">Number of rotated log files to keep per container</div>
                        <input type="number" id="docker-log-max-file" class="form-input" 
                               value="${logOpts['max-file'] || '3'}" min="1" max="10" placeholder="3">
                    </div>
                    
                    <div class="config-field-item">
                        <label class="field-label">Compress Logs</label>
                        <div class="field-description">Compress rotated log files to save disk space</div>
                        <label class="switch">
                            <input type="checkbox" id="docker-log-compress" 
                                   ${logOpts['compress'] === 'true' || logOpts['compress'] === true ? 'checked' : ''}>
                            <span class="slider round"></span>
                        </label>
                    </div>
                </div>
                
                <div class="popout-info" style="margin-top: 15px; padding: 10px; background: var(--bg-tertiary); border-radius: var(--radius-md);">
                    <strong>💡 Tip:</strong> With these settings, each container will use max <span id="docker-log-total">300MB</span> of disk space for logs.
                    <br><small>Docker restart required after saving changes.</small>
                </div>
            </div>
            <div class="popout-footer">
                <button class="btn btn-secondary" onclick="resetDockerLoggingDefaults()">↩️ Reset to Defaults</button>
                <div class="popout-actions">
                    <button class="btn btn-success" onclick="saveDockerLoggingConfig(${dockerRunning})">💾 Save & Apply</button>
                </div>
            </div>
        </div>
    `;
    
    // Insert after the wizard steps grid
    const stepsGrid = document.querySelector('.wizard-steps-grid');
    if (stepsGrid) {
        stepsGrid.insertAdjacentHTML('afterend', html);
    } else {
        // Fallback - append to wizard content
        const wizardContent = document.getElementById('wizardContent');
        if (wizardContent) {
            wizardContent.insertAdjacentHTML('beforeend', html);
        }
    }
    
    // Update disk usage calculation when values change
    document.getElementById('docker-log-max-size')?.addEventListener('input', updateDockerLogDiskUsage);
    document.getElementById('docker-log-max-file')?.addEventListener('input', updateDockerLogDiskUsage);
    updateDockerLogDiskUsage();
    
    // Scroll panel into view
    document.getElementById('dockerLoggingPanel')?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function updateDockerLogDiskUsage() {
    const maxSize = document.getElementById('docker-log-max-size')?.value || '100m';
    const maxFile = parseInt(document.getElementById('docker-log-max-file')?.value || '3');
    
    // Parse size
    let sizeNum = parseInt(maxSize);
    let unit = maxSize.replace(/[0-9]/g, '').toLowerCase() || 'm';
    
    // Calculate total in MB
    let totalMB = sizeNum * maxFile;
    if (unit === 'g') totalMB = sizeNum * 1024 * maxFile;
    if (unit === 'k') totalMB = (sizeNum / 1024) * maxFile;
    
    const totalEl = document.getElementById('docker-log-total');
    if (totalEl) {
        if (totalMB >= 1024) {
            totalEl.textContent = `${(totalMB / 1024).toFixed(1)}GB`;
        } else {
            totalEl.textContent = `${totalMB}MB`;
        }
    }
}

function resetDockerLoggingDefaults() {
    document.getElementById('docker-log-driver').value = 'json-file';
    document.getElementById('docker-log-max-size').value = '100m';
    document.getElementById('docker-log-max-file').value = '3';
    document.getElementById('docker-log-compress').checked = true;
    updateDockerLogDiskUsage();
    showToast('Reset to recommended defaults', 'info');
}

function closeDockerLoggingPanel() {
    const panel = document.getElementById('dockerLoggingPanel');
    if (panel) panel.remove();
}

async function saveDockerLoggingConfig(dockerRunning) {
    const config = {
        log_driver: document.getElementById('docker-log-driver')?.value || 'json-file',
        max_size: document.getElementById('docker-log-max-size')?.value || '100m',
        max_file: document.getElementById('docker-log-max-file')?.value || '3',
        compress: document.getElementById('docker-log-compress')?.checked || false
    };
    
    showToast('Saving Docker logging configuration...', 'info');
    appendWizardOutput('\\nSaving Docker logging configuration...\\n');
    
    try {
        const response = await fetch('/api/docker/logging/config', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(config)
        });
        
        const data = await response.json();
        
        if (data.success) {
            appendWizardOutput('✅ Configuration saved to /etc/docker/daemon.json\\n', 'success');
            
            // Ask to restart Docker
            if (dockerRunning && data.restart_required) {
                appendWizardOutput('\\n⚠️ Docker restart required to apply changes.\\n', 'warning');
                
                if (confirm('Docker needs to restart to apply changes. This will briefly stop all containers.\\n\\nRestart Docker now?')) {
                    appendWizardOutput('Restarting Docker service...\\n');
                    
                    const restartResponse = await fetch('/api/docker/logging/restart', { method: 'POST' });
                    const restartData = await restartResponse.json();
                    
                    if (restartData.success) {
                        appendWizardOutput('✅ Docker service restarted successfully!\\n', 'success');
                        showToast('Docker logging configured and service restarted', 'success');
                        updateStepStatus('logging', true, 'Log rotation enabled');
                    } else {
                        appendWizardOutput(`❌ Restart failed: ${restartData.error}\\n`, 'error');
                        showToast('Config saved but restart failed', 'warning');
                    }
                } else {
                    appendWizardOutput('\\nℹ️ Remember to restart Docker manually:\\n');
                    appendWizardOutput('  sudo systemctl restart docker\\n', 'code');
                    showToast('Config saved - restart Docker to apply', 'info');
                    updateStepStatus('logging', true, 'Restart required');
                }
            } else {
                showToast('Docker logging configuration saved', 'success');
                updateStepStatus('logging', true, 'Log rotation enabled');
            }
            
            closeDockerLoggingPanel();
            await refreshWizardStatus();
            
        } else {
            appendWizardOutput(`❌ Failed to save: ${data.error}\\n`, 'error');
            showToast(`Save failed: ${data.error}`, 'error');
        }
        
    } catch (e) {
        appendWizardOutput(`❌ Error: ${e.message}\\n`, 'error');
        showToast(`Error: ${e.message}`, 'error');
    }
}

async function startStackStep() {
    if (!wizardStatus?.ready_to_start) {
        appendWizardOutput('⚠️ Complete previous steps before starting the stack.\\n', 'warning');
        return;
    }
    
    appendWizardOutput('Starting Docker stack...\\n');
    appendWizardOutput('This may take a few minutes as images are pulled.\\n\\n');
    
    const response = await fetch('/api/wizard/start-stack', { method: 'POST' });
    if (!response.ok) throw new Error('Failed to start stack');
    const data = await response.json();
    
    if (data.success) {
        appendWizardOutput('\\n✅ Stack started successfully!\\n', 'success');
        appendWizardOutput('\\nContainers are now starting. Check the Containers page for status.\\n');
        updateStepStatus('start', true, 'Stack running');
    } else {
        appendWizardOutput('\\n❌ Stack start failed:\\n', 'error');
        appendWizardOutput(data.stderr || data.error || 'Unknown error');
    }
}

function showWizardOutput(title, clear = false) {
    const panel = document.getElementById('wizardOutputPanel');
    const titleEl = document.getElementById('wizardOutputTitle');
    const contentEl = document.getElementById('wizardOutputContent');
    
    if (panel) panel.style.display = 'block';
    if (titleEl) titleEl.textContent = title;
    if (contentEl && clear) contentEl.innerHTML = '';
}

function appendWizardOutput(text, type = '') {
    const contentEl = document.getElementById('wizardOutputContent');
    if (!contentEl) return;
    
    const span = document.createElement('span');
    span.className = `wizard-output-${type}`;
    span.textContent = text.replace(/\\n/g, '\n');
    contentEl.appendChild(span);
    contentEl.scrollTop = contentEl.scrollHeight;
}

function closeWizardOutput() {
    const panel = document.getElementById('wizardOutputPanel');
    if (panel) panel.style.display = 'none';
}

// Initialize wizard when navigating to setup page
document.addEventListener('DOMContentLoaded', () => {
    // Check if we're on setup page
    const setupTab = document.getElementById('setup-tab-scripts');
    if (setupTab) {
        // Only auto-refresh if wizard was already started
        const observer = new MutationObserver((mutations) => {
            for (const mutation of mutations) {
                if (mutation.attributeName === 'class' && 
                    setupTab.classList.contains('active') && 
                    wizardStarted) {
                    refreshWizardStatus();
                }
            }
        });
        observer.observe(setupTab, { attributes: true });
    }
});

// =============================================================================
// SHELLDER CONFIGURATION PAGE
// =============================================================================

let shellderConfigData = null;
let currentEditingComponent = null;

// Component icons mapping
const componentIcons = {
    database: '🗄️',
    dragonite: '🐉',
    golbat: '🦇',
    rotom: '📱',
    xilriws: '🔐',
    reactmap: '🗺️',
    koji: '📍',
    poracle: '🔔',
    fletchling: '🪺',
    grafana: '📊',
    victoriametrics: '📈',
    phpmyadmin: '🔧',
    shellder: '🐚'
};

// Load Shellder configuration
async function loadShellderConfig() {
    try {
        const data = await fetchAPI('/api/stack-config/components');
        shellderConfigData = data;
        
        // Update stats
        const enabled = data.components.filter(c => c.enabled).length;
        const local = data.components.filter(c => c.enabled && c.local).length;
        const remote = data.components.filter(c => c.enabled && !c.local).length;
        
        // Helper to safely update element text
        const setElementText = (id, text) => {
            const el = document.getElementById(id);
            if (el) el.textContent = text;
        };
        
        setElementText('shellderConfigStatus', data.config_loaded ? '✓ Loaded' : '✗ Not Loaded');
        setElementText('shellderComponentsEnabled', `${enabled}/${data.components.length}`);
        setElementText('shellderLocalComponents', local.toString());
        setElementText('shellderRemoteComponents', remote.toString());
        
        // Render components grid
        renderShellderComponents(data.components);
        
        // Load general settings
        loadShellderGeneralSettings();
        
        // Load AI Debug toggle status
        loadAIDebugMasterToggle();
        
    } catch (error) {
        console.error('Error loading Shellder config:', error);
        showToast('Failed to load configuration', 'error');
    }
}

// Render components grid
function renderShellderComponents(components) {
    const container = document.getElementById('shellderComponentsGrid');
    if (!container) return;
    
    if (!components || components.length === 0) {
        container.innerHTML = '<div class="empty-state">No components configured</div>';
        return;
    }
    
    container.innerHTML = components.map(comp => `
        <div class="component-card ${comp.enabled ? '' : 'disabled'}" onclick="editComponent('${comp.name}')">
            <div class="component-card-header">
                <div class="component-card-title">
                    <span class="icon">${componentIcons[comp.name] || '📦'}</span>
                    <h3>${comp.name}</h3>
                </div>
                <div class="component-card-badges">
                    <span class="component-badge ${comp.enabled ? 'enabled' : 'disabled'}">
                        ${comp.enabled ? 'Enabled' : 'Disabled'}
                    </span>
                    <span class="component-badge ${comp.local ? 'local' : 'remote'}">
                        ${comp.local ? 'Local' : 'Remote'}
                    </span>
                </div>
            </div>
            <div class="component-card-details">
                <div class="component-detail">
                    <span class="component-detail-label">${comp.local ? 'Container' : 'Host'}</span>
                    <span class="component-detail-value">${comp.local ? comp.container : comp.host}</span>
                </div>
                <div class="component-detail">
                    <span class="component-detail-label">Port</span>
                    <span class="component-detail-value">${comp.port || '-'}</span>
                </div>
                ${comp.config_file ? `
                <div class="component-detail full-width">
                    <span class="component-detail-label">Config</span>
                    <span class="component-detail-value">${comp.config_file.split('/').pop()}</span>
                </div>
                ` : ''}
            </div>
        </div>
    `).join('');
}

// Load general settings
async function loadShellderGeneralSettings() {
    try {
        const data = await fetchAPI('/api/stack-config');
        
        // Update general paths
        const pathsContainer = document.getElementById('shellderGeneralPaths');
        if (pathsContainer && data.general) {
            pathsContainer.innerHTML = `
                <div class="info-item">
                    <span class="info-label">Aegis Root</span>
                    <span class="info-value">${data.aegis_root || 'Auto-detected'}</span>
                </div>
                <div class="info-item">
                    <span class="info-label">Docker Compose</span>
                    <span class="info-value">${data.general.docker_compose_file || 'docker-compose.yaml'}</span>
                </div>
                <div class="info-item">
                    <span class="info-label">Environment File</span>
                    <span class="info-value">${data.general.env_file || '.env'}</span>
                </div>
                <div class="info-item">
                    <span class="info-label">Config File</span>
                    <span class="info-value">${data.config_file || 'Not found'}</span>
                </div>
            `;
        }
        
        // Update remote settings
        const remoteContainer = document.getElementById('shellderRemoteSettings');
        if (remoteContainer && data.remote) {
            remoteContainer.innerHTML = `
                <div class="info-item">
                    <span class="info-label">SSH Enabled</span>
                    <span class="info-value">${data.remote.ssh_enabled ? 'Yes' : 'No'}</span>
                </div>
                <div class="info-item">
                    <span class="info-label">API Key</span>
                    <span class="info-value">${data.remote.api_key ? '••••••••' : 'Not set'}</span>
                </div>
                <div class="info-item">
                    <span class="info-label">Allowed Hosts</span>
                    <span class="info-value">${data.remote.allowed_hosts || 'Local only'}</span>
                </div>
            `;
        }
        
        // Update config path display
        const pathDisplay = document.getElementById('shellderConfigPath');
        if (pathDisplay && data.config_file) {
            pathDisplay.textContent = data.config_file;
        }
        
    } catch (error) {
        console.error('Error loading general settings:', error);
    }
}

// Edit component
async function editComponent(componentName) {
    currentEditingComponent = componentName;
    
    try {
        const data = await fetchAPI('/api/stack-config');
        const compConfig = data.components[componentName];
        
        if (!compConfig) {
            showToast('Component configuration not found', 'error');
            return;
        }
        
        // Update modal title
        document.getElementById('componentEditorName').textContent = componentName;
        document.getElementById('componentEditorKey').value = componentName;
        
        // Fill form fields
        document.getElementById('componentEnabled').checked = compConfig.enabled;
        document.getElementById('componentLocal').checked = compConfig.local;
        document.getElementById('componentContainer').value = compConfig.container_name || '';
        document.getElementById('componentHost').value = compConfig.config?.host || 'localhost';
        document.getElementById('componentPort').value = compConfig.config?.port || compConfig.config?.api_port || '';
        document.getElementById('componentConfigFile').value = compConfig.config?.config_file || '';
        
        // Toggle local/remote sections
        toggleLocalRemote();
        
        // Show modal
        document.getElementById('componentEditorModal').classList.add('active');
        
    } catch (error) {
        console.error('Error loading component config:', error);
        showToast('Failed to load component configuration', 'error');
    }
}

// Toggle local/remote settings visibility
function toggleLocalRemote() {
    const isLocal = document.getElementById('componentLocal').checked;
    document.getElementById('localSettings').style.display = isLocal ? 'block' : 'none';
    document.getElementById('remoteSettings').style.display = isLocal ? 'none' : 'block';
}

// Close component editor
function closeComponentEditor() {
    document.getElementById('componentEditorModal').classList.remove('active');
    currentEditingComponent = null;
}

// Save component configuration
async function saveComponentConfig(event) {
    event.preventDefault();
    
    if (!currentEditingComponent) return;
    
    const formData = new FormData(event.target);
    const values = {
        enabled: formData.get('enabled') === 'on',
        local: formData.get('local') === 'on',
        container_name: formData.get('container_name'),
        host: formData.get('host'),
        config_file: formData.get('config_file')
    };
    
    // Add port if provided
    const port = formData.get('port');
    if (port) {
        values.port = parseInt(port);
    }
    
    try {
        const response = await fetchAPI('/api/stack-config', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                section: currentEditingComponent,
                values: values
            })
        });
        
        if (response.success) {
            showToast(`${currentEditingComponent} configuration saved`, 'success');
            closeComponentEditor();
            loadShellderConfig();
        } else {
            showToast(response.error || 'Failed to save configuration', 'error');
        }
    } catch (error) {
        console.error('Error saving component config:', error);
        showToast('Failed to save configuration', 'error');
    }
}

// Reload configuration file
async function reloadShellderConfigFile() {
    try {
        const response = await fetchAPI('/api/stack-config/reload', { method: 'POST' });
        if (response.success) {
            showToast('Configuration reloaded', 'success');
            loadShellderConfig();
            loadRawShellderConfig();
        } else {
            showToast(response.error || 'Failed to reload configuration', 'error');
        }
    } catch (error) {
        console.error('Error reloading config:', error);
        showToast('Failed to reload configuration', 'error');
    }
}

// Load raw configuration file
async function loadRawShellderConfig() {
    const textarea = document.getElementById('rawShellderConfig');
    if (!textarea) return;
    
    try {
        const data = await fetchAPI('/api/stack-config/file');
        if (data.content) {
            textarea.value = data.content;
        } else if (data.error) {
            textarea.value = `# Error: ${data.error}\n# Create shellder_config.toml to customize stack settings`;
        }
    } catch (error) {
        console.error('Error loading raw config:', error);
        textarea.value = '# Failed to load configuration file';
    }
}

// Save raw configuration file
async function saveRawShellderConfig() {
    const textarea = document.getElementById('rawShellderConfig');
    if (!textarea) return;
    
    const content = textarea.value;
    if (!content.trim()) {
        showToast('Configuration cannot be empty', 'error');
        return;
    }
    
    try {
        const response = await fetchAPI('/api/stack-config/file', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ content })
        });
        
        if (response.success) {
            showToast('Configuration saved and reloaded', 'success');
            loadShellderConfig();
        } else {
            showToast(response.error || 'Failed to save configuration', 'error');
        }
    } catch (error) {
        console.error('Error saving raw config:', error);
        showToast('Failed to save configuration', 'error');
    }
}

// Note: Shellder config page loading is now handled directly in navigateTo()

// =============================================================================
// AI DEBUG MASTER TOGGLE
// =============================================================================

async function loadAIDebugMasterToggle() {
    try {
        const response = await fetchAPI('/api/ai-debug/master-toggle');
        updateAIDebugUI(response.enabled);
        
        // Also load the config options
        const configResponse = await fetchAPI('/api/ai-debug/config');
        if (configResponse.config) {
            document.getElementById('aiOptFileAccess').checked = configResponse.config.file_access;
            document.getElementById('aiOptCommandExec').checked = configResponse.config.command_exec;
            document.getElementById('aiOptDockerAccess').checked = configResponse.config.docker_access;
            document.getElementById('aiOptDatabaseAccess').checked = configResponse.config.database_access;
            document.getElementById('aiOptSystemInfo').checked = configResponse.config.system_info;
        }
        
        // Update endpoint URL with actual host
        const baseUrl = `http://${window.location.hostname}:${window.location.port || 5000}`;
        const endpointEl = document.getElementById('aiDebugEndpoint');
        const baseUrlEl = document.getElementById('aiDebugBaseUrl');
        if (endpointEl) endpointEl.textContent = `${baseUrl}/api/ai-debug/*`;
        if (baseUrlEl) baseUrlEl.textContent = baseUrl;
        
    } catch (error) {
        console.error('Error loading AI Debug toggle:', error);
    }
}

async function toggleAIDebugAccess(enabled) {
    // Show confirmation dialog for enabling
    if (enabled) {
        const confirmed = confirm(
            '⚠️ SECURITY WARNING ⚠️\n\n' +
            'Enabling AI Debug Access allows external systems to:\n' +
            '• Read and write files on this machine\n' +
            '• Execute shell commands\n' +
            '• Access and modify databases\n' +
            '• Control Docker containers\n\n' +
            'Only enable this if:\n' +
            '• You trust the connecting AI system\n' +
            '• You have been instructed by a Pokemod/Unown# developer\n\n' +
            'Do you want to enable AI Debug Access?'
        );
        
        if (!confirmed) {
            document.getElementById('aiDebugMasterToggle').checked = false;
            return;
        }
    }
    
    try {
        const response = await fetchAPI('/api/ai-debug/master-toggle', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ enabled })
        });
        
        if (response.success) {
            updateAIDebugUI(response.enabled);
            showToast(response.message, response.enabled ? 'warning' : 'success');
        } else {
            showToast('Failed to update AI Debug Access', 'error');
            document.getElementById('aiDebugMasterToggle').checked = !enabled;
        }
    } catch (error) {
        console.error('Error toggling AI Debug Access:', error);
        showToast('Failed to update AI Debug Access', 'error');
        document.getElementById('aiDebugMasterToggle').checked = !enabled;
    }
}

function updateAIDebugUI(enabled) {
    // Update toggle
    const toggle = document.getElementById('aiDebugMasterToggle');
    if (toggle) toggle.checked = enabled;
    
    // Update label
    const label = document.getElementById('aiDebugToggleLabel');
    if (label) {
        label.textContent = enabled ? 'ENABLED' : 'Disabled';
        label.classList.toggle('enabled', enabled);
    }
    
    // Update card border
    const card = document.querySelector('.ai-debug-master-card');
    if (card) {
        card.classList.toggle('enabled', enabled);
    }
    
    // Update status badge
    const badge = document.getElementById('aiDebugStatusBadge');
    if (badge) {
        badge.className = `status-badge ${enabled ? 'enabled' : 'secured'}`;
        badge.innerHTML = `
            <span class="status-dot ${enabled ? 'on' : 'off'}"></span>
            <span class="status-text">${enabled ? 'ACTIVE - External Access Allowed' : 'Secured'}</span>
        `;
    }
    
    // Update MCP status
    const mcpStatus = document.getElementById('aiDebugMcpStatus');
    if (mcpStatus) {
        mcpStatus.textContent = enabled ? 'Active - Accepting Connections' : 'Disabled';
        mcpStatus.style.color = enabled ? 'var(--warning)' : 'var(--text-muted)';
    }
    
    // Show/hide expanded options
    const expandedOptions = document.getElementById('aiDebugExpandedOptions');
    if (expandedOptions) {
        expandedOptions.style.display = enabled ? 'block' : 'none';
    }
}

async function updateAIDebugOption(option, enabled) {
    try {
        const data = {};
        data[option] = enabled;
        
        const response = await fetchAPI('/api/ai-debug/config', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(data)
        });
        
        if (response.success) {
            showToast(`${option.replace('_', ' ')} ${enabled ? 'enabled' : 'disabled'}`, 'info');
        }
    } catch (error) {
        console.error('Error updating AI debug option:', error);
    }
}

function copyAIInstructions() {
    const baseUrl = `http://${window.location.hostname}:${window.location.port || 5000}`;
    const instructions = `# AI Debug Access Instructions

## Base URL
${baseUrl}

## Quick Start
1. Documentation: GET ${baseUrl}/api/ai-debug/help
2. Diagnostics: GET ${baseUrl}/api/ai-debug/diagnose
3. System Info: GET ${baseUrl}/api/ai-debug/system

## Available Endpoints
- Read files: GET ${baseUrl}/api/ai-debug/file?path=<path>
- Write files: POST ${baseUrl}/api/ai-debug/file
- Execute commands: POST ${baseUrl}/api/ai-debug/exec
- Docker operations: GET ${baseUrl}/api/ai-debug/docker?cmd=<cmd>
- SQL queries: POST ${baseUrl}/api/ai-debug/sql
- View logs: GET ${baseUrl}/api/ai-debug/logs?type=<type>

## MCP Server (for Cursor)
Add to Cursor settings (mcpServers):
{
  "shellder": {
    "command": "npx",
    "args": ["@anthropic-ai/mcp-server-fetch"],
    "env": {
      "SHELLDER_URL": "${baseUrl}"
    }
  }
}
`;
    
    navigator.clipboard.writeText(instructions).then(() => {
        showToast('AI instructions copied to clipboard!', 'success');
    }).catch(err => {
        console.error('Failed to copy:', err);
        showToast('Failed to copy instructions', 'error');
    });
}
