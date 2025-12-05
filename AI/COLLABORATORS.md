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

### 2024-12-05
- **AI folder restructure** - Created comprehensive AI/ documentation
  - Added: MCP_SERVER.md, AI_DEBUG_API.md, STRUCTURE.md, CHANGELOG.md
  - Moved: DEEP_ANALYSIS.md, STACK_SIMULATION.md from root
  - Updated: CONTEXT.md, RULES.md, README.md
- **MCP server setup** on Windows instance
  - Installed Node.js dependencies
  - Created Cursor MCP configuration
- **Updated .gitignore** - Added node_modules for mcp-server
- **Updated .cursorrules** - Comprehensive AI context

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

## Known Issues

> Document issues encountered for other collaborators

### Windows PowerShell
- Use `;` instead of `&&` for command chaining
- May need `cmd /c` prefix for npm commands
- PATH may not update without terminal restart

### MCP Server
- Requires Node.js 18+
- Shellder service must be running on port 5050
- Cursor needs restart after MCP config changes

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
