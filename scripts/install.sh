#!/bin/bash
# One-line build-from-source install. Builds the app, copies it to /Applications, wires up the
# Claude Code hooks, and launches it. No Apple Developer account or notarization needed —
# a locally built app isn't quarantined, so Gatekeeper trusts it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_SRC="build/Pookify.app"
APP_DST="/Applications/Pookify.app"

echo "▸ Building…"
./scripts/build.sh

if [[ ! -w /Applications ]]; then
  echo "✗ Can't write to /Applications (it needs an administrator account)."
  echo "  The app was built at: $APP_SRC"
  echo "  Drag it into /Applications in Finder (you'll be asked to authenticate), then run:"
  echo "      \"/Applications/Pookify.app/Contents/MacOS/Pookify\" --install"
  echo "  (Don't 'sudo' this script — that would wire hooks into root's config, not yours.)"
  exit 1
fi

echo "▸ Installing to /Applications…"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "▸ Wiring hooks into Claude Code…"
"$APP_DST/Contents/MacOS/Pookify" --install || true

# Deploy the status line mirror. It's the *writer* half of the context ring: it hands Claude
# Code's authoritative context_window.used_percentage to the notch via a per-session sidecar
# (state.d/ctx-<sessionId>.json), which the ring prefers over its token heuristic. Keeping it
# tracked + deployed here means `git pull && install.sh` restores both halves in lockstep.
STATUSLINE_DST="$HOME/.claude/pookify-statusline.py"
echo "▸ Installing the status line ($STATUSLINE_DST)…"
mkdir -p "$HOME/.claude"
cp statusline/pookify-statusline.py "$STATUSLINE_DST"
chmod +x "$STATUSLINE_DST"
echo "  Note: this does NOT edit settings.json. If the status line isn't showing, wire it once:"
echo '        "statusLine": { "type": "command", "command": "/usr/bin/python3 '"$STATUSLINE_DST"'" }'

echo "▸ Launching…"
open "$APP_DST"

echo ""
echo "✓ Installed. Start (or continue) a Claude Code session and the island appears"
echo "  on your notch. Right-click it to pick the Claude icon or quit."
