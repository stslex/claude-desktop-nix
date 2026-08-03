# Static regression guard for the libraries the payload dlopen()s.
#
# Why this exists: `nix build` stays green when a dlopen'd soname stops
# resolving, because dlopen failure is a runtime event, not a link error. The
# specific regression it guards is silent and security-relevant — if
# libsecret-1.so.0 drops out of the RUNPATH (an Electron bump changing layout,
# someone editing runtimeLibs, appendRunpaths breaking), os_crypt falls back
# from a keyring-derived v11 key to the hardcoded-password v10 path and the
# session token quietly stops being protected.
#
# Three assertions, because resolving a hand-written list only covers the
# first one:
#
#   1. RESOLVE   — every soname this package claims to provide resolves from
#                  the RUNPATH of the object that opens it.
#   2. REFERENCE — every soname it claims to provide is still named by the
#                  shipped payload. Catches list entries upstream stopped
#                  using, which would otherwise keep passing (1) forever.
#   3. NOVELTY   — every soname-shaped string in the payload is accounted for:
#                  DT_NEEDED (autoPatchelfHook's job), bundled with the app,
#                  provided by us, or waived by name with a reason. Catches an
#                  upstream bump that starts dlopen()ing something new, which
#                  (1) and (2) cannot see.
#
# (2) and (3) are what tie the lists in passthru to the binary. Keeping the
# lists next to runtimeLibs is a convention and conventions drift; the binary
# is rescanned on every run, and the lists are only the expected answer.
#
# Deliberately static: it resolves sonames against RUNPATH entries rather than
# launching the app. An Xvfb launch check would be strictly worse here — it
# needs a display, a D-Bus session and a live Secret Service provider to tell
# v10 from v11, none of which exist in the build sandbox, and it would be slow
# and flaky in exchange for testing the same property this resolves directly.
#
# Limits of the scan, stated rather than papered over: it is a string scan, so
# a soname assembled at runtime is invisible to it (libva is the live example —
# the binary carries "libva.so" and appends the ABI version, which is why an
# unversioned stem counts as a reference), a string can be present without any
# code path reaching the dlopen, and only ELF objects are scanned — nothing
# inside app.asar is.
{
  lib,
  runCommand,
  binutils,
  patchelf,
  claude-desktop,
}:

runCommand "claude-desktop-dlopen-runpath"
  {
    nativeBuildInputs = [
      binutils # strings
      patchelf # --print-rpath / --print-needed
    ];
    app = claude-desktop;
    provided = lib.concatStringsSep " " claude-desktop.dlopenSonames;
    dependsOnly = lib.concatStringsSep " " claude-desktop.dlopenSonamesDependsOnly;
    unprovided = lib.concatStringsSep " " claude-desktop.dlopenSonamesUnprovided;
  }
  ''
    set -euo pipefail

    appdir=$app/lib/claude-desktop
    main=$appdir/claude-desktop
    test -f "$main" || { echo "FAIL: main executable missing at $main"; exit 1; }

    # Anything shaped like a soname: libfoo.so, libfoo.so.1, libfoo-2.0.so.0.
    sonameRe='\blib[A-Za-z0-9_+.-]*\.so(\.[0-9]+)*\b'

    # libfoo.so.1 -> libfoo.so ; libfoo.so -> libfoo.so
    stemOf() { case "$1" in *.so.*) echo "''${1%%.so.*}.so" ;; *) echo "$1" ;; esac; }

    rc=0

    # ------------------------------------------------------------ inventory
    declare -A RPATH=() SCANNED=() SEENIN=() NEEDED=() BUNDLED=()
    elfs=()

    while IFS= read -r f; do
      if [ "$(head -c4 "$f" 2>/dev/null | tr -d '\0' || true)" = $'\x7fELF' ]; then
        elfs+=("$f")
      fi
    done < <(find "$app" -type f | sort)

    while IFS= read -r f; do
      BUNDLED["$f"]=1
    done < <(find "$app" -type f -name 'lib*.so*' -printf '%f\n' | grep -xE "$sonameRe" || true)

    for f in "''${elfs[@]}"; do
      rel=''${f#$app/}
      RPATH["$rel"]=$(patchelf --print-rpath "$f" 2>/dev/null || true)
      while IFS= read -r s; do
        SCANNED["$s"]=1
        SEENIN["$s"]="''${SEENIN[$s]-}$rel "
      done < <(strings -a "$f" | grep -oE "$sonameRe" | sort -u)
      while IFS= read -r n; do
        NEEDED["$n"]=1
      done < <(patchelf --print-needed "$f" 2>/dev/null || true)
    done

    echo "scanned ''${#elfs[@]} ELF objects, ''${#SCANNED[@]} distinct soname strings"

    # Echoes the RUNPATH directory a soname resolves from, or returns 1.
    resolveIn() { # $1 = path relative to $app, $2 = soname
      local dirs d
      IFS=: read -ra dirs <<< "''${RPATH[$1]-}"
      for d in "''${dirs[@]}"; do
        if [ -n "$d" ] && [ -e "$d/$2" ]; then echo "$d"; return 0; fi
      done
      return 1
    }

    # ------------------------------------------- 0. RUNPATH structural sanity
    #
    # An empty RUNPATH element means "current directory" at load time — the
    # same class of bug as an empty LD_LIBRARY_PATH element. Never acceptable.
    # (An object with no RUNPATH at all is fine; that is not this bug.)
    for rel in "''${!RPATH[@]}"; do
      if [ -n "''${RPATH[$rel]}" ]; then
        case ":''${RPATH[$rel]}:" in
          *::*)
            echo "FAIL: empty RUNPATH element in $rel (resolves to the cwd)"
            rc=1
            ;;
        esac
      fi
    done

    # -------------------------------------------------------- 1. RESOLVE
    echo
    echo "== resolve: provided sonames, from the main executable's RUNPATH"
    for s in $provided $dependsOnly; do
      if d=$(resolveIn "lib/claude-desktop/claude-desktop" "$s"); then
        printf '  ok      %-26s -> %s\n' "$s" "$d"
      else
        printf '  FAIL    %-26s unresolvable from RUNPATH\n' "$s"
        rc=1
      fi
    done

    echo
    echo "== resolve: and from the RUNPATH of every other object that names them"
    pairs=0
    for s in $provided; do
      for rel in ''${SEENIN[$s]-}; do
        if [ "$rel" = "lib/claude-desktop/claude-desktop" ]; then continue; fi
        pairs=$((pairs + 1))
        if ! resolveIn "$rel" "$s" >/dev/null; then
          printf '  FAIL    %-26s named by %s, unresolvable from its RUNPATH\n' "$s" "$rel"
          rc=1
        fi
      done
    done
    echo "  ok      $pairs further (object, soname) pairs resolve"

    # ------------------------------------------------------ 2. REFERENCE
    echo
    echo "== reference: provided sonames are still named by the payload"
    for s in $provided; do
      stem=$(stemOf "$s")
      if [ -n "''${SCANNED[$s]-}" ]; then
        printf '  ok      %-26s named by %s\n' "$s" "''${SEENIN[$s]%% *}"
      elif [ -n "''${SCANNED[$stem]-}" ]; then
        printf '  ok      %-26s named as %s (ABI version appended at runtime)\n' "$s" "$stem"
      else
        printf '  FAIL    %-26s no longer named by any shipped ELF\n' "$s"
        rc=1
      fi
    done
    for s in $dependsOnly; do
      printf '  n/a     %-26s Depends-only, not expected in the scan\n' "$s"
    done

    # -------------------------------------------------------- 3. NOVELTY
    echo
    echo "== novelty: every soname string is classified"
    declare -A KNOWN=() KNOWNSTEM=()
    for s in $provided $dependsOnly $unprovided "''${!NEEDED[@]}" "''${!BUNDLED[@]}"; do
      KNOWN["$s"]=1
      KNOWNSTEM["$(stemOf "$s")"]=1
    done

    unknown=()
    for s in "''${!SCANNED[@]}"; do
      if [ -n "''${KNOWN[$s]-}" ]; then continue; fi
      # An unversioned string is covered by a known soname with the same stem:
      # upstream probes "libfoo.so" alongside "libfoo.so.N". A *versioned*
      # string must be listed explicitly, or a bump that starts probing
      # libfoo.so.9 would sail past on the strength of libfoo.so.4.
      case "$s" in
        *.so)
          if [ -n "''${KNOWNSTEM[$s]-}" ]; then continue; fi
          ;;
      esac
      unknown+=("$s")
    done

    if [ ''${#unknown[@]} -eq 0 ]; then
      echo "  ok      all ''${#SCANNED[@]} classified (DT_NEEDED, bundled, provided or waived)"
    else
      for s in $(printf '%s\n' "''${unknown[@]}" | sort); do
        printf '  FAIL    %-26s unclassified, named by %s\n' "$s" "''${SEENIN[$s]%% *}"
        rc=1
      done
    fi

    if [ $rc -ne 0 ]; then
      cat <<'MSG'

    One or more assertions failed. Note what this does NOT look like at
    runtime: dlopen failure is not a link error, so the package still builds
    and still starts — the affected feature just switches itself off. For
    libsecret-1.so.0 that means the session token drops from a keyring-derived
    v11 key to v10 obfuscation.

      unresolvable     the library left the closure, or the RUNPATH no longer
                       reaches it. Fix runtimeLibs in pkgs/claude-desktop.nix.

      no longer named  upstream stopped using it. Drop it from dlopenSonames
                       (and from runtimeLibs if nothing else needs it), or move
                       it to dlopenSonamesDependsOnly if the .deb still lists
                       it in Depends.

      unclassified     upstream started naming something new. Decide which it
                       is: add it to runtimeLibs + dlopenSonames if this
                       package should provide it, or to
                       dlopenSonamesUnprovided with the reason if it should
                       not.
    MSG
      exit 1
    fi

    touch $out
  ''
