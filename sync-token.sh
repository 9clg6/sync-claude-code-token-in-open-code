#!/bin/bash
# Sync Claude Code OAuth token to OpenCode
# Reads the token from macOS Keychain and writes it to OpenCode's auth.json

set -e

# Read Claude Code credentials from macOS Keychain
TOKEN_JSON=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
if [ -z "$TOKEN_JSON" ]; then
  echo "Error: No Claude Code credentials found in Keychain."
  echo "Make sure Claude Code is installed and you are logged in (run: claude auth status)"
  exit 1
fi

# Extract OAuth tokens
ACCESS=$(echo "$TOKEN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])")
REFRESH=$(echo "$TOKEN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['refreshToken'])")
EXPIRES=$(echo "$TOKEN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['expiresAt'])")

if [ -z "$ACCESS" ] || [ -z "$REFRESH" ]; then
  echo "Error: Could not extract tokens from credentials."
  exit 1
fi

# Write to OpenCode auth.json (respects XDG_DATA_HOME)
AUTH_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
AUTH_FILE="$AUTH_DIR/auth.json"
mkdir -p "$AUTH_DIR"

# Merge with existing auth.json to preserve other providers
if [ -f "$AUTH_FILE" ]; then
  python3 -c "
import json, sys
try:
    with open('$AUTH_FILE') as f:
        auth = json.load(f)
except:
    auth = {}
auth['anthropic'] = {
    'type': 'oauth',
    'access': '$ACCESS',
    'refresh': '$REFRESH',
    'expires': $EXPIRES
}
with open('$AUTH_FILE', 'w') as f:
    json.dump(auth, f, indent=2)
"
else
  cat > "$AUTH_FILE" << EOF
{
  "anthropic": {
    "type": "oauth",
    "access": "$ACCESS",
    "refresh": "$REFRESH",
    "expires": $EXPIRES
  }
}
EOF
fi

echo "Done! Anthropic token synced to OpenCode."
echo "Expires: $(date -r $((EXPIRES / 1000)) 2>/dev/null || date -d @$((EXPIRES / 1000)) 2>/dev/null || echo "timestamp $EXPIRES")"
