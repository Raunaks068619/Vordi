# AI Agent Memory Design

Date: 2026-06-04
Status: Approved for implementation planning
Owner: Vordi Memory

## Summary

Vordi Memory should import local AI-agent sessions from Claude Code, Codex, and Gemini CLI on demand, map those sessions by project folder, and let the existing Knowledge Graph and Ask Memory surfaces use that context when the user enables it.

The feature should follow Agentlytics' proven model: each local agent has a small adapter that reads that agent's known local session store, normalizes sessions and messages into a common shape, and writes them into a local SQLite index. Vordi should not become an analytics dashboard. The P1 is stronger local memory, folder-wise context mapping, source-aware search, and chat answers grounded in local dictations plus local agent sessions.

## Evidence From Agentlytics

Agentlytics knows about local chats because common AI coding tools persist their sessions on disk under the user's home directory. It does not need special access to the running app for Claude Code or Codex.

Relevant upstream patterns observed in `f/agentlytics`:

- Claude Code reads `~/.claude/projects/<encoded-path>/`, including `sessions-index.json` and `.jsonl` session files.
- Codex reads `${CODEX_HOME:-~/.codex}/sessions/**/*.jsonl` and `archived_sessions/**/*.jsonl`.
- Gemini CLI reads `~/.gemini/tmp/<project>/chats/session-*.json` and optionally maps project names through `~/.gemini/projects.json`.
- Agentlytics normalizes sessions into a local SQLite cache at `~/.agentlytics/cache.db`.
- It stores chats, messages, stats, tool calls, source, folder, timestamps, models, and token usage where available.

Local exploratory scan showed that this machine has data in the same shapes:

- Claude Code: around 97 sessions.
- Codex: around 157 sessions.
- Gemini: around 66 sessions, with missing folder mapping because `~/.gemini/projects.json` was not present.
- Vordi itself appears in both Claude and Codex session folders, which proves the same-folder connection is available locally.

## Goals

1. Add an opt-in `Include AI agent context` toggle in the Memory / Knowledge Graph view.
2. Keep sync manual and on demand, using the existing Sync mental model.
3. Import Claude Code, Codex, and Gemini CLI sessions into Vordi's local Memory index when the toggle is enabled.
4. Classify imported sessions by project folder so sessions from different agents working in the same repo are connected.
5. Extend search, embeddings, entity extraction, graph edges, and Ask Memory retrieval to include agent sessions when enabled.
6. Preserve source provenance in UI and citations.
7. Keep the UI close to the current Wispr-derived Vordi design system.

## Non-Goals

- Do not build a full Agentlytics-style analytics dashboard.
- Do not index arbitrary files under `~/.gemini`, browser profile caches, OAuth credentials, auth files, or unrelated agent configuration.
- Do not auto-sync in the background.
- Do not send local session content anywhere except through the existing Ask Memory LLM answer flow.
- Do not add support for Cursor, Windsurf, VS Code, Zed, or other editors in P1.
- Do not create a separate Agent Memory tab for P1.

## Product Behavior

Memory has one primary toggle:

```text
Include AI agent context
```

When OFF:

- Sync indexes Vordi dictations only.
- Ask Memory retrieves from Vordi dictations only.
- The graph reflects existing dictation-derived entities and edges.

When ON:

- Sync indexes Vordi dictations and local AI-agent sessions.
- Ask Memory retrieves from dictations and agent sessions.
- The graph includes entities extracted from agent sessions.
- Source chips and citations identify whether evidence came from Vordi, Claude Code, Codex, or Gemini.

The toggle should default OFF for privacy. The user's last choice can be remembered in `UserDefaults` after the first explicit toggle.

## Architecture

Extend the current Memory pipeline instead of creating a parallel subsystem:

```text
Vordi dictations -> RunStore
Claude/Codex/Gemini -> AgentSessionImporters
             ↓
        MemoryStore
             ↓
FTS search + embeddings + entities + graph + Ask Memory
```

New boundaries:

- `AgentSession`: normalized session model independent of any source format.
- `AgentMessage`: normalized message model for user, assistant, system, tool, and tool result content.
- `AgentSessionImporter`: protocol for discovering and parsing sessions from one agent source.
- `AgentSessionImportService`: orchestrates importers during manual sync and reports per-source counts.
- `FolderNormalizer`: canonicalizes folder paths and collapses obvious worktrees to parent repos.

Importer files should live under `Sources/Services/Memory/AgentSessions/` or another similarly scoped Memory subfolder.

## Source Adapter Contracts

### Claude Code

Read from:

```text
/Users/raunaksingh/.claude/projects
```

Behavior:

- Decode project folder names where possible.
- Prefer `sessions-index.json` metadata when present.
- Parse `.jsonl` session files for user, assistant, system, tool-use, and tool-result messages.
- Extract title from the first meaningful user message.
- Use `cwd`, `projectPath`, or decoded folder name as the folder path.
- Skip malformed lines and count skipped records.

### Codex

Read from:

```text
${CODEX_HOME:-/Users/raunaksingh/.codex}/sessions/**/*.jsonl
${CODEX_HOME:-/Users/raunaksingh/.codex}/archived_sessions/**/*.jsonl
```

Behavior:

- Parse `session_meta` for `id`, `cwd`, timestamp, source, originator, CLI version, and model provider.
- Parse `turn_context` for model context.
- Parse `response_item` for visible user and assistant messages.
- Include reasoning summaries if they are visible summaries.
- Convert function calls, custom tool calls, web search calls, and tool outputs into compact transcript lines.
- Skip Codex bootstrap wrappers such as `<user_instructions>` and `<environment_context>` when deriving titles.

### Gemini CLI

Read from:

```text
/Users/raunaksingh/.gemini/tmp/*/chats/session-*.json
```

Behavior:

- Parse JSON sessions with message arrays.
- Extract user, Gemini assistant, info, warning, and error messages.
- Extract tool calls and token fields when present.
- Use `~/.gemini/projects.json` for folder mapping if present.
- If folder mapping is unavailable, import under `Unknown project` and keep the session searchable.
- Do not scan `~/.gemini/antigravity-browser-profile`, credentials, skills, history repos, OAuth files, or arbitrary Gemini files.

## Data Model

The current `MemoryStore` schema is dictation-shaped. P1 should migrate it to a source-aware item model.

Recommended logical shape:

```text
memory_items
- id TEXT PRIMARY KEY
- source_type TEXT NOT NULL        -- dictation | agent_session
- source_app TEXT NOT NULL         -- vordi | claude-code | codex | gemini-cli
- external_id TEXT NOT NULL
- folder_path TEXT
- folder_display_name TEXT
- title TEXT
- created_at INTEGER NOT NULL
- updated_at INTEGER
- app TEXT
- bundle_id TEXT
- profile TEXT
- word_count INTEGER DEFAULT 0
- duration_seconds REAL DEFAULT 0
- status TEXT
- model TEXT
- tool_names_json TEXT DEFAULT '[]'
- llm_cost_usd REAL DEFAULT 0
```

Searchable text remains in FTS:

```text
memory_text_fts
- memory_item_id UNINDEXED
- text
```

Derived data should point to memory items rather than runs:

```text
embeddings(memory_item_id, vec, dim, model)
entity_items(entity_id, memory_item_id)
entity_indexed_items(memory_item_id, indexed_at)
```

Migration strategy:

- Existing dictation rows become `source_type = dictation`, `source_app = vordi`.
- Because MemoryStore is a derived index, a breaking schema change may wipe and rebuild the index from `RunStore` plus agent importers.
- Preserve the existing ability to delete a Vordi run and remove the matching memory item.

## Folder Mapping

Folder path is the key relationship for P1.

Rules:

1. Normalize `file://` prefixes and resolve symlinks when cheap.
2. Preserve absolute paths as the canonical key.
3. Collapse obvious `.claude/worktrees/<name>` paths to their parent repo when `.git` metadata or path naming makes the parent clear.
4. Use the session-provided `cwd` over encoded path names when available.
5. Store unknown Gemini folders as `Unknown project` rather than dropping them.

Graph and retrieval should treat sessions in the same normalized folder as related, even when they came from different agents.

## Sync Flow

Manual sync remains the only expensive work trigger.

```text
User clicks Sync
-> migrate Vordi RunStore items into MemoryStore
-> if Include AI agent context is ON, scan agent stores
-> upsert changed agent sessions
-> compute missing embeddings
-> extract missing entities
-> refresh graph
```

Status should distinguish source counts:

```text
Indexing 42 dictations + 17 agent sessions
Indexed 42 runs, 25 agent sessions, skipped 3
```

Partial success is acceptable:

- If Claude succeeds and Gemini fails, keep Claude results.
- If a file is malformed, skip it and count it.
- If embeddings fail, FTS search still works.
- If entity extraction fails for a session, mark the failure without blocking other items.

## Retrieval

Extend `MemoryChatService` so the candidate pool is source-aware.

When agent context is OFF:

- Retrieve only `source_type = dictation`.

When agent context is ON:

- Retrieve both dictations and agent sessions.

Ranking inputs:

- Semantic similarity.
- FTS keyword score.
- Entity boost.
- Folder/project boost.
- Recency decay.
- Previous-source continuity for follow-up questions.

Folder boost should apply when the question mentions a known folder name, repo name, file path, tool, or project entity. This is what lets questions such as "What did we decide about Vordi memory?" pull both Claude and Codex sessions from `/Users/raunaksingh/Documents/Vordi`.

Sources sent to the LLM should include:

- Source app.
- Folder.
- Title.
- Date.
- Text excerpt.

The answer should cite source IDs so the UI can render source chips.

## Knowledge Graph

The existing entity graph remains primary.

P1 graph behavior:

- Agent sessions contribute entities and co-occurrence edges.
- Project/folder relationships influence retrieval and popovers.
- Agent sources appear as chips, filters, and source metadata.
- Do not add giant `Claude Code`, `Codex`, or `Gemini` graph nodes by default.
- Node popovers should show source previews with source app, folder, date, and snippet.

This keeps the graph readable while still connecting sessions from multiple agents through shared entities and folders.

## UI Design

Use current Vordi design tokens and components from `Sources/Views/DesignSystem.swift`.

Memory header:

```text
Memory   Local   [Include AI agent context]   [Sync]
```

When enabled, show a compact source status row:

```text
Vordi 42 runs · Claude Code 10 sessions · Codex 17 sessions · Gemini 66 unknown-project sessions
```

Ask Memory copy:

- Toggle OFF: `Questions about your past dictations.`
- Toggle ON: `Questions about dictations and local AI-agent sessions.`

Source previews:

- Show source app chip.
- Show folder display name.
- Show date.
- Show title or first prompt.
- Show short snippet.
- Do not dump full chats by default.

No new large dashboard, no card-heavy analytics page, no separate sidebar tab for P1.

## Privacy And Safety

- Toggle defaults OFF.
- Sync is manual.
- Only known chat/session files are read.
- Credentials, OAuth files, auth files, browser caches, and arbitrary agent folders are never indexed.
- Local text is stored in Vordi's local SQLite index.
- Existing Ask Memory provider behavior still controls whether retrieved source excerpts are sent to an LLM.
- Errors should reveal source and count, not sensitive content.

## Performance

P1 should be safe for a few hundred to a few thousand sessions.

Constraints:

- Skip unchanged sessions by comparing `external_id`, `updated_at`, file modified time, and message count.
- Cap each indexed message or session text chunk to avoid huge embedding prompts.
- Prefer one item per session for P1, not one item per message, unless very large sessions need chunking.
- Keep importer parsing synchronous or serial inside the sync worker to avoid high disk churn.
- Continue to let FTS work even if embeddings are unavailable.

## Testing

Unit-level fixtures:

- Claude `.jsonl` with user, assistant, tool use, tool result.
- Codex `.jsonl` with `session_meta`, `turn_context`, `response_item`, tool calls, and token events.
- Gemini `session-*.json` with user, gemini, thoughts, tool calls, and warning/info messages.

Behavior tests:

- Folder normalization connects Claude and Codex sessions in the same repo.
- Worktree path collapses when parent repo can be inferred.
- Unknown Gemini folder imports as `Unknown project`.
- Toggle OFF excludes agent sessions from retrieval.
- Toggle ON includes agent sessions in retrieval.
- FTS finds agent session content.
- Source previews include source app and folder.

Manual verification:

- Run local scan and compare counts against current local data.
- Click Sync with toggle OFF and confirm dictation-only behavior.
- Click Sync with toggle ON and confirm agent sessions import.
- Ask a Vordi project question and confirm answers can cite Claude and Codex sessions from the same folder.

## Implementation Order

1. Add normalized `AgentSession` and importer protocol.
2. Implement Claude Code importer.
3. Implement Codex importer.
4. Implement Gemini importer with strict path allowlist.
5. Migrate `MemoryStore` schema to source-aware memory items.
6. Wire agent import into `IndexerService.syncNow()` behind the toggle.
7. Extend `KnowledgeGraphService` source previews and counts.
8. Extend `MemoryChatService` retrieval filters, folder boosts, and source hydration.
9. Add Memory header toggle and source status row.
10. Add focused parser and retrieval tests.

## Open Decisions Resolved For P1

- Use hybrid storage: full local text in SQLite for search, snippets and source chips in UI.
- Keep unknown-folder Gemini sessions searchable.
- Collapse obvious worktrees to parent repo.
- Represent agents as source chips and filters, not default graph nodes.
- Keep one Sync button.
- Keep toggle default OFF but remember explicit user choice.

