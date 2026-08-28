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
# Matched by /proc/PID/exe, not by cmdline. This checkout is named
# claude-desktop-nix, so a cmdline pattern matches any process that merely
# mentions the directory — an editor, a grep, the shell running this — and the
# guard would refuse to start against a phantom.
running() {
  local pat=$1 d e hit=1
  for d in /proc/[0-9]*; do
    e=$(readlink "$d/exe" 2>/dev/null) || continue
    case "$e" in
      *"$pat"*) echo "  pid ${d#/proc/}: $e" >&2; hit=0 ;;
    esac
  done
  return $hit
}

if running 'lib/claude-desktop/claude-desktop' 2>/dev/null >/dev/null; then
  echo "refusing to start: a Claude Desktop is already running." >&2
  echo "quit it (tray -> Quit), then re-run. Offending processes:" >&2
  running 'lib/claude-desktop/claude-desktop' >/dev/null
  exit 1
fi
if running 'cowork-linux-helper' 2>/dev/null >/dev/null; then
  echo "refusing to start: a cowork-linux-helper is still holding the socket." >&2
  running 'cowork-linux-helper' >/dev/null
  echo "it is orphaned; kill it with: pkill -f cowork-linux-helper" >&2
  exit 1
fi

# --- carry the host's browser into the sandbox -------------------------------
# XDG_CONFIG_HOME does not only move the app's profile: it moves the whole
# desktop-integration context, mimeapps.list included. A throwaway config has no
# http/https association at all, so `xdg-open` inside the sandbox cannot find
# the browser you actually use. It falls back to the first application
# registered for the scheme — and launches it with the throwaway XDG dirs too,
# i.e. with an empty browser profile.
#
# That is fatal for this test rather than untidy. Sign-in is an OAuth round trip
# through the system browser and only completes in a browser already signed in
# to the identity provider. Observed on 2026-08-18: the app opened a chromium
# with --database=$ROOT/config/chromium/Crashpad — a profile created seconds
# earlier — and the claude:// callback never came back. Four attempts, four
# failures, and nothing in either log said why.
#
# Naming the host's .desktop file is not enough either. This host's
# zen.desktop carries `Exec=zen --name zen %U`, a bare name resolved through
# PATH, and PATH inside the FHS sandbox is the sandbox's own — the browser is
# not in targetPkgs and never will be. That is precisely why chromium won the
# fallback: its entry happened to carry an absolute store path. So resolve the
# browser to an absolute path here, on the host, and hand the sandbox an entry
# it can actually execute.
host_browser=$(xdg-settings get default-web-browser 2>/dev/null || true)
if [ -z "${host_browser:-}" ]; then
  host_browser=$(sed -n 's/^x-scheme-handler\/https=//p' \
    "${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list" 2>/dev/null | head -1)
fi
host_browser=${host_browser%;}

browser_exec=""
if [ -n "$host_browser" ]; then
  IFS=: read -r -a _datadirs <<<"${XDG_DATA_HOME:-$HOME/.local/share}:$XDG_DATA_DIRS"
  for _d in "${_datadirs[@]}"; do
    [ -f "$_d/applications/$host_browser" ] || continue
    _exec=$(sed -n 's/^Exec=//p' "$_d/applications/$host_browser" | head -1)
    _cmd=${_exec%% *}
    case "$_cmd" in
      /*) browser_exec=$_cmd ;;
      *)  browser_exec=$(command -v "$_cmd" 2>/dev/null || true) ;;
    esac
    break
  done
fi

PKG=$(nix build --no-link --print-out-paths "$REPO#claude-desktop-cowork")
echo "package: $PKG"
echo "profile: $ROOT   (delete this directory to undo the test)"

mkdir -p "$ROOT"/{config,cache,data,state} "$ROOT/data/applications"

if [ -n "$browser_exec" ]; then
  echo "browser: $browser_exec   (carried over from the host as $host_browser)"

  # Its own entry under the throwaway XDG_DATA_HOME rather than a copy of the
  # host's, so the file the sandbox reads is one this script fully controls and
  # `rm -rf $ROOT` still undoes everything.
  cat > "$ROOT/data/applications/t14-host-browser.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Host browser (T1.4)
Exec=$browser_exec %U
NoDisplay=true
MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;
DESKTOP

  mimeapps="$ROOT/config/mimeapps.list"
  if ! grep -q '^x-scheme-handler/https=' "$mimeapps" 2>/dev/null; then
    if [ -f "$mimeapps" ] && grep -q '^\[Default Applications\]' "$mimeapps"; then
      # Insert under the group that is already there. Appending a second
      # [Default Applications] header instead would make GLib's key-file parser
      # reject the whole file, which fails closed in the worst way: every
      # association disappears, including the claude:// one the app wrote.
      tmp=$(mktemp)
      awk '
        { print }
        /^\[Default Applications\]$/ && !seeded {
          print "x-scheme-handler/http=t14-host-browser.desktop"
          print "x-scheme-handler/https=t14-host-browser.desktop"
          print "text/html=t14-host-browser.desktop"
          seeded = 1
        }' "$mimeapps" > "$tmp" && mv "$tmp" "$mimeapps"
    else
      cat >> "$mimeapps" <<'MIME'
[Default Applications]
x-scheme-handler/http=t14-host-browser.desktop
x-scheme-handler/https=t14-host-browser.desktop
text/html=t14-host-browser.desktop
MIME
    fi
  fi
else
  echo "WARNING: could not resolve the host's browser to an absolute path." >&2
  echo "         Sign-in will open whatever xdg-open falls back to, probably" >&2
  echo "         with an empty profile, and the OAuth round trip will not" >&2
  echo "         finish. See the comment above this warning." >&2
fi

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
