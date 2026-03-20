<#
.SYNOPSIS
    Syncs Claude Code OAuth token to OpenCode.

.DESCRIPTION
    Reads the OAuth token from Claude Code's credentials file and writes it
    into OpenCode's auth.json, preserving any existing provider entries.
    Works on both PowerShell 5.1 and 7+.

.PARAMETER Verbose
    Show detailed step-by-step output of what the script is doing.

.EXAMPLE
    .\sync-claude-to-opencode.ps1
    Syncs the token silently.

.EXAMPLE
    .\sync-claude-to-opencode.ps1 -Verbose
    Syncs the token with detailed progress output.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# --- Helper: mask tokens for safe display ---
function Get-MaskedToken {
    param([string]$Token)
    if ($Token.Length -le 8) { return "********" }
    return $Token.Substring(0, 4) + ("*" * ($Token.Length - 8)) + $Token.Substring($Token.Length - 4)
}

# --- Step 1: Locate and read Claude Code credentials ---
Write-Verbose "=== Step 1: Reading Claude Code credentials ==="

$credFile = Join-Path (Join-Path $env:USERPROFILE ".claude") ".credentials.json"
Write-Verbose "  Credentials path: $credFile"

if (-not (Test-Path $credFile)) {
    Write-Error "$credFile not found. Make sure Claude Code is installed and you are logged in (run: claude auth status)"
    exit 1
}

Write-Verbose "  File exists, reading content..."
$rawContent = Get-Content $credFile -Raw
$creds = $rawContent | ConvertFrom-Json
Write-Verbose "  Parsed JSON successfully. Top-level keys: $($creds.PSObject.Properties.Name -join ', ')"

# --- Step 2: Extract OAuth tokens ---
Write-Verbose "=== Step 2: Extracting OAuth tokens ==="

$oauth = $creds.claudeAiOauth
if (-not $oauth) {
    Write-Error "claudeAiOauth section not found in credentials."
    exit 1
}
Write-Verbose "  Found claudeAiOauth section."

$access  = $oauth.accessToken
$refresh = $oauth.refreshToken
$expires = $oauth.expiresAt

if (-not $access -or -not $refresh) {
    Write-Error "Could not extract tokens from credentials."
    exit 1
}

Write-Verbose "  Access token:  $(Get-MaskedToken $access)"
Write-Verbose "  Refresh token: $(Get-MaskedToken $refresh)"
Write-Verbose "  Expires (raw): $expires"

# --- Step 3: Resolve OpenCode auth directory ---
Write-Verbose "=== Step 3: Resolving OpenCode auth directory ==="

$authDir = if ($env:XDG_DATA_HOME) {
    Write-Verbose "  Using XDG_DATA_HOME: $env:XDG_DATA_HOME"
    Join-Path $env:XDG_DATA_HOME "opencode"
} else {
    Write-Verbose "  XDG_DATA_HOME not set, falling back to LOCALAPPDATA: $env:LOCALAPPDATA"
    Join-Path $env:LOCALAPPDATA "opencode"
}

Write-Verbose "  Auth directory: $authDir"

if (-not (Test-Path $authDir)) {
    Write-Verbose "  Directory does not exist, creating it..."
    New-Item -ItemType Directory -Path $authDir -Force | Out-Null
    Write-Verbose "  Created."
} else {
    Write-Verbose "  Directory already exists."
}

$authFile = Join-Path $authDir "auth.json"
Write-Verbose "  Auth file: $authFile"

# --- Step 4: Load existing auth.json (if any) ---
Write-Verbose "=== Step 4: Loading existing auth.json ==="

$auth = @{}
if (Test-Path $authFile) {
    Write-Verbose "  Existing auth.json found, merging..."
    try {
        $existing = Get-Content $authFile -Raw | ConvertFrom-Json
        $existingKeys = @()
        $existing.PSObject.Properties | ForEach-Object {
            $auth[$_.Name] = $_.Value
            $existingKeys += $_.Name
        }
        Write-Verbose "  Existing providers: $($existingKeys -join ', ')"
    } catch {
        Write-Verbose "  Failed to parse existing auth.json ($_), starting fresh."
        $auth = @{}
    }
} else {
    Write-Verbose "  No existing auth.json, creating new one."
}

# --- Step 5: Write updated auth.json ---
Write-Verbose "=== Step 5: Writing updated auth.json ==="

$auth["anthropic"] = @{
    type    = "oauth"
    access  = $access
    refresh = $refresh
    expires = [long]$expires
}

$finalKeys = @($auth.Keys) -join ", "
Write-Verbose "  Providers in output: $finalKeys"

$json = $auth | ConvertTo-Json -Depth 10
$json | Set-Content $authFile -Encoding UTF8
Write-Verbose "  Wrote $($json.Length) bytes to $authFile"

# --- Step 6: Display result ---
Write-Verbose "=== Step 6: Summary ==="

# Auto-detect epoch format: seconds vs milliseconds
if ([long]$expires -lt 10000000000) {
    $expiresDate = (Get-Date "1970-01-01").AddSeconds([long]$expires).ToLocalTime()
    Write-Verbose "  Epoch format: seconds"
} else {
    $expiresDate = (Get-Date "1970-01-01").AddMilliseconds([long]$expires).ToLocalTime()
    Write-Verbose "  Epoch format: milliseconds"
}

$now = Get-Date
$remaining = $expiresDate - $now
if ($remaining.TotalSeconds -gt 0) {
    Write-Verbose "  Time remaining: $([math]::Floor($remaining.TotalHours))h $($remaining.Minutes)m"
} else {
    Write-Warning "Token is already expired! Re-authenticate in Claude Code (run: claude auth login)"
}

Write-Host "Done! Anthropic token synced to OpenCode."
Write-Host "  Source:  $credFile"
Write-Host "  Target:  $authFile"
Write-Host "  Expires: $expiresDate"