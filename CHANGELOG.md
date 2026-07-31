# Changelog

## v0.2.0 - 2026-07-31

- Switch DeepSeek from the local Chat Completions bridge to the official Responses API.
- Refresh Responses-compatible DeepSeek models and reasoning-effort values from official sources on every launch.
- Remove the obsolete DeepSeek bridge statistics command and rename the remaining bridge as GLM-only.

## v0.1.4 - 2026-07-24

- Restore full Codex Third-Party README (codex-3p / deepseek / glm); document `grok-3p` as an added section instead of replacing the whole file.

## v0.1.3 - 2026-07-23

- Make `grok-3p` use isolated `~/.grok-3p` so official `grok` and `grok-3p` can run at the same time without fighting over `config.toml`.
- Keep real effort menus (from CLI metadata) and newest-first `3p-NN` ordering; direct relay (no local inference proxy).
- Never rewrite official `~/.grok/config.toml` (avoids JWT→relay 401 when both are open).

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
