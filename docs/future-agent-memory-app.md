# Future idea (parked): cross-agent memory app

**Status:** Parked, not started. Do not build until the trigger below is met.
**Parked on:** 2026-06-06
**Why parked:** Vordi's bottleneck is distribution, not features. Starting a
second app now is the same scope-creep that pulled Memory away from
transcription. Ship Vordi, get real users, then revisit only if *users*
pull us toward this.

---

## The idea in one paragraph

A local, private memory layer that spans **all** of a developer's AI coding
agents — Claude Code, Codex, Gemini CLI, etc. It ingests each tool's session
logs, normalizes them by **folder/repo**, builds a knowledge graph + hybrid
retrieval over the lot, and lets the developer ask one question across
everything every agent did in a project ("what did Claude and Codex both touch
in this repo last week?"). Everything stays on the machine.

This is an **infrastructure / power-user** product, distinct from Vordi
(voice-to-text). Different customer, different value prop, different story. It
was deliberately removed from Vordi so the transcription product stays one
coherent thing.

## What it is NOT (the trap to avoid)

- NOT a "mediator" that injects context back into agents. That's a much harder
  bidirectional infra play competing directly with Anthropic/OpenAI's own
  native memory roadmaps. Read-only "ask your history" is the defensible scope.
- NOT a Vordi feature. If it ships, it ships as its own app.

## Code to reuse (already written, preserved in this repo's history)

The hard part is done and lives in Vordi's tree as dormant/standalone code:

- `Sources/Services/Memory/AgentSessionImportService.swift` — **the crown
  jewel.** Parses Claude Code (`~/.claude/projects`), Codex
  (`~/.codex/sessions`), and Gemini CLI (`~/.gemini/tmp`) session formats into
  one `AgentSession` model, normalized by folder (`FolderNormalizer`). Intact
  and unreferenced by the live product after the 2026-06-06 scoping.
- `Sources/Services/Memory/MemoryStore.swift` — SQLite corpus + FTS5. Still
  carries dormant `includeAgentContext:` parameters on ~15 query methods plus
  `upsertAgentSession` / `deleteStaleAgentSessions` — the engine already
  supports filtering by source. This is the retrieval engine, reusable as-is.
- `Sources/Services/Memory/MemoryChatService.swift` — hybrid retrieval pipeline
  (embeddings + BM25 merge, entity boost, recency decay, recency fallback).
  Source-agnostic; works on any corpus.
- `Sources/Services/Memory/EmbeddingService.swift`, `IndexerService.swift`,
  `LLMRouter.swift`, `CLIBackend.swift` — embedding, indexing, and local-LLM
  plumbing.
- Removed at scoping time but recoverable from git: the `applyFolderBoost`
  cross-repo ranking logic in `MemoryChatService`, and the "Include AI agent
  context" UI in `KnowledgeGraphView.swift`.

## Trigger to revisit

Revisit ONLY when **both** are true:

1. Vordi has a real user base (rough bar: ~100 active users), AND
2. Some of those users have explicitly asked for cross-agent memory / "remember
   what my coding agents did."

Until then: closed tab. This file is the bookmark.
