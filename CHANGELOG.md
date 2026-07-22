# Changelog

## v0.1.2 - 2026-07-22

- Add the `grok-3p` launcher for third-party Grok Build CLI relays.
- Preserve official Grok configuration while injecting relay models at runtime.
- Restore global Codex defaults after DeepSeek, GLM, and third-party launcher runs.
- Document Grok relay setup, model ordering, effort metadata, and troubleshooting.

## v0.1.1 - 2026-06-18

- Refine README around the core `codex-3p` Codex API relay mode.
- Simplify DeepSeek and GLM setup notes to focus on API key entry.
- Clarify that DeepSeek and GLM installers require `codex-chat-bridge` in the same directory.

## v0.1.0 - 2026-06-18

- Add independent DeepSeek and GLM Coding Plan launchers.
- Add local chat bridge for Codex Responses-to-Chat-Completions conversion.
- Add DeepSeek and GLM stats commands for reasoning and usage logs.
- Add DeepSeek cache hit-rate logging.
- Simplify setup and usage documentation.
- Add git ignore rules for local credentials, logs, caches, and private copies.
