#!/usr/bin/env bash
# Fails when flake.nix's `checks` attrset and a workflow's hand-written list of
# checks have drifted apart.
#
# Both workflows name the checks they run instead of calling `nix flake check`,
# because `nix flake check` offers no way to skip one — and skipping exactly one
# of them (`cowork-fhs-paths`, the trimmed-QEMU assertion, which compiles QEMU
# from source) is the entire reason the lists exist. The price of naming them is
# that a check added to flake.nix and forgotten in a list is never run and never
# reported: the workflow stays green and quietly covers less than it claims.
#
# This lives in one file rather than being copied into each workflow because a
# guard against duplicated lists going stale should not itself be a duplicated
# list going stale. ci.yml carried this check inline and update.yml did not,
# which is exactly the shape of the bug it exists to prevent.
#
# Usage: checks-accounted-for.sh <check-name>...
#
# The arguments are every check the caller either builds or has *deliberately*
# gated — not merely the ones it builds. A gated check is accounted for;
# demanding otherwise would make this script fail on the one arrangement it
# exists to permit.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "::error::checks-accounted-for.sh was called with no check names." >&2
  exit 2
fi

all=$(nix eval --json .#checks.x86_64-linux --apply builtins.attrNames | jq -r '.[]' | sort)
accounted=$(printf '%s\n' "$@" | sort)

if ! diff <(echo "$all") <(echo "$accounted"); then
  echo "::error::flake.nix's checks and ${GITHUB_WORKFLOW:-this workflow}'s list have drifted."
  echo "The '<' lines are in flake.nix and unaccounted for; the '>' lines are"
  echo "named here but no longer exist. Build the new check, or gate it"
  echo "deliberately and name it in the caller's list."
  exit 1
fi
