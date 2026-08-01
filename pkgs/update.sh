#!/usr/bin/env bash
# Bump sources.json to the newest amd64 build in Anthropic's APT index.
#
# Prints nothing but diagnostics on stderr; writes sources.json in place and
# emits `version=<v>` / `changed=<true|false>` on stdout as KEY=VALUE lines so
# CI can consume it. Exits non-zero on any inconsistency — a wrong hash must
# fail the updater, never land silently.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sources_json="$repo_root/sources.json"

base_url="https://downloads.claude.ai/claude-desktop/apt/stable"
index_url="$base_url/dists/stable/main/binary-amd64/Packages"

log() { printf '%s\n' "$*" >&2; }

log "fetching $index_url"
index=$(curl -fsSL --retry 3 --retry-delay 2 "$index_url")

# One "version<TAB>filename<TAB>sha256" line per stanza, then pick the highest
# version. `sort -V` is sufficient for upstream's strictly numeric x.y.z scheme.
newest=$(
  printf '%s\n' "$index" | awk '
    /^Package: /  { pkg = $2 }
    /^Version: /  { ver = $2 }
    /^Filename: / { fn  = $2 }
    /^SHA256: /   { sha = $2 }
    /^$/ {
      if (pkg == "claude-desktop" && ver != "" && fn != "" && sha != "")
        print ver "\t" fn "\t" sha
      pkg = ver = fn = sha = ""
    }
    END {
      if (pkg == "claude-desktop" && ver != "" && fn != "" && sha != "")
        print ver "\t" fn "\t" sha
    }
  ' | sort -V -k1,1 | tail -n1
)

[ -n "$newest" ] || { log "ERROR: no claude-desktop stanza found in the index"; exit 1; }

version=$(cut -f1 <<<"$newest")
filename=$(cut -f2 <<<"$newest")
index_sha=$(cut -f3 <<<"$newest")
url="$base_url/$filename"

log "newest upstream version: $version"
log "url:                     $url"
log "sha256 (from index):     $index_sha"

current=$(jq -r '.version' "$sources_json")
if [ "$current" = "$version" ]; then
  log "sources.json already at $version — nothing to do"
  echo "version=$version"
  echo "changed=false"
  exit 0
fi
log "current sources.json version: $current"

# Fetch into the store and take the hash from Nix itself rather than trusting
# the index blindly...
log "prefetching..."
prefetched=$(nix-prefetch-url --type sha256 "$url")
sri=$(nix hash convert --hash-algo sha256 --to sri "$prefetched")

# ...then cross-check against what the signed index advertises. A divergence
# means the pool object changed under a published hash: refuse to proceed.
index_sri=$(nix hash convert --hash-algo sha256 --to sri "$index_sha")
if [ "$sri" != "$index_sri" ]; then
  log "ERROR: hash mismatch for $url"
  log "  index advertises: $index_sri"
  log "  download hashes:  $sri"
  exit 1
fi
log "hash verified:           $sri"

tmp=$(mktemp)
jq --arg version "$version" \
   --arg url "$url" \
   --arg hash "$sri" \
   '.version = $version
    | .systems."x86_64-linux".url = $url
    | .systems."x86_64-linux".hash = $hash' \
   "$sources_json" >"$tmp"
mv "$tmp" "$sources_json"

log "sources.json updated: $current -> $version"
echo "version=$version"
echo "changed=true"
