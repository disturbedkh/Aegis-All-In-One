#!/usr/bin/env node
/**
 * Shellder MCP Server
 * Provides AI assistants with direct access to Aegis AIO debugging tools
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';

const SHELLDER_URL = process.env.SHELLDER_URL || 'http://localhost:5050';

async function fetchAPI(endpoint, options = {}) {
  const url = `${SHELLDER_URL}${endpoint}`;
  try {
    const response = await fetch(url, {
      ...options,
      headers: {
        'Content-Type': 'application/json',
        ...options.headers
      }
    });
    return await response.json();
  } catch (error) {
    return { error: error.message };
  }
}

const server = new Server(
  { name: 'shellder-debug', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

// Define available tools
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'shellder_diagnose',
      description: 'Run comprehensive system diagnostics on the Aegis AIO stack. Returns CPU, memory, disk usage, container status, port availability, and service health.',
      inputSchema: { type: 'object', properties: {} }
    },
    {
      name: 'shellder_read_file',
      description: 'Read a file from the Aegis AIO directory. Returns file contents.',
      inputSchema: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Relative path from Aegis root (e.g., ".env", "docker-compose.yaml")' },
          lines: { type: 'number', description: 'Optional: limit to last N lines' }
        },
        required: ['path']
      }
    },
    {
      name: 'shellder_write_file',
      description: 'Write content to a file in the Aegis AIO directory.',
      inputSchema: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Relative path from Aegis root' },
          content: { type: 'string', description: 'File content to write' },
          append: { type: 'boolean', description: 'If true, append instead of overwrite' }
        },
        required: ['path', 'content']
      }
    },
    {
      name: 'shellder_exec',
      description: 'Execute a shell command on the Aegis server. Returns stdout, stderr, and return code.',
      inputSchema: {
        type: 'object',
        properties: {
          cmd: { type: 'string', description: 'Shell command to execute' },
          timeout: { type: 'number', description: 'Timeout in seconds (default: 30)' }
        },
        required: ['cmd']
      }
    },
    {
      name: 'shellder_docker',
      description: 'Docker operations: ps (list containers), logs (get container logs), inspect, stats, images',
      inputSchema: {
        type: 'object',
        properties: {
          cmd: { type: 'string', description: 'Command: ps, logs, inspect, stats, images' },
          container: { type: 'string', description: 'Container name (required for logs/inspect)' },
          lines: { type: 'number', description: 'Number of log lines (default: 100)' }
        },
        required: ['cmd']
      }
    },
    {
      name: 'shellder_sql',
      description: 'Execute a SQL query on MariaDB databases (golbat, dragonite, reactmap, koji). Read-only for safety.',
      inputSchema: {
        type: 'object',
        properties: {
          database: { type: 'string', description: 'Database name: golbat, dragonite, reactmap, koji' },
          query: { type: 'string', description: 'SQL query to execute' }
        },
        required: ['database', 'query']
      }
    },
    {
      name: 'shellder_logs',
      description: 'Get system logs. Types: shellder, docker, nginx, system, container',
      inputSchema: {
        type: 'object',
        properties: {
          type: { type: 'string', description: 'Log type: shellder, docker, nginx, system, container' },
          lines: { type: 'number', description: 'Number of lines (default: 100)' },
          container: { type: 'string', description: 'Container name (for container type)' }
        },
        required: ['type']
      }
    },
    {
      name: 'shellder_system',
      description: 'Get detailed system information: hostname, platform, CPU, memory, disk, git info',
      inputSchema: { type: 'object', properties: {} }
    },
    {
      name: 'shellder_help',
      description: 'Get complete API documentation for all Shellder debug endpoints',
      inputSchema: { type: 'object', properties: {} }
    }
  ]
}));

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      case 'shellder_diagnose':
        return { content: [{ type: 'text', text: JSON.stringify(await fetchAPI('/api/ai-debug/diagnose'), null, 2) }] };

      case 'shellder_read_file': {
        const params = new URLSearchParams({ path: args.path });
        if (args.lines) params.append('lines', args.lines);
        return { content: [{ type: 'text', text: JSON.stringify(await fetchAPI(`/api/ai-debug/file?${params}`), null, 2) }] };
      }

      case 'shellder_write_file':
        return { content: [{ type: 'text', text: JSON.stringify(await fetchAPI('/api/ai-debug/file', {
          method: 'POST',
          body: JSON.stringify(args)
        }), null, 2) }] };

      case 'shellder_exec':
        return { content: [{ type: 'text', text: JSON.stringify(await fetchAPI('/api/ai-debug/exec', {
          method: 'POST',
          body: JSON.stringify(args)
        }), null, 2) }] };

      case 'shellder_docker': {
        const params = new URLSearchParams({ cmd: args.cmd });
        if (args.container) params.append('container', args.container);
        if (args.lines) params.append('lines', args.lines);
        return { content: [{ type: 'text', text: JSON.stringify(await fetchAPI(`/api/ai-debug/docker?${params}`), null, 2) }] };
      }

      case 'shellder_sql':
        return { content: [{ type: 'text', text: JSON.stringify(await fetchAPI('/api/ai-debug/sql', {
          method: 'POST',
          body: JSON.stringify(args)
        }), null, 2) }] };

      case 'shellder_logs': {
        const params = new URLSearchParams({ type: args.type });
        if (args.lines) params.append('lines', args.lines);
        if (args.container) params.append('container', args.container);
        return { content: [{ type: 'text', text: JSON.stringify(await fetchAPI(`/api/ai-debug/logs?${params}`), null, 2) }] };
      }

      case 'shellder_system':
        return { content: [{ type: 'text', text: JSON.stringify(await fetchAPI('/api/ai-debug/system'), null, 2) }] };

      case 'shellder_help':
        return { content: [{ type: 'text', text: JSON.stringify(await fetchAPI('/api/ai-debug/help'), null, 2) }] };

      default:
        return { content: [{ type: 'text', text: `Unknown tool: ${name}` }], isError: true };
    }
  } catch (error) {
    return { content: [{ type: 'text', text: `Error: ${error.message}` }], isError: true };
  }
});

// Start server
const transport = new StdioServerTransport();
await server.connect(transport);
console.error('Shellder MCP Server running');

