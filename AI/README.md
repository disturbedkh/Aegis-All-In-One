# AI Knowledge Base

> Comprehensive documentation for AI assistants working on Aegis AIO.

---

## Quick Start for AI

1. **Read `CONTEXT.md`** - Project overview and architecture
2. **Follow `RULES.md`** - Guidelines and constraints
3. **Reference `STRUCTURE.md`** - Directory layout
4. **Check `CHANGELOG.md`** - Recent changes

---

## Documentation Index

### Core Documentation

| File | Purpose | Read When |
|------|---------|-----------|
| [CONTEXT.md](CONTEXT.md) | Project overview, architecture, key info | **First** - Start of any session |
| [RULES.md](RULES.md) | Guidelines and constraints | Before making changes |
| [STRUCTURE.md](STRUCTURE.md) | Complete directory structure | Navigating the codebase |
| [CHANGELOG.md](CHANGELOG.md) | Project change history | Understanding recent changes |

### Technical Documentation

| File | Purpose | Read When |
|------|---------|-----------|
| [MCP_SERVER.md](MCP_SERVER.md) | MCP server for Cursor/Claude | Using MCP tools |
| [AI_DEBUG_API.md](AI_DEBUG_API.md) | REST API reference | Making API calls |
| [DEEP_ANALYSIS.md](DEEP_ANALYSIS.md) | System deep-dive analysis | Debugging complex issues |
| [STACK_SIMULATION.md](STACK_SIMULATION.md) | Data flow simulation | Understanding data flow |

### Collaboration

| File | Purpose | Read When |
|------|---------|-----------|
| [COLLABORATORS.md](COLLABORATORS.md) | Team notes & coordination | Multi-user development |

---

## Usage with Different AI Tools

### Cursor
Automatically reads `.cursorrules` → points to AI/ folder.

### Claude Web/API
Start conversations with:
```
Please read AI/CONTEXT.md for project context before proceeding.
```

### ChatGPT / Other
Upload or reference `AI/CONTEXT.md` at session start.

### MCP-Enabled Tools
Use the Shellder MCP server for direct system access:
- Diagnostics, file operations, Docker control, SQL queries

---

## File Purposes

```
AI/
├── README.md          ← You are here (index & usage guide)
├── CONTEXT.md         ← Project overview (read first)
├── RULES.md           ← AI guidelines (read before changes)
├── STRUCTURE.md       ← Directory layout reference
├── CHANGELOG.md       ← What changed and when
├── COLLABORATORS.md   ← Team coordination notes
├── MCP_SERVER.md      ← MCP server documentation
├── AI_DEBUG_API.md    ← REST API for AI access
├── DEEP_ANALYSIS.md   ← System deep-dive
└── STACK_SIMULATION.md← Data flow documentation
```

---

## Keeping Documentation Updated

### When to Update

| Event | Update |
|-------|--------|
| Architecture change | CONTEXT.md, STRUCTURE.md |
| New feature added | CHANGELOG.md, relevant docs |
| New guideline needed | RULES.md |
| Team change | COLLABORATORS.md |
| MCP/API change | MCP_SERVER.md, AI_DEBUG_API.md |

### How to Update

1. Make changes to relevant AI/*.md files
2. Add entry to CHANGELOG.md under [Unreleased]
3. Commit with descriptive message
4. Push to share with other instances/collaborators

---

## Why This Folder Exists

### Problems Solved

1. **Tool-Agnostic** - Works with Cursor, Claude, ChatGPT, Copilot
2. **Version Controlled** - Shared via git across all instances
3. **Human Readable** - Anyone can view/edit the markdown
4. **Discoverable** - Not hidden in dot-folders
5. **Self-Documenting** - AI can read about itself

### Alternative Approaches

| Approach | Limitation |
|----------|------------|
| `.cursor/` folder | Cursor-specific, may be blocked |
| Per-tool configs | Fragmented, hard to sync |
| README only | Limited context capacity |
| No documentation | AI has no project awareness |

---

## Best Practices

### For AI Assistants

1. **Always read CONTEXT.md** at session start
2. **Check CHANGELOG.md** for recent changes
3. **Follow RULES.md** constraints
4. **Use STRUCTURE.md** to navigate
5. **Update COLLABORATORS.md** after significant work

### For Human Collaborators

1. Keep documentation current
2. Add changelog entries for significant changes
3. Review AI-generated changes
4. Document patterns and conventions

---

## Related Resources

- **Wiki:** `wiki/` folder (GitHub wiki format)
- **README:** `README.md` in project root
- **Shellder Docs:** `wiki/Shellder.md`
