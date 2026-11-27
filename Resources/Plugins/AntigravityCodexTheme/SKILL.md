---
name: antigravity-codex-theme
description: Deploy, selectively install, relaunch with CDP opt-in (Antigravity 2.33.0+), diagnose, configure, or troubleshoot antigravity-codex-theme (Codex pure-white/charcoal-dark theme, Chinese UI localization, 4-state session status indicator, expandable L1/L2 usage panels, and per-turn footer stats) on macOS, Windows, and Linux.
---

# Agent Operations Guide: antigravity-codex-theme

Follow this guide when a user asks you to install, selectively install specific modules, update for Antigravity `2.33.0+`, verify, customize, troubleshoot, rollback, or uninstall **`antigravity-codex-theme`**.

> **Platform & Node.js Alignment**:
> - Minimum Node.js version: **`>= 22.13.0`** (aligned with `package.json`, required for built-in `node:sqlite`).
> - Supported Antigravity versions: **`2.30.x` – `2.35.2+`** (includes single-icon M1/M2 `--remote-debugging-port=0` opt-in relaunch for `2.33.0+`).
> - Real-device verified platforms: **macOS, Windows, and Linux desktops** with Antigravity **`2.31.0` / `2.32.1` / `2.33.0` / `2.34.0` / `2.35.2`** (covering macOS `LaunchAgent`, Windows `schtasks` + `.lnk`, and Linux `systemd --user` + `.desktop`), plus GitHub Actions CI (`ubuntu-latest`) for syntax checks and unit tests.

## 1. Key Paths & Service Identifiers

| Item | Path / Identifier |
| :--- | :--- |
| Deployed runtime directory | `~/.gemini/antigravity/codex-theme` |
| Service wrapper script | `~/.gemini/antigravity/scripts/antigravity-codex-daemon.mjs` |
| macOS LaunchAgent | `com.antigravity.codex-theme` (`~/Library/LaunchAgents/com.antigravity.codex-theme.plist`) |
| macOS daemon logs | `/tmp/antigravity-codex-daemon.log`, `/tmp/antigravity-codex-daemon.err` |
| Linux systemd user unit | `antigravity-codex-theme.service` (`~/.config/systemd/user/antigravity-codex-theme.service`) |
| Windows autostart | Scheduled Task `AntigravityCodexThemeDaemon` / `AntigravityCodexThemeDaemon.vbs` |
| User hot-reload config | `~/.gemini/antigravity/codex-theme/user/config.json` |

## 2. Selectable Core Modules

Users can install all features or only the modules they request:

| Feature ID | Config Keys | Purpose |
| :--- | :--- | :--- |
| `theme` | `modules.theme` | Codex pure-white light & charcoal-dark themes (`00-base.css`, `10-light-codex.css`, `20-dark-codex.css`, `20-theme-sync.js`, including Swarm iframe sync) |
| `i18n` | `modules.i18n` | 2,000+ Chinese UI & Electron native right-click context menu localization entries (`core/i18n.json`, `60-i18n-engine.js`, preserving English model names & project/branch/group names) |
| `metrics` | `modules.metrics`, `modules.quota`, `modules.quotaSidebar`, `modules.sshRemote` | 4-state session status indicator (`会话状态`), L1/L2 expandable usage panels, Ink 5h/7d model quota display with live refresh & passive sync, split-screen multi-conversation stats, Side Question pane, and opt-in in-memory SSH Remote telemetry via `sshHosts` |
| `fixes` | `modules.deadlockHealer`, `modules.zoomShortcuts` | Settings modal router deadlock fix & `Cmd/Ctrl + -/=/0` zoom shortcuts (`10-guards.js`) |
| `suggest` | `modules.promptSuggestions` | Opt-in (default `false`) Claude Code-style Ghost Text + `Tab`/`→` prompt suggestions via persistent background `agy` worker (`prompt-suggest.mjs`, `70-prompt-suggestions.js`, `40-prompt-suggestions.css`) |

## 3. Standard & Selective Workflows

### Fast Sparse Clone (Recommended for AI Agents — skips `assets/` screenshots & `tests/`)
```bash
git clone --depth=1 --filter=blob:none --sparse https://github.com/nkjDSLcvanv/antigravity-codex-theme.git
cd antigravity-codex-theme
git sparse-checkout set core user
```
If the user requests only specific modules without even downloading unused `core/` files, run `git sparse-checkout set --no-cone ...` with only the needed files (for an existing clone, run `node install.mjs sparse-paths --only <features>` to list exact paths).

### Install or Upgrade (auto-migrates older theme daemons cleanly)
```bash
# Install all core features
node install.mjs install

# Or install only selected modules (e.g., i18n + session status/telemetry without Codex theme)
node install.mjs install --only i18n,metrics

# Check for or apply SHA-256 verified updates directly from GitHub (preserves user/ config)
node install.mjs update --check
node install.mjs update
```
Optional flags:
- `--only theme,i18n,metrics,fixes,suggest`: enable only the specified feature groups (`suggest` is opt-in and off by default unless listed)
- `--without <features>`: exclude specific feature groups
- `--minimal`: prune excluded feature files inside `~/.gemini/antigravity/codex-theme/core` and rebuild its manifest
- `--with-launcher`: (macOS only) optionally create `~/Applications/Antigravity (Codex Theme).app`; by default macOS uses single-icon mode (`single-icon-m2-relay`) with no duplicate app icon
- `--sync-user`: overwrite `user/*` files from repository defaults
- `--channel stable|insiders`: restrict to one Antigravity channel

### Antigravity `2.33.0+` CDP Opt-In Relaunch & Anti-Self-Termination Rule
Antigravity `2.33.0+` no longer opens `DevToolsActivePort` by default unless launched with `--remote-debugging-port=0`.
- **Single-icon M2 cold-start relay (`cdpAutoRelaunch: true`)**: On macOS (and post-update restarts on Windows/Linux), the background daemon automatically relaunches a freshly opened Antigravity process with `--remote-debugging-port=0` during its first `12s` (`25s` for `--updated`), while **strictly exempting** any already-running session past that window.
- **When `install` or `doctor` reports `"cdpStatus": "missing_opt_in_flag"`**:
  - **Case A (Agent running inside Antigravity itself)**: **NEVER run `relaunch --force`** during an active turn (it would terminate your own Antigravity host window; running without `--force` is also safely blocked with exit code `2` by the 15s `.db-wal` active-conversation guard). Tell the user the update is deployed and ask them to quit and reopen Antigravity once after the reply completes (M2 will attach `--remote-debugging-port=0` automatically), or run `node ~/.gemini/antigravity/codex-theme/install.mjs relaunch` from an external terminal.
  - **Case B (Agent running in an external terminal such as iTerm2 / Claude Code / Codex / Windows Terminal with no active Antigravity turn)**: Run `node ~/.gemini/antigravity/codex-theme/install.mjs relaunch` directly to restart Antigravity with `--remote-debugging-port=0` and verify live injection.

### Diagnose Environment & Live Injection
```bash
node --disable-warning=ExperimentalWarning install.mjs doctor
```
Verify in JSON output:
- `ok === true` (returns `false` with `remediation` when `cdpStatus === "missing_opt_in_flag"`)
- `node.tier` shows `FULL (>= 22.13.0, ...)`
- `coreIntegrity.clean === true`
- `liveWindow.reachable === true` and `liveWindow.state.hasStyle === true` (`#ag-codex-theme`); when `theme` is enabled, `preset` is `"codex-pure-white"` or `"codex-dark"`; when `i18n` is enabled, `dictCount >= 1800`; when `metrics` is enabled in an active chat, `pillMounted === true`

### Safe-Mode Troubleshooting
```bash
node --disable-warning=ExperimentalWarning install.mjs verify --safe-mode
```
If `--safe-mode` works cleanly, inspect `~/.gemini/antigravity/codex-theme/user/` rather than `core/`.

### Configuration Tweaks (Embedded Settings UI or Hot-Reloaded `user/config.json`)
Users can toggle modules, pick prompt-suggestion models, edit `sshHosts`, trigger manual reload, and check/apply plugin updates visually inside Antigravity under **Settings → Codex Theme** (`设置 → Codex 主题`), or edit `~/.gemini/antigravity/codex-theme/user/config.json`:
- **Toggle individual modules**: `"modules": { "theme": true, "i18n": true, "metrics": true, "sshRemote": false, "promptSuggestions": false, "deadlockHealer": true, "zoomShortcuts": true, "cdpAutoRelaunch": true }`
- **Enable opt-in prompt suggestions** (zero overhead / no `agy` process when disabled): set `"modules": { "promptSuggestions": true }` (optional `"promptSuggestionModel": "gemini-3.8-flash-low"`)
- **Enable opt-in SSH Remote telemetry** (reads remote SQLite via read-only `python3` over `ssh`, strips all conversation text remotely, zero local `.db` copy): set `"modules": { "sshRemote": true }` and `"sshHosts": ["your-ssh-host"]`
- **Switch status bar density**: `"telemetryLayout": "detailed"` (`"compact"` is default)
- **Switch cache metric mode**: `"telemetryCacheMode": "step"` (`"session"` is default)
- **Disable entire plugin cleanly**: `"enabled": false`

### Rollback / Uninstall
```bash
node install.mjs rollback
node install.mjs uninstall
```
`uninstall` stops the daemon, removes autostart registrations and managed CDP launchers, and restores original English UI and native styling while preserving `~/.gemini/antigravity/codex-theme/user/`, `backups/`, `core.prev/`, and `"remote-debugging-port"` in `argv.json`.

## 4. Verification Checklist (For Maintainers / Contributors)
After editing any file under `core/`, always regenerate `core/manifest.json` before running checks or tests:
```bash
node install.mjs build-manifest
npm run check
npm test
```
