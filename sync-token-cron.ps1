<#
.SYNOPSIS
    Token refresh loop: checks token expiry first, only opens Claude CLI
    when a refresh is actually needed, then syncs the token to OpenCode.
.DESCRIPTION
    Pre-flight:
    - Verifies Claude CLI is logged in (claude auth status)
    Each cycle:
    1. Read the current token expiry from credentials
    2. If the token is still valid (outside the jitter window) — sync it to OpenCode, then sleep
    3. If a refresh is needed — start Claude CLI briefly to refresh the token
    4. Exit Claude CLI
    5. Run sync-token.ps1 (sync token to OpenCode)
    6. Re-read the new token expiry
    7. Sleep until 30–90 minutes before expiry (randomized each cycle)
    8. Repeat
    Press Ctrl+C to stop.
.USAGE
    powershell -ExecutionPolicy Bypass -File "sync-token-cron.ps1"
#>

[CmdletBinding()]
param()

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$syncScript = Join-Path $scriptDir "sync-token.ps1"
$credFile = Join-Path (Join-Path $env:USERPROFILE ".claude") ".credentials.json"
$cycle = 1

# Jitter config: refresh window is randomized between these bounds (minutes)
$jitterMinMin = 30
$jitterMinMax = 91  # exclusive upper bound → actual max is 90

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Claude Token Refresh & Sync Loop" -ForegroundColor Cyan
Write-Host "  Sync script:  $syncScript" -ForegroundColor Cyan
Write-Host "  Credentials:  $credFile" -ForegroundColor Cyan
Write-Host "  Jitter range: ${jitterMinMin}-$($jitterMinMax - 1) min before expiry" -ForegroundColor Cyan
Write-Host "  Press Ctrl+C to stop" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --- Helper functions ---

function Test-ClaudeLoggedIn {
    try {
        $output = & claude auth status 2>&1 | Out-String
        $status = $output | ConvertFrom-Json
        return ($status.loggedIn -eq $true)
    }
    catch {
        return $false
    }
}

function Get-TokenExpiryDate {
    if (-not (Test-Path $credFile)) {
        return $null
    }
    try {
        $creds = Get-Content $credFile -Raw | ConvertFrom-Json
        $expires = $creds.claudeAiOauth.expiresAt
        if (-not $expires) { return $null }

        # Auto-detect epoch format: seconds vs milliseconds
        if ([long]$expires -lt 10000000000) {
            return (Get-Date "1970-01-01").AddSeconds([long]$expires).ToLocalTime()
        } else {
            return (Get-Date "1970-01-01").AddMilliseconds([long]$expires).ToLocalTime()
        }
    }
    catch {
        return $null
    }
}

function Invoke-TokenSync {
    Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Running token sync..." -ForegroundColor Blue
    try {
        & $syncScript
        Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Token sync completed." -ForegroundColor Blue
    }
    catch {
        Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] WARNING: Token sync failed: $_" -ForegroundColor DarkYellow
    }
}

function Invoke-ClaudeRefresh {
    Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Starting Claude CLI to refresh token..." -ForegroundColor Green
    $proc = Start-Process -FilePath "claude" -PassThru

    if ($null -eq $proc) {
        Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] ERROR: Failed to start Claude CLI." -ForegroundColor Red
        return $false
    }

    Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Claude CLI started (PID: $( $proc.Id )). Waiting for token refresh..." -ForegroundColor Yellow
    Start-Sleep -Seconds 15

    if (-not $proc.HasExited) {
        Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Stopping Claude CLI (PID: $( $proc.Id ))..." -ForegroundColor Yellow
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
    }

    Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Claude CLI stopped." -ForegroundColor Yellow
    return $true
}

function Get-SleepSeconds {
    param(
        [DateTime]$ExpiryDate,
        [int]$JitterMinutes
    )

    $now = Get-Date
    $wakeUpAt = $ExpiryDate.AddMinutes(-$JitterMinutes)
    $sleepSpan = $wakeUpAt - $now

    if ($sleepSpan.TotalSeconds -le 0) {
        return @{ Seconds = 0; WakeUpAt = $now; JitterMinutes = $JitterMinutes }
    }

    $sleepSec = [int][Math]::Floor($sleepSpan.TotalSeconds)
    return @{ Seconds = $sleepSec; WakeUpAt = $wakeUpAt; JitterMinutes = $JitterMinutes }
}

# --- Pre-flight checks ---
if (-not (Test-Path $syncScript)) {
    Write-Host "ERROR: sync-token.ps1 not found at $syncScript" -ForegroundColor Red
    exit 1
}

Write-Host "Checking Claude auth status..." -ForegroundColor Cyan
if (-not (Test-ClaudeLoggedIn)) {
    Write-Host "ERROR: Claude CLI is not logged in. Run 'claude auth login' first." -ForegroundColor Red
    exit 1
}
Write-Host "Claude CLI is logged in." -ForegroundColor Cyan
Write-Host ""

# --- Main loop ---
try {
    while ($true) {
        Write-Host "========================================" -ForegroundColor DarkGray
        Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Cycle #$cycle" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor DarkGray

        # Roll jitter for this cycle
        $jitterMinutes = Get-Random -Minimum $jitterMinMin -Maximum $jitterMinMax

        # --- Step 1: Check existing token ---
        $expiryDate = Get-TokenExpiryDate
        $needsRefresh = $true

        if ($null -ne $expiryDate) {
            $now = Get-Date
            $refreshDeadline = $expiryDate.AddMinutes(-$jitterMinutes)
            $remaining = $expiryDate - $now

            if ($now -lt $refreshDeadline) {
                # Token is still valid and outside the jitter window - no refresh needed
                $needsRefresh = $false
                $remainHours = [math]::Floor($remaining.TotalHours)
                $remainMins = $remaining.Minutes
                Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Token still valid (expires $( $expiryDate.ToString('yyyy-MM-dd HH:mm:ss') ), ${remainHours}h ${remainMins}m remaining). Skipping refresh, syncing token." -ForegroundColor DarkCyan
            } else {
                Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Token expires at $( $expiryDate.ToString('yyyy-MM-dd HH:mm:ss') ) - within ${jitterMinutes}min jitter window. Refresh needed." -ForegroundColor Magenta
            }
        } else {
            Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] No valid token found. Refresh needed." -ForegroundColor Magenta
        }

        # --- Step 2 & 3: Refresh (only if needed) + Sync (always) ---
        if ($needsRefresh) {
            $refreshed = Invoke-ClaudeRefresh

            if (-not $refreshed) {
                Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Refresh failed. Will retry in 60 seconds." -ForegroundColor Red
                Start-Sleep -Seconds 60
                $cycle++
                continue
            }
        }

        # Always sync — ensures OpenCode has the current token
        Invoke-TokenSync

        if ($needsRefresh) {
            # Re-read expiry after refresh
            $expiryDate = Get-TokenExpiryDate
        }

        # --- Step 4: Calculate sleep ---
        if ($null -eq $expiryDate) {
            $fallbackHours = 3
            $sleepSeconds = $fallbackHours * 3600
            Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Could not determine token expiry. Fallback: sleeping ${fallbackHours} hours." -ForegroundColor DarkYellow
        } else {
            $sleep = Get-SleepSeconds -ExpiryDate $expiryDate -JitterMinutes $jitterMinutes
            $sleepSeconds = $sleep.Seconds

            if ($sleepSeconds -le 0) {
                Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Token already within refresh window. Looping immediately." -ForegroundColor Magenta
            } else {
                $sleepHours = [math]::Floor([TimeSpan]::FromSeconds($sleepSeconds).TotalHours)
                $sleepMins = [TimeSpan]::FromSeconds($sleepSeconds).Minutes

                Write-Host ""
                Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Token expires:   $( $expiryDate.ToString('yyyy-MM-dd HH:mm:ss') )" -ForegroundColor Cyan
                Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Jitter:          $( $sleep.JitterMinutes ) min before expiry" -ForegroundColor Cyan
                Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Wake up at:      $( $sleep.WakeUpAt.ToString('yyyy-MM-dd HH:mm:ss') )" -ForegroundColor Cyan
                Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Sleeping for:    ${sleepHours}h ${sleepMins}m" -ForegroundColor Cyan
                Write-Host ""
            }
        }

        # --- Step 5: Sleep ---
        if ($sleepSeconds -gt 0) {
            Start-Sleep -Seconds $sleepSeconds
        }

        $cycle++
    }
}
finally {
    Write-Host ""
    Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Script stopped. Cleaning up..." -ForegroundColor Cyan
    Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss' )] Goodbye!" -ForegroundColor Cyan
}
