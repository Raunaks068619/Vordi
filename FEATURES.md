# Vordi — Features

A macOS-native dictation app: hold **Fn → speak → release**, and polished text is
injected into the active text field. Pure Swift + SwiftUI, no Electron,
macOS 13+. Current line: `v0.6.x`.

This document lists what is **implemented**. For parked/future ideas see
`docs/`. Last updated: 2026-06-06.

---

## 1. Core dictation

- **Push-to-talk dictation** — hold the Fn key to record, release to transcribe
  and inject. (`HotKeyListener`, `AudioRecorder`, `TextInjector`)
- **Global hotkey capture** — CGEvent tap + NSEvent global monitor for the Fn
  key, works system-wide. (`HotKeyListener`)
- **Keystroke injection** — transcribed text typed into the focused field of any
  app via synthesized CGEvents. (`TextInjector`)
- **Audio capture** — AVAudioEngine-based recording to WAV. (`AudioRecorder`)
- **Microphone probing & selection** — device detection and health checks.
  (`MicrophoneProbe`)

## 2. Transcription pipeline

- **Whisper transcription** — audio → text via Whisper. (`WhisperService`)
- **Realtime transcription** — streaming transcription path.
  (`RealtimeTranscriptionService`)
- **Hallucination guard** — blocklist/heuristics that strip Whisper's known
  hallucinated phrases from output. (`HallucinationGuard`)
- **Local model support** — detects locally available models so transcription /
  LLM work can run on-device. (`LocalModelDetector`, `LLMRouter`, CLI backend)

## 3. Post-processing & transformer profiles

LLM-based cleanup that rewrites raw transcripts per the active profile.
(`LLMService`, `TransformerRouter`, `Sources/Services/Profiles/`)

- **Standard cleanup** — punctuation, casing, filler removal.
  (`StandardCleanupProfile`)
- **Developer mode** — code-aware formatting. (`DeveloperModeProfile`)
- **Agentic developer mode** — formatting tuned for AI-coding-agent prompts.
  (`AgenticDeveloperModeProfile`)
- **Prompt engineer mode** — structures dictation into clean prompts.
  (`PromptEngineerProfile`)
- **Variable recognition** — recognizes code identifiers / variable names.
  (`VariableRecognitionProfile`)
- **Magic word expansion profile** — applies user shortcuts during cleanup.
  (`MagicWordExpansionProfile`)
- **User-type classification** — adapts behavior to the kind of user.
  (`UserTypeClassifier`)
- **User vocabulary** — custom dictionary that biases transcription/cleanup.
  (`UserVocabulary`)

## 4. Magic Words

- **Custom voice shortcuts** — spoken triggers expand into snippets / canned
  text. (`MagicWordResolver`, `MagicWordStore`, `MagicWord` model)
- **Magic Words settings UI** — manage triggers and expansions.
  (`MagicWordsSettingsView`, `MagicWordsSettingsView`)

## 5. Context capture

Captures "what the user was doing" at hotkey-press time so cleanup is
context-aware. (`ContextProvider`, `Context` model)

- **Frontmost app + window detection** — knows which app/surface is active.
- **Selected-text capture** — Accessibility (AX) path, with an opt-in clipboard
  fallback (off by default).
- **Window screenshot context** — captures the active window image for the
  context-summary model (toggleable).
- **Privacy-first defaults** — selection persistence and clipboard capture are
  opt-in; context capture is gated in Settings → Privacy.

## 6. Memory & Knowledge Graph

Local, on-device memory over **Vordi's own transcriptions** (scoped to
Vordi data only — external AI-agent syncing was removed; see
`docs/future-agent-memory-app.md`).

- **Transcription corpus** — SQLite store with full-text search (FTS5).
  (`MemoryStore`)
- **Embeddings + semantic search** — local vector embeddings over transcripts.
  (`EmbeddingService`)
- **Knowledge graph** — entities (people, projects, tools, concepts, commands,
  places) with weighted edges, rendered in the Memory tab.
  (`KnowledgeGraphService`, `KnowledgeGraphView`)
- **Ask Memory (chat)** — hybrid retrieval (semantic + BM25 merge, entity boost,
  recency decay, recency fallback) → LLM answer with cited sources.
  (`MemoryChatService`)
- **On-demand indexing** — manual Sync builds embeddings + entity links;
  migration from the legacy run files runs once. (`IndexerService`)
- **Local LLM routing** — chat/answers can run via HTTP or a local CLI backend.
  (`LLMRouter`, `CLIBackend`, `CLIRunner`)

## 7. Insights

- **Usage insights dashboard** — aggregated stats over dictations.
  (`InsightsView`)

## 8. Notes, scratchpad & voice notes

- **Notes workspace** — rich-text note-taking surface.
  (`NotesWorkspaceView`, `NotesRichTextEditor`)
- **Floating notes window** — detachable notes overlay. (`FloatingNotesWindow`)
- **Voice notes** — stored dictated notes. (`VoiceNoteStore`, `VoiceNote` model)

## 9. Run Log

- **Run history** — every dictation recorded as a "run" with full pipeline
  stages (capture → transcription → post-processing). (`RunStore`,
  `RunRecorder`, `RunModel`)
- **Run Log UI** — list + detail view with pipeline breakdown and audio
  playback. (`RunLogView`)
- **Filesystem ring buffer** — runs persisted under Application Support.
  (`RunStore`)

## 10. On-screen UI surfaces

- **Notch pill / recording overlay** — animated pill near the notch showing
  recording state (waveform, pulsing dots), spring slide-in.
  (`NotchPillView`, `NotchPillWindow`, `NotchPillComponents`)
- **Menu bar app** — `MenuBarExtra` dropdown for quick access and status.
  (`MenuBarView`, `VordiApp`)
- **Floating chip window** — lightweight floating status/affordance.
  (`FloatingChipWindow`)
- **Main dashboard** — primary window with sidebar navigation.
  (`MainDashboardView`)

## 11. GitHub integration

- **Repo star prompt / card** — surfaces a "star the repo" affordance.
  (`GitHubService`, `StarRepoCard`)

## 12. Settings, onboarding & permissions

- **Settings window** — full preferences surface. (`SettingsView`)
- **Developer mode settings** — advanced/dev options. (`DevModeSettingsView`)
- **Permission onboarding** — guided cards for Accessibility and Input
  Monitoring grants. (`AccessibilityGuideView`, `InputMonitoringGuideView`,
  `PERMISSIONS.md`, `ONBOARDING_PLAN.md`)
- **Permission service** — runtime permission state + prompting.
  (`VordiApp` / `PermissionService`)

## 13. Design system

- **Shared design system** — `Theme` tokens, `Font.vf*` styles, and `VF*`
  components (buttons, badges, toggles, dropdowns, form rows, dialogs, loading
  overlay, etc.). Source of truth: `DesignSystem.swift` + `DESIGN.md`.

---

## Notes

- **Removed (2026-06-06):** external AI-agent session syncing (Claude Code,
  Codex, Gemini CLI) from Memory. Memory + Ask Memory are now scoped to
  Vordi's own transcriptions. The importer code is preserved for a possible
  future standalone app — see `docs/future-agent-memory-app.md`.
