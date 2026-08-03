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
# Four assertions, because resolving a hand-written list only covers the
# first one:
#
#   1. RESOLVE      — every soname this package claims to provide resolves
#                     from the main executable's RUNPATH.
#   1b. REACHABILITY— *every* (object, soname) pair the scan produced
#                     resolves from that object's own RUNPATH, not merely the
#                     pairs on the provided list. Being DT_NEEDED of some
#                     other object proves nothing about this one.
#   2. REFERENCE    — every soname the lists mention is still named by the
#                     shipped payload — waivers included. Catches entries
#                     upstream stopped using, which would otherwise keep
#                     passing (1) forever, and stale waivers, which would
#                     silently pre-approve a soname that comes back.
#   3. NOVELTY      — every soname-shaped string in the payload is accounted
#                     for: DT_NEEDED (autoPatchelfHook's job), bundled with
#                     the app, provided by us, or waived by name with a
#                     reason. Catches an upstream bump that starts
#                     dlopen()ing something new, which the others cannot see.
#
# (1b), (2) and (3) are what tie the lists in passthru to the binary. Keeping
# the lists next to runtimeLibs is a convention and conventions drift; the
# binary is rescanned on every run, and the lists are only the expected
# answer.
#
# Deliberately static: it resolves sonames against RUNPATH entries rather than
# launching the app. An Xvfb launch check would be strictly worse here — it
# needs a display, a D-Bus session and a live Secret Service provider to tell
# v10 from v11, none of which exist in the build sandbox, and it would be slow
# and flaky in exchange for testing the same property this resolves directly.
#
# Two pieces of bookkeeping make the assertions per-object rather than
# per-soname, which is where the earlier revisions of this file were wrong:
#
#   * DT_NEEDED is recorded per object. Object B linking a library says
#     nothing about whether object A, which merely names it, can reach it.
#   * waivers are recorded per object. "crashpad probes for libcurl and we
#     ship no crash server" is a claim about crashpad; the same soname named
#     by the main executable is a new fact and fails.
#
# There is no stem matching. An unversioned spelling counts as a reference to
# a versioned soname only when passthru.dlopenSonamesAliases declares it, one
# alias to one target — a blanket rule would let a dropped probe
# (libnotify.so.1 going away while libnotify.so stays) look alive, which is
# exactly what the reference assertion exists to catch.
#
# Limits of the scan, stated rather than papered over: it is a string scan, so
# a soname assembled at runtime is only visible through its unversioned
# spelling (libva is the live example, hence the alias), a string can be
# present without any code path reaching the dlopen, and only ELF objects are
# scanned — nothing inside app.asar is.
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
    # "<object>\t<soname>" per line. Tab-separated, not space: an object path
    # is a file path and may contain whitespace.
    unprovided = lib.concatStringsSep "\n" (
      lib.concatLists (
        lib.mapAttrsToList (
          obj: sonames: map (s: "${obj}\t${s}") sonames
        ) claude-desktop.dlopenSonamesUnprovided
      )
    );
    # "<spelling>\t<soname it stands for>" per line, in two tables: only the
    # runtime-versioned one may stand in for an exact reference.
    runtimeVersioned = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (a: t: "${a}\t${t}") claude-desktop.dlopenSonamesRuntimeVersioned
    );
    secondSpellings = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (a: t: "${a}\t${t}") claude-desktop.dlopenSonamesSecondSpellings
    );
  }
  ''
    set -euo pipefail

    appdir=$app/lib/claude-desktop
    main=$appdir/claude-desktop
    test -f "$main" || { echo "FAIL: main executable missing at $main"; exit 1; }

    # Anything shaped like a soname: libfoo.so, libfoo.so.1, libfoo-2.0.so.0.
    sonameRe='\blib[A-Za-z0-9_+.-]*\.so(\.[0-9]+)*\b'

    rc=0

    # ALIAS[unversioned] = the soname it stands for. Declared, never inferred.
    # SUBST is the subset allowed to stand in for an exact reference: only
    # sonames whose version the binary appends at runtime, where the exact
    # string genuinely does not exist. A second spelling that sits beside the
    # exact string proves nothing about it — if the exact string disappears,
    # that is the news the reference assertion exists to report.
    declare -A ALIAS=() SUBST=()
    while IFS=$'\t' read -r a t; do
      if [ -n "$a" ]; then
        ALIAS["$a"]=$t
        SUBST["$a"]=$t
      fi
    done <<< "$runtimeVersioned"
    while IFS=$'\t' read -r a t; do
      if [ -n "$a" ]; then ALIAS["$a"]=$t; fi
    done <<< "$secondSpellings"

    # What a scanned string means: itself, or the soname it is an alias for.
    meaningOf() { echo "''${ALIAS[$1]-$1}"; }

    # WAIVED["<object> <soname>"] — deliberately not provided, for that object
    # only. "We decided not to ship this" is the one answer that also exempts
    # a soname from having to resolve, so it must not be granted payload-wide
    # on the strength of one binary.
    declare -A WAIVED=()
    waiverPairs=()
    while IFS=$'\t' read -r obj s; do
      if [ -n "$obj" ]; then
        WAIVED["$obj"$'\t'"$s"]=1
        waiverPairs+=("$obj"$'\t'"$s")
      fi
    done <<< "$unprovided"

    isWaivedFor() { # $1 = object, $2 = scanned string
      if [ -n "''${WAIVED[$1$'\t'$(meaningOf "$2")]-}" ]; then return 0; fi
      return 1
    }

    # ------------------------------------------------------------ inventory
    #
    # NEEDED is kept twice on purpose: NEEDED_BY[object] answers "may this
    # object rely on the loader for this soname", which is a per-object
    # question, while NEEDED answers "does this string have a reason to exist
    # anywhere in the payload", which is a global one. Collapsing the first
    # into the second would let object A dlopen a soname that only object B
    # links, with nothing checking that A can actually reach it.
    declare -A RPATH=() RPATHX=() SCANNED=() SEENIN=() NEEDED=() NEEDED_BY=() SONAME=() BUNDLED=()
    elfs=()

    # -type f here (unlike the bundled inventory below): each real object is
    # to be scanned once, and a soname symlink points at a file already in
    # this list.
    while IFS= read -r f; do
      if [ "$(head -c4 "$f" 2>/dev/null | tr -d '\0' || true)" = $'\x7fELF' ]; then
        elfs+=("$f")
      fi
    done < <(find "$app" -type f | sort)

    # -xtype f, not -type f: a bundled library is routinely shipped as
    # libfoo.so.1 -> libfoo.so.1.2.3, and it is the *symlink* that carries the
    # soname. Recording only regular files would leave that soname
    # unclassified even though it resolves through the same directory. -xtype
    # follows the link and tests the target, so a dangling one still does not
    # count as bundled.
    while IFS= read -r f; do
      BUNDLED["$f"]=1
    done < <(find "$app" -xtype f -name 'lib*.so*' -printf '%f\n' | grep -xE "$sonameRe" || true)

    for f in "''${elfs[@]}"; do
      rel=''${f#$app/}
      RPATH["$rel"]=$(patchelf --print-rpath "$f" 2>/dev/null || true)
      # $ORIGIN is the directory of the object being loaded, so it has to be
      # expanded per object, exactly as the loader does. [$] keeps the token
      # out of this file as a literal that Nix would try to interpolate.
      RPATHX["$rel"]=$(printf '%s' "''${RPATH[$rel]}" \
        | sed -e "s|[$]{ORIGIN}|$(dirname "$f")|g" -e "s|[$]ORIGIN|$(dirname "$f")|g")
      SONAME["$rel"]=$(patchelf --print-soname "$f" 2>/dev/null || true)
      while IFS= read -r s; do
        SCANNED["$s"]=1
        # Newline-delimited: object paths are file paths and a space-delimited
        # string would split "resources/My Helper/helper" into two objects
        # that do not exist, whose empty RUNPATH then fails every lookup.
        SEENIN["$s"]="''${SEENIN[$s]-}$rel"$'\n' 
      done < <(strings -a "$f" | grep -oE "$sonameRe" | sort -u)
      while IFS= read -r n; do
        NEEDED["$n"]=1
        NEEDED_BY["$rel"]="''${NEEDED_BY[$rel]-}$n "
      done < <(patchelf --print-needed "$f" 2>/dev/null || true)
    done

    echo "scanned ''${#elfs[@]} ELF objects, ''${#SCANNED[@]} distinct soname strings"

    # Does this object name this exact string?
    namesIt() { # $1 = object, $2 = soname
      local r
      while IFS= read -r r; do
        if [ "$r" = "$1" ]; then return 0; fi
      done <<< "''${SEENIN[$2]-}"
      return 1
    }

    # Echoes the RUNPATH directory a soname resolves from, or returns 1.
    # Reads the $ORIGIN-expanded form: an object reaching a bundled library
    # through an origin-relative entry resolves at runtime and must not be
    # reported as unreachable here.
    resolveIn() { # $1 = path relative to $app, $2 = soname
      local dirs d
      IFS=: read -ra dirs <<< "''${RPATHX[$1]-}"
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
        # $ORIGIN is expanded above. Any other loader token ($LIB, $PLATFORM)
        # would have to be guessed at, and a guess here is worse than a stop:
        # say so instead of silently resolving against a made-up directory.
        case "''${RPATHX[$rel]}" in
          *'$'*)
            echo "FAIL: unsupported loader token in RUNPATH of $rel: ''${RPATH[$rel]}"
            echo "      only \$ORIGIN is modelled; teach resolveIn the rest before trusting this"
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

    # ---------------------------------------------------- 1b. REACHABILITY
    #
    # Every (object, soname) pair the scan produced, not just the pairs whose
    # soname happens to be on the provided list. A soname that is DT_NEEDED of
    # *some other* object is not thereby reachable from this one: the RUNPATH
    # autoPatchelfHook wrote for object B says nothing about object A. Three
    # exemptions, each for a reason that holds per object:
    #
    #   own soname   an ELF's own DT_SONAME appears in its own strings.
    #   DT_NEEDED    of *this* object — the build would already have failed if
    #                it were unsatisfiable, and libc and friends resolve via
    #                the patched interpreter's own path rather than a RUNPATH.
    #   waived       *this object's* waiver list says we decided not to
    #                provide it, which is the one answer that also excuses it
    #                from resolving. A waiver granted to another object does
    #                not carry over.
    echo
    echo "== reachability: each named soname resolves from the RUNPATH of the object naming it"
    pairs=0
    skipped=0
    for s in "''${!SCANNED[@]}"; do
      while IFS= read -r rel; do
        if [ -z "$rel" ]; then continue; fi
        if [ "$s" = "''${SONAME[$rel]-}" ]; then
          skipped=$((skipped + 1))
          continue
        fi
        case " ''${NEEDED_BY[$rel]-} " in
          *" $s "*)
            skipped=$((skipped + 1))
            continue
            ;;
        esac
        if isWaivedFor "$rel" "$s"; then
          skipped=$((skipped + 1))
          continue
        fi
        pairs=$((pairs + 1))
        # What the loader is actually asked for. For a runtime-versioned
        # spelling the binary never opens the string it carries — it appends
        # the ABI version first — so resolving the literal would fail the
        # package the day a dependency stops shipping the unversioned
        # development symlink, while the library it really opens is still
        # there. For everything else the literal is what gets opened, with the
        # mapped soname accepted as a fallback for second spellings, which the
        # binary tries alongside the exact name.
        if [ -n "''${SUBST[$s]-}" ]; then
          if ! resolveIn "$rel" "''${SUBST[$s]}" >/dev/null; then
            printf '  FAIL    %-26s named by %s; its runtime soname %s is unresolvable from that RUNPATH\n' \
              "$s" "$rel" "''${SUBST[$s]}"
            rc=1
          fi
        elif ! resolveIn "$rel" "$s" >/dev/null; then
          # The mapped soname is a fallback only when *this* object also names
          # it — a second spelling is one the binary tries alongside the exact
          # name, and "somewhere in the payload names the exact name" is not
          # evidence that this caller does. An object that only ever calls
          # dlopen("libnotify.so") is broken when just libnotify.so.4 exists,
          # and must be reported as such.
          if namesIt "$rel" "$(meaningOf "$s")" \
            && resolveIn "$rel" "$(meaningOf "$s")" >/dev/null; then
            :
          else
            printf '  FAIL    %-26s named by %s, unresolvable from its RUNPATH\n' "$s" "$rel"
            rc=1
          fi
        fi
      done <<< "''${SEENIN[$s]-}"
    done
    echo "  ok      $pairs (object, soname) pairs resolve; $skipped exempt (own soname, that object's DT_NEEDED, or waived for that object)"

    # ------------------------------------------------------ 2. REFERENCE
    echo
    echo "== reference: provided sonames are still named by the payload"
    for s in $provided; do
      if [ -n "''${SCANNED[$s]-}" ]; then
        printf '  ok      %-26s named by %s\n' "$s" "''${SEENIN[$s]%%$'\n'*}"
        continue
      fi
      # Only a runtime-versioned spelling may stand in for it.
      via=""
      for a in "''${!SUBST[@]}"; do
        if [ "''${SUBST[$a]}" = "$s" ] && [ -n "''${SCANNED[$a]-}" ]; then via=$a; break; fi
      done
      if [ -n "$via" ]; then
        printf '  ok      %-26s named as %s (version appended at runtime)\n' "$s" "$via"
      else
        printf '  FAIL    %-26s no longer named by any shipped ELF\n' "$s"
        rc=1
      fi
    done
    for s in $dependsOnly; do
      printf '  n/a     %-26s Depends-only, not expected in the scan\n' "$s"
    done

    # A waiver is a claim about one object — "this binary names the soname and
    # we choose not to provide it". Once that object stops naming it the claim
    # is stale, and a stale waiver is worse than a missing one: it silently
    # pre-approves the soname if a later release reintroduces it for something
    # that does matter. Only dependsOnly is exempt from having to be named.
    echo
    echo "== reference: waivers are still named by the object they were written for"
    namedBy() { # $1 = object, $2 = soname; the exact string, or a spelling
                # whose version the binary composes at runtime
      if namesIt "$1" "$2"; then return 0; fi
      local a
      for a in "''${!SUBST[@]}"; do
        if [ "''${SUBST[$a]}" = "$2" ] && namesIt "$1" "$a"; then return 0; fi
      done
      return 1
    }
    for pair in "''${waiverPairs[@]}"; do
      obj=''${pair%%$'\t'*}
      s=''${pair#*$'\t'}
      if namedBy "$obj" "$s"; then
        printf '  ok      %-26s still named by %s\n' "$s" "$obj"
      else
        printf '  FAIL    %-26s stale waiver: %s no longer names it\n' "$s" "$obj"
        rc=1
      fi
    done

    # The spelling tables are assertions too: an entry nothing names is a rule
    # about a string that no longer exists.
    echo
    echo "== reference: declared spellings are still named by the payload"
    for a in $(printf '%s\n' "''${!ALIAS[@]}" | sort); do
      if [ -n "''${SCANNED[$a]-}" ]; then
        if [ -n "''${SUBST[$a]-}" ]; then
          printf '  ok      %-26s stands for %s (version appended at runtime)\n' "$a" "''${ALIAS[$a]}"
        else
          printf '  ok      %-26s stands for %s (second spelling)\n' "$a" "''${ALIAS[$a]}"
        fi
      else
        printf '  FAIL    %-26s stale spelling: no longer named by any shipped ELF\n' "$a"
        rc=1
      fi
    done

    # -------------------------------------------------------- 3. NOVELTY
    echo
    echo "== novelty: every soname string is classified"
    declare -A KNOWN=()
    for s in $provided $dependsOnly "''${!NEEDED[@]}" "''${!BUNDLED[@]}" "''${!ALIAS[@]}"; do
      KNOWN["$s"]=1
    done
    for pair in "''${waiverPairs[@]}"; do
      KNOWN["''${pair#*$'\t'}"]=1
    done

    unknown=()
    for s in "''${!SCANNED[@]}"; do
      if [ -n "''${KNOWN[$s]-}" ]; then continue; fi
      unknown+=("$s")
    done

    if [ ''${#unknown[@]} -eq 0 ]; then
      echo "  ok      all ''${#SCANNED[@]} classified (DT_NEEDED, bundled, provided, waived, or a declared spelling)"
    else
      for s in $(printf '%s\n' "''${unknown[@]}" | sort); do
        printf '  FAIL    %-26s unclassified, named by %s\n' "$s" "''${SEENIN[$s]%%$'\n'*}"
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

      unresolvable     the library left the closure, or that object's RUNPATH
                       no longer reaches it. Fix runtimeLibs in
                       pkgs/claude-desktop.nix. Note the object named in the
                       message: appendRunpaths covers every ELF, so a single
                       object failing usually means the library is gone rather
                       than misplaced.

      no longer named  upstream stopped using it. Drop it from dlopenSonames
                       (and from runtimeLibs if nothing else needs it), or move
                       it to dlopenSonamesDependsOnly if the .deb still lists
                       it in Depends.

      stale waiver     upstream stopped naming a soname we had waived. Delete
                       the entry from dlopenSonamesUnprovided — leaving it
                       would silently pre-approve the soname if a later
                       release brings it back for something that matters.

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
