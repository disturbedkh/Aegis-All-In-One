# Collaboration Notes

> Coordination document for multi-user/multi-instance development.

---

## Active Development Environments

| User | Machine | Role | MCP Setup | Notes |
|------|---------|------|-----------|-------|
| khutt | Windows (Cursor) | Development | ✅ Configured | Local development |
| khutt | Linux Server | Production | ❓ | Runs Docker stack |

---

## How to Add Your Environment

When starting work on a new machine:

1. Clone the repository: `git clone <repo-url>`
2. Set up MCP server (see AI/MCP_SERVER.md)
3. Add entry to this table
4. Commit and push

---

## Recent Changes Log

> Add dated entries when making significant changes

### 2024-12-05 (Windows - Primary Development)
- **AI folder restructure** - Created comprehensive AI/ documentation
  - Added: MCP_SERVER.md, AI_DEBUG_API.md, STRUCTURE.md, CHANGELOG.md
  - Moved: DEEP_ANALYSIS.md, STACK_SIMULATION.md from root
  - Updated: CONTEXT.md, RULES.md, README.md
- **MCP server setup** on Windows instance
  - Installed Node.js dependencies
  - Created Cursor MCP configuration
- **Updated .gitignore** - Added node_modules for mcp-server
- **Updated .cursorrules** - Comprehensive AI context
- **Xilriws Log Parsing Fixes**
  - Fixed ANSI color code stripping (`[36m`, `[0m`, etc.) breaking regex
  - Added 'local' proxy tracking when no external proxy configured
  - Fixed duplicate `updateXilriwsPage` function overwriting correct one
  - Correct API field: `browser_bot_protection` (not `code_15`)
- **Metrics History Charts**
  - Fixed SQLite database locking with `busy_timeout=5000` and WAL mode
  - Added AbortController to cancel in-flight requests when switching periods
  - Fixed bar width proportionality with CSS flex
  - Implemented auto-scaling Y-axis for low-value visibility
- **Config Editor Improvements**
  - Fixed nested TOML section navigation (e.g., `db.dragonite.user`)
  - Added Golbat webhook management UI (CRUD operations)
  - Parse commented-out config variables and show as optional
- **File Manager**
  - Fixed base64 encoding for file paths with special characters
  - Added ownership/permissions controls with sudo password prompt
- **Stack Configuration System** (NEW)
  - `Shellder/shellder_config.toml` - Centralized component configuration
  - `Shellder/config_loader.py` - Python config loader with defaults
  - Support for local Docker OR remote service per component
- **CRITICAL FIX: GUI Completely Broken**
  - **Symptom**: Clicking ANY menu item did nothing, metrics showed flat lines
  - **Root Cause**: Function wrapper at end of script.js reassigned `window.navigateTo`
  - **Diagnosis**: Debug logs showed "Expected endpoints not called" - no API requests
  - **Fix**: Removed wrapper, added page handling directly in `navigateTo()`
  - **Lesson**: NEVER reassign global functions with wrappers - modify original instead

---

## Work Session Template

When starting a significant work session, add:

```markdown
### YYYY-MM-DD
- **[Brief title]** - Description of work
  - File changes: list files modified
  - Features: what was added/changed
  - Notes: anything important for other collaborators
```

---

## Pending Tasks

> Track tasks across sessions

### High Priority
- [ ] Test MCP server connection to remote Shellder
- [ ] Verify AI Debug API endpoints work
- [ ] Document remote server MCP setup

### Medium Priority
- [ ] Add more troubleshooting scenarios to DEEP_ANALYSIS.md
- [ ] Create video/screenshots of Shellder dashboard

### Low Priority
- [ ] Investigate additional MCP tools to add
- [ ] Add webhook testing documentation

---

## Sync Workflow

### Before Starting Work

```bash
# Pull latest changes
git fetch origin
git pull origin main

# Check for conflicts
git status
```

### After Completing Work

```bash
# Stage changes
git add -A

# Commit with descriptive message
git commit -m "feat: description of what was done"

# Push to remote
git push origin main
```

### Commit Message Format

```
type: brief description

Types:
- feat: new feature
- fix: bug fix
- docs: documentation only
- refactor: code restructure
- chore: maintenance tasks
```

---

## Known Issues & Lessons Learned

> Critical knowledge from debugging sessions - READ BEFORE MAKING CHANGES

### Windows PowerShell
- Use `;` instead of `&&` for command chaining
- May need `cmd /c` prefix for npm commands
- PATH may not update without terminal restart

### MCP Server / AI Debug API
- **Port is 5000** (same as web dashboard), NOT 5050
- Requires Node.js 18+
- Cursor needs restart after MCP config changes
- For remote servers, use actual IP: `http://<your-server-ip>:5000`
- The Shellder UI auto-detects and displays the correct URL

### Docker Log Parsing (CRITICAL)
- **ANSI codes break regex!** Docker logs contain color codes like `[36m`, `[0m`
- Always strip ANSI before parsing: `re.sub(r'\x1b\[[0-9;]*m|\[(?:\d+;)*\d*m', '', line)`
- Log format varies by container - check actual logs first

### JavaScript Gotchas
- **Duplicate functions silently override** - search entire file for function name before adding
- The later-defined function wins, can cause silent failures
- Example: Two `updateXilriwsPage()` functions caused stats to show 0
- **NEVER reassign global functions with wrappers** - breaks onclick handlers
  ```javascript
  // BAD - This broke the entire GUI:
  const originalFn = typeof myFunc === 'function' ? myFunc : null;
  window.myFunc = function() { originalFn(); /* extra code */ };
  
  // GOOD - Modify the original function directly:
  // Add handling inside the existing function
  ```
- **Diagnosing "clicks do nothing"**: Check debug logs for "Expected endpoints not called"

### SQLite Database Issues
- **Always set busy_timeout** - default 0 causes instant lock failures
- Use WAL mode for concurrent read/write: `PRAGMA journal_mode=WAL`
- Shellder uses `Shellder/data/shellder.db` for metrics history

### API Field Name Mismatches
- Xilriws stats: `browser_bot_protection` (not `code_15`)
- Check API response before assuming field names
- Use browser DevTools Network tab to inspect actual responses

### Config File Parsing
- TOML nested sections: `[db.dragonite]` creates nested dict `{db: {dragonite: {...}}}`
- JavaScript must navigate: `values.db?.dragonite?.user` not `values['db.dragonite'].user`
- Commented variables (starting with `#`) may need to be parsed separately

### Chart/Metrics Issues
- Cancel previous requests with AbortController when user switches views
- CSS `flex: 1` on bars needs `max-width` removed to fill container
- Auto-scale Y-axis when values are low (< 30%) for visibility

### File Operations
- Base64 encode paths with special characters for onclick handlers
- Use `TextEncoder`/`TextDecoder` (not deprecated `escape`/`unescape`)
- Check file ownership - operations may need sudo password

---

## Communication

### When Working Simultaneously

1. Communicate before making major changes
2. Pull frequently to avoid conflicts
3. Use branches for large features
4. Document changes in this file

### When Handing Off Work

1. Push all changes
2. Update COLLABORATORS.md with session notes
3. Note any unfinished work in Pending Tasks
4. Document any blockers encountered

---

## Environment-Specific Notes

### Windows Development
- Node.js: Install via `winget install OpenJS.NodeJS.LTS`
- MCP config: `%APPDATA%\Cursor\User\globalStorage\cursor.mcp\mcp.json`
- Path separators: Use `\\` in JSON configs

### Linux/Mac Development
- Node.js: Use nvm or system package manager
- MCP config: `~/.cursor/mcp.json` or similar
- Path separators: Use `/`

### Remote Server
- SHELLDER_URL should point to server IP/hostname
- May need SSH tunnel for local MCP to remote Shellder
- Firewall must allow port 5050 if accessing remotely

---

## File Ownership

> Who typically works on what (informational)

| Area | Primary | Notes |
|------|---------|-------|
| AI/ documentation | All | Collaborative |
| Shellder scripts | - | Shell/Python |
| MCP server | - | Node.js |
| Docker configs | - | YAML |
| Wiki | - | Markdown |
