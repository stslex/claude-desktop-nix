#!/usr/bin/env bash
# T1.4 — launch claude-desktop-cowork against a throwaway profile.
#
# Your real ~/.config/Claude is never read or written: every XDG base dir is
# redirected under $ROOT. Electron's userData, the app logs and the downloaded
# VM bundle all land there, so deleting $ROOT undoes the entire test.
set -euo pipefail

ROOT=${COWORK_TEST_ROOT:-/tmp/cowork-t14}
REPO=${COWORK_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

# --- refuse to run alongside another Claude Desktop -------------------------
# The helper socket lives at $XDG_RUNTIME_DIR/claude-cowork-vm.sock, which is
# NOT covered by the XDG redirection below. A second instance would connect to
# whichever cowork-linux-helper already owns that path — a different binary from
# a different build — and the test would be measuring the wrong thing.
if pgrep -f 'lib/claude-desktop/claude-desktop' >/dev/null 2>&1; then
  echo "refusing to start: a Claude Desktop is already running." >&2
  echo "quit it (tray -> Quit), then re-run. Offending processes:" >&2
  pgrep -af 'lib/claude-desktop/claude-desktop' | head -3 >&2
  exit 1
fi
if pgrep -f 'cowork-linux-helper' >/dev/null 2>&1; then
  echo "refusing to start: a cowork-linux-helper is still holding the socket." >&2
  pgrep -af 'cowork-linux-helper' >&2
  echo "it is orphaned; kill it with: pkill -f cowork-linux-helper" >&2
  exit 1
fi

PKG=$(nix build --no-link --print-out-paths "$REPO#claude-desktop-cowork")
echo "package: $PKG"
echo "profile: $ROOT   (delete this directory to undo the test)"

mkdir -p "$ROOT"/{config,cache,data,state}
export XDG_CONFIG_HOME="$ROOT/config"
export XDG_CACHE_HOME="$ROOT/cache"
export XDG_DATA_HOME="$ROOT/data"
export XDG_STATE_HOME="$ROOT/state"

# The sign-in callback is a claude:// deep link. The app registers
# x-scheme-handler/claude=com.anthropic.Claude.desktop in the throwaway
# mimeapps.list, but that desktop entry lives in the package's own share/ —
# we run the binary straight out of the store, so nothing would resolve the
# name and the redirect back from the browser silently does nothing.
export XDG_DATA_DIRS="$PKG/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

echo "XDG_CONFIG_HOME=$XDG_CONFIG_HOME"
echo "app log will also be at: $ROOT/config/Claude/logs/"
echo

"$PKG/bin/claude-desktop-cowork" 2>&1 | tee "$ROOT/stdout.log"
