# Sync Claude Code OAuth token to OpenCode (Windows)
# Reads token from %USERPROFILE%\.claude\.credentials.json

$ErrorActionPreference = "Stop"

# Read credentials
$credFile = Join-Path (Join-Path $env:USERPROFILE ".claude") ".credentials.json"
if (-not (Test-Path $credFile)) {
    Write-Error "$credFile not found. Make sure Claude Code is installed and you are logged in (run: claude auth status)"
    exit 1
}

$creds = Get-Content $credFile -Raw | ConvertFrom-Json

# Validate nested oauth object before accessing properties
$oauth = $creds.claudeAiOauth
if (-not $oauth) {
    Write-Error "claudeAiOauth section not found in credentials."
    exit 1
}

$access  = $oauth.accessToken
$refresh = $oauth.refreshToken
$expires = $oauth.expiresAt

if (-not $access -or -not $refresh) {
    Write-Error "Could not extract tokens from credentials."
    exit 1
}

# Write to OpenCode auth.json
$authDir = if ($env:XDG_DATA_HOME) {
    Join-Path $env:XDG_DATA_HOME "opencode"
} else {
    Join-Path $env:LOCALAPPDATA "opencode"
}

if (-not (Test-Path $authDir)) {
    New-Item -ItemType Directory -Path $authDir -Force | Out-Null
}

$authFile = Join-Path $authDir "auth.json"

# Merge with existing auth.json to preserve other providers
# Compatible with both PowerShell 5.1 and 7+
$auth = @{}
if (Test-Path $authFile) {
    try {
        $existing = Get-Content $authFile -Raw | ConvertFrom-Json
        $existing.PSObject.Properties | ForEach-Object { $auth[$_.Name] = $_.Value }
    } catch {
        $auth = @{}
    }
}

$auth["anthropic"] = @{
    type    = "oauth"
    access  = $access
    refresh = $refresh
    expires = [long]$expires
}

$auth | ConvertTo-Json -Depth 10 | Set-Content $authFile -Encoding UTF8

# Auto-detect epoch format: seconds vs milliseconds
if ([long]$expires -lt 10000000000) {
    $expiresDate = (Get-Date "1970-01-01").AddSeconds([long]$expires).ToLocalTime()
} else {
    $expiresDate = (Get-Date "1970-01-01").AddMilliseconds([long]$expires).ToLocalTime()
}

Write-Host "Done! Anthropic token synced to OpenCode."
Write-Host "Expires: $expiresDate"