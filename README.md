# Use Anthropic Models in OpenCode with Your Claude Pro/Max Subscription

Use Claude models in [OpenCode](https://opencode.ai) using your existing Claude Pro or Max subscription — no API key needed. This works by syncing the OAuth token from Claude Code (CLI) into OpenCode.

## Prerequisites

- **macOS**, **Linux** or **Windows**
- **[OpenCode](https://opencode.ai)** installed (desktop app or CLI)
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** (CLI) installed and logged in
- An active **Claude Pro or Max** subscription

## Setup

### 1. Make sure Claude Code is logged in

```bash
claude auth status
```

You should see something like:

```json
{
  "loggedIn": true,
  "authMethod": "claude.ai",
  "subscriptionType": "max"
}
```

If not logged in, run `claude` and follow the login flow.

### 2. Clone this repo

```bash
git clone https://github.com/9clg6/sync-claude-code-token-in-open-code.git
cd sync-claude-code-token-in-open-code
chmod +x sync-token.sh  # not needed on Windows
```

### 3. Run the sync script

**macOS / Linux / Git Bash:**

```bash
./sync-token.sh
```

**Windows (PowerShell):**

```powershell
.\sync-token.ps1
```

Expected output:

```
Done! Anthropic token synced to OpenCode.
Expires: Fri Mar 20 05:22:36 CET 2026
```

### 4. Verify

```bash
# macOS desktop app:
/Applications/OpenCode.app/Contents/MacOS/opencode-cli providers list

# Or if installed via npm/homebrew:
opencode providers list
```

You should see:

```
●  Anthropic  oauth
└  1 credentials
```

### 5. Open OpenCode

Launch the OpenCode app. Anthropic models (Claude Sonnet, Opus, Haiku) should now appear in the model selector.

## Token Renewal

The OAuth token expires approximately every **6 hours**. You have two approaches to keep it fresh:

### Manual Renewal

When Anthropic models stop working in OpenCode:

1. Use Claude Code in your terminal (any command) — this automatically refreshes the token
2. Run the sync script:

**macOS / Linux / Git Bash:**
```bash
./sync-token.sh
```

**Windows (PowerShell):**
```powershell
.\sync-token.ps1
```

3. Restart OpenCode

### Automated Renewal

#### Windows — `sync-token-cron.ps1` (Recommended)

For a set-and-forget solution, use the `sync-token-cron.ps1` automation loop:

```powershell
powershell -ExecutionPolicy Bypass -File "sync-token-cron.ps1"
```

This script verifies you're logged in at startup, then checks the token **before** doing anything — Claude CLI is only started when a refresh is actually needed:

1. **Pre-flight:** Verifies Claude CLI is logged in (`claude auth status`) — exits with a clear error if not
2. Reads the current token expiry from `~/.claude/.credentials.json`
3. If the token is still valid → skips refresh, syncs token to OpenCode, then sleeps
4. If a refresh is needed → starts Claude CLI briefly (~15s), exits it, runs `sync-token.ps1`
5. Sleeps until **30–90 minutes** before expiry (randomized each cycle to avoid predictable patterns)
6. Loops back to step 2 automatically

Example output (startup + first refresh):

```
============================================
  Claude Token Refresh & Sync Loop
  Jitter range: 30-90 min before expiry
  Press Ctrl+C to stop
============================================

Checking Claude auth status...
Claude CLI is logged in.

========================================
[2026-03-21 14:00:00] Cycle #1
========================================
[2026-03-21 14:00:00] No valid token found. Refresh needed.
[2026-03-21 14:00:00] Starting Claude CLI to refresh token...
[2026-03-21 14:00:00] Claude CLI started (PID: 12345). Waiting for token refresh...
[2026-03-21 14:00:15] Stopping Claude CLI (PID: 12345)...
[2026-03-21 14:00:17] Claude CLI stopped.
[2026-03-21 14:00:17] Running token sync...
Done! Anthropic token synced to OpenCode.
[2026-03-21 14:00:18] Token sync completed.

[2026-03-21 14:00:18] Token expires:   2026-03-21 20:00:00
[2026-03-21 14:00:18] Jitter:          47 min before expiry
[2026-03-21 14:00:18] Wake up at:      2026-03-21 19:13:00
[2026-03-21 14:00:18] Sleeping for:    5h 12m
```

If Claude CLI is not logged in, the script exits immediately:

```
Checking Claude auth status...
ERROR: Claude CLI is not logged in. Run 'claude auth login' first.
```

Example output (subsequent cycle — token still valid):

```
========================================
[2026-03-21 19:13:00] Cycle #2
========================================
[2026-03-21 19:13:00] Token expires at 2026-03-21 20:00:00 — within 63min jitter window. Refresh needed.
[2026-03-21 19:13:00] Starting Claude CLI to refresh token...
...
```

If the script is restarted while the token is still fresh, it skips the refresh but still syncs:

```
========================================
[2026-03-21 15:30:00] Cycle #1
========================================
[2026-03-21 15:30:00] Token still valid (expires 2026-03-21 20:00:00, 4h 30m remaining). Skipping refresh, syncing token.
[2026-03-21 15:30:00] Running token sync...
Done! Anthropic token synced to OpenCode.
[2026-03-21 15:30:01] Token sync completed.

[2026-03-21 15:30:01] Token expires:   2026-03-21 20:00:00
[2026-03-21 15:30:01] Jitter:          52 min before expiry
[2026-03-21 15:30:01] Wake up at:      2026-03-21 19:08:00
[2026-03-21 15:30:01] Sleeping for:    3h 37m
```

#### Linux / macOS — Automate with cron (optional)

To automatically sync the token every 5 hours:

```bash
crontab -e
```

Add this line (replace the path with where you cloned the repo):

```
0 */5 * * * /path/to/sync-token.sh
```

> **Note:** The cron job syncs the token but doesn't refresh it — Claude Code must have been used recently enough for the token to still be valid. If both tokens expire, open Claude Code once to trigger a refresh, then run the script. On Windows, `sync-token-cron.ps1` handles both refresh and sync automatically.

## How It Works

The script auto-detects your OS:

- **macOS**: first tries the **macOS Keychain** (multiple known Claude service names), then falls back to **`~/.claude/.credentials.json`**
- **Linux**: reads the token from **`~/.claude/.credentials.json`** (thanks [@minivolk](https://github.com/minivolk))
- **Windows** *(untested — contributions welcome)*: reads the token from **`%USERPROFILE%\.claude\.credentials.json`** (use `sync-token.ps1` for PowerShell, or `sync-token.sh` via Git Bash)

It then writes the token to `~/.local/share/opencode/auth.json` in the OAuth format that OpenCode expects:

```json
{
  "anthropic": {
    "type": "oauth",
    "access": "sk-ant-oat01-...",
    "refresh": "sk-ant-ort01-...",
    "expires": 1773980556114
  }
}
```

OpenCode recognizes Anthropic as an authenticated provider and exposes Claude models.

## Troubleshooting

**"No Claude Code credentials found in macOS Keychain or ~/.claude/.credentials.json"** (macOS)
- Make sure Claude Code is installed and you've logged in at least once
- Run `claude auth status` to check

**"~/.claude/.credentials.json not found"** (Linux/Windows)
- Make sure Claude Code is installed and you've logged in at least once
- Run `claude auth status` to check

**OpenCode doesn't show Anthropic models**
- Run `opencode providers list` to verify the credential is detected
- Make sure the token hasn't expired — re-run `./sync-token.sh`
- Restart OpenCode after syncing

**Token expires too quickly**
- The token lasts ~6 hours. Use `sync-token-cron.ps1` on Windows for automatic refresh with randomized timing, cron on Linux/macOS, or re-run the script manually when needed

**"sync-token-cron.ps1 falls back to 3h sleep"**
- The credentials file couldn't be read or has no `expiresAt` field. Run `claude auth status` to verify Claude Code is logged in, then run the script once manually to confirm it works

## OpenCode Desktop v1.2.27 Backup

Starting with OpenCode v1.3.0, Anthropic is no longer a built-in provider. A backup of v1.2.27 (the last version with Anthropic built-in) is available in the [Releases](https://github.com/9clg6/sync-claude-code-token-in-open-code/releases/tag/v1.2.27) section.
