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
    # "<object>\t<spelling>\t<soname it stands for>" per line: which object
    # composes the ABI version at runtime, and for which spelling.
    runtimeVersioned = lib.concatStringsSep "\n" (
      lib.concatLists (
        lib.mapAttrsToList (
          obj: m: lib.mapAttrsToList (a: t: "${obj}\t${a}\t${t}") m
        ) claude-desktop.dlopenSonamesRuntimeVersioned
      )
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
    # RTV["<object>\t<spelling>"] — this object composes the version itself,
    # so what it opens is the mapped soname and the literal never appears.
    # Object-scoped for the same reason waivers are: another ELF naming the
    # same string is asking for that exact file.
    # SUBST is the payload-wide view of the same table, used only where the
    # question is payload-wide ("is this soname still named anywhere").
    declare -A ALIAS=() SUBST=() RTV=()
    rtvPairs=()
    while IFS=$'\t' read -r obj a t; do
      if [ -n "$obj" ]; then
        RTV["$obj"$'\t'"$a"]=$t
        rtvPairs+=("$obj"$'\t'"$a")
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
      local target
      target=$(meaningOf "$2")
      if [ -z "''${WAIVED[$1$'\t'$target]-}" ]; then return 1; fi
      if [ "$target" = "$2" ]; then return 0; fi
      # An alias inherits a waiver only where this object shows the same
      # evidence the fallback demands: the waived soname carried as a mapped
      # literal here, not merely linked. Otherwise "we do not provide
      # libcurl.so.4" would silently excuse a dlopen("libcurl.so") in an
      # object that links libcurl and would have resolved it.
      if triesItself "$1" "$target"; then return 0; fi
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
    declare -A LITERAL=() UNREADABLE=() UNREADABLE_REPORTED=()
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
      # patchelf reads the dynamic metadata through the section headers, so an
      # object it cannot parse — a section-header-less or self-decompressing
      # ELF — yields no RUNPATH and no DT_NEEDED. Left implicit that reads as
      # "every soname it names is unresolvable", which is the right verdict
      # reached by the wrong route and reported unintelligibly. Record it and
      # say so once instead.
      if ! RPATH["$rel"]=$(patchelf --print-rpath "$f" 2>/dev/null); then
        UNREADABLE["$rel"]=1
        RPATH["$rel"]=""
      fi
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

      # Second pass, by byte offset: which of those sonames could a dlopen call
      # in *this* object actually pass. Two conditions, and both matter.
      #
      #   inside a PT_LOAD segment — a string a call site can reach has to be
      #     mapped at runtime. dontStrip = true keeps .comment, .shstrtab,
      #     .gnu_debuglink and friends in the file, and a soname sitting in one
      #     of those is a note about the binary, not something it can open.
      #   outside .dynstr — that section *is* loaded, but it is where the
      #     linker records DT_NEEDED and DT_SONAME. A name found only there is
      #     linkage metadata, not a call.
      #
      # Deciding this by offset rather than by subtracting DT_NEEDED names
      # keeps the object that both links a soname and carries it as a literal
      # fallback: that one really does try both spellings.
      loadRanges=""
      while read -r segOff segVaddr segSize; do
        if [ -n "$segOff" ]; then
          loadRanges="$loadRanges $((segOff)):$((segOff + segSize))"
        fi
      done < <(readelf -lW "$f" 2>/dev/null | awk '$1 == "LOAD" { print $2, $3, $5 }' || true)

      # The dynamic string table, located through PT_DYNAMIC rather than the
      # section headers. Section headers are optional in ELF — a stripped
      # section-header table would leave this unfound, and "unfound" used to
      # mean "no linkage table to exclude", i.e. every DT_NEEDED name counted
      # as a literal. DT_STRTAB/DT_STRSZ are what the loader itself reads, so
      # they are there whenever there is anything to exclude.
      dynOff=-1
      dynEnd=-1
      dynUnknown=0
      dynInfo=$(readelf -dW "$f" 2>/dev/null || true)
      case "$dynInfo" in
        *"(STRTAB)"*)
          strtabVaddr=$(printf '%s\n' "$dynInfo" | awk '/\(STRTAB\)/ { print $3; exit }')
          strtabSize=$(printf '%s\n' "$dynInfo" | awk '/\(STRSZ\)/ { print $3; exit }')
          if [ -n "$strtabVaddr" ] && [ -n "$strtabSize" ]; then
            while read -r segOff segVaddr segSize; do
              if [ -n "$segOff" ] \
                && [ $((strtabVaddr)) -ge $((segVaddr)) ] \
                && [ $((strtabVaddr)) -lt $((segVaddr + segSize)) ]; then
                dynOff=$((strtabVaddr - segVaddr + segOff))
                dynEnd=$((dynOff + strtabSize))
                break
              fi
            done < <(readelf -lW "$f" 2>/dev/null | awk '$1 == "LOAD" { print $2, $3, $5 }' || true)
          fi
          # A dynamic object whose string table could not be placed: refuse to
          # guess. No literal evidence is recorded for it, so the fallback that
          # evidence would unlock simply does not apply — closed, not open.
          if [ "$dynOff" -lt 0 ]; then
            dynUnknown=1
            echo "note: cannot locate the dynamic string table of $rel; no literal evidence will be credited to it"
          fi
          ;;
      esac

      while IFS= read -r s; do
        if [ "$dynUnknown" -eq 1 ]; then break; fi
        LITERAL["$rel"]="''${LITERAL[$rel]-}$s"$'\n' 
      done < <(
        strings -a -t d "$f" \
          | awk -v off="$dynOff" -v end="$dynEnd" -v ranges="$loadRanges" '
              BEGIN {
                n = split(ranges, r, " ")
                for (i = 1; i <= n; i++) { split(r[i], p, ":"); lo[i] = p[1] + 0; hi[i] = p[2] + 0 }
              }
              {
                o = $1 + 0
                if (off >= 0 && o >= off && o < end) next
                mapped = 0
                for (i = 1; i <= n; i++) if (o >= lo[i] && o < hi[i]) { mapped = 1; break }
                if (!mapped) next
                $1 = ""; print
              }' \
          | grep -oE "$sonameRe" | sort -u
      )
      while IFS= read -r n; do
        NEEDED["$n"]=1
        NEEDED_BY["$rel"]="''${NEEDED_BY[$rel]-}$n "
      done < <(patchelf --print-needed "$f" 2>/dev/null || true)
    done

    echo "scanned ''${#elfs[@]} ELF objects, ''${#SCANNED[@]} distinct soname strings"

    # Does this object look like it tries this exact spelling itself?
    #
    # Every assertion that asks "does this object ask for this soname" goes
    # through here, and the distinction it draws is the one the whole guard
    # turns on: an object's DT_NEEDED entries and its own DT_SONAME live in
    # .dynstr, which is part of the file and therefore part of the string scan.
    # A soname found only there is linkage metadata, not a dlopen attempt — and dlopen matches on the name
    # asked for, so a call to the generic spelling still returns NULL when
    # only the versioned file is on the RUNPATH, however the object is linked.
    #
    # Decided by where the occurrences are, not by subtracting DT_NEEDED names:
    # an ELF may perfectly well link libfoo.so.4 *and* carry it as a literal
    # fallback after trying libfoo.so, and that object does try both.
    triesItself() { # $1 = object, $2 = exact soname
      local r
      while IFS= read -r r; do
        if [ "$r" = "$2" ]; then return 0; fi
      done <<< "''${LITERAL[$1]-}"
      return 1
    }

    # Does any shipped object carry this soname as a live literal? The
    # payload-wide form of triesItself, for the assertions whose question is
    # payload-wide ("is this still probed anywhere") rather than per object.
    someObjectTries() { # $1 = soname
      local r
      while IFS= read -r r; do
        if [ -n "$r" ] && triesItself "$r" "$1"; then return 0; fi
      done <<< "''${SEENIN[$1]-}"
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
        # An empty element is only the most obvious way to name the working
        # directory. "." or "lib" or "../x" are resolved by the loader relative
        # to the process cwd just the same, and a later absolute entry that
        # happens to satisfy every soname does not make that safe: whatever
        # sits in the cwd is searched first. Every component, after $ORIGIN
        # expansion, has to be absolute.
        IFS=: read -ra rpDirs <<< "''${RPATHX[$rel]}"
        for d in "''${rpDirs[@]}"; do
          if [ -n "$d" ]; then
            case "$d" in
              /*) ;;
              *)
                echo "FAIL: relative RUNPATH element '$d' in $rel (resolved against the cwd at load time)"
                rc=1
                ;;
            esac
          fi
        done
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
        # An object patchelf cannot parse has no readable RUNPATH, DT_NEEDED or
        # DT_SONAME, so nothing it names can be shown to resolve and the two
        # exemptions that come from that metadata cannot be applied either.
        # Fail closed, and say which of the two problems this is — but only for
        # sonames it actually names, since an object that names none (the
        # self-decompressing cowork helper, today) needs none of it.
        if [ -n "''${UNREADABLE[$rel]-}" ]; then
          if isWaivedFor "$rel" "$s"; then
            skipped=$((skipped + 1))
            continue
          fi
          pairs=$((pairs + 1))
          printf '  FAIL    %-26s named by %s, whose dynamic metadata patchelf cannot read\n' "$s" "$rel"
          if [ -z "''${UNREADABLE_REPORTED[$rel]-}" ]; then
            UNREADABLE_REPORTED["$rel"]=1
            echo "          (a stripped section-header table or a self-decompressing binary:"
            echo "           its RUNPATH is unknown, so this cannot be shown to resolve)"
          fi
          rc=1
          continue
        fi
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
        if [ -n "''${RTV[$rel$'\t'$s]-}" ]; then
          # The declaration says this object composes the version at runtime,
          # which is a statement about a live call site. Take it only where the
          # spelling is a mapped literal here: a prefix surviving in .dynstr or
          # in debug metadata is not a probe, and substituting the versioned
          # soname for it would check something nothing asks for.
          if ! triesItself "$rel" "$s"; then
            printf '  FAIL    %-26s declared in %s as composing its version, but no longer a live literal there\n' \
              "$s" "$rel"
            rc=1
          elif ! resolveIn "$rel" "''${RTV[$rel$'\t'$s]}" >/dev/null; then
            printf '  FAIL    %-26s named by %s; its runtime soname %s is unresolvable from that RUNPATH\n' \
              "$s" "$rel" "''${RTV[$rel$'\t'$s]}"
            rc=1
          fi
        elif ! resolveIn "$rel" "$s" >/dev/null; then
          # The mapped soname is a fallback only when *this* object looks like
          # it tries that spelling too — a second spelling is one the binary
          # attempts alongside the exact name, and neither "somewhere in the
          # payload names it" nor "this object links it" is evidence that this
          # caller attempts it. An object whose only call is
          # dlopen("libnotify.so") is broken when just libnotify.so.4 exists,
          # however it is linked, and must be reported as such.
          if triesItself "$rel" "$(meaningOf "$s")" \
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
      # A live literal somewhere, not merely a string somewhere: a soname left
      # behind in DT_NEEDED, in debug metadata or in a section that is never
      # mapped is not a probe, and an entry kept alive by one is an assertion
      # that passes forever while testing nothing.
      if someObjectTries "$s"; then
        printf '  ok      %-26s named by %s\n' "$s" "''${SEENIN[$s]%%$'\n'*}"
        continue
      fi
      # Only a runtime-versioned spelling may stand in for it, on the same
      # evidence.
      via=""
      for a in "''${!SUBST[@]}"; do
        if [ "''${SUBST[$a]}" = "$s" ] && someObjectTries "$a"; then via=$a; break; fi
      done
      if [ -n "$via" ]; then
        printf '  ok      %-26s named as %s (version appended at runtime)\n' "$s" "$via"
      else
        printf '  FAIL    %-26s no longer a live literal in any shipped ELF\n' "$s"
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
    namedBy() { # $1 = object, $2 = soname; the exact string as a mapped
                # literal, or a spelling whose version the binary composes at
                # runtime. Linkage metadata does not keep a waiver alive: a
                # soname this object merely links is one the build resolved,
                # which is the opposite of a probe we declined to provide.
      if triesItself "$1" "$2"; then return 0; fi
      local a
      for a in "''${!SUBST[@]}"; do
        if [ "''${SUBST[$a]}" = "$2" ] && triesItself "$1" "$a"; then return 0; fi
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
    echo "== reference: declared spellings are still named"
    for pair in "''${rtvPairs[@]}"; do
      obj=''${pair%%$'\t'*}
      a=''${pair#*$'\t'}
      if triesItself "$obj" "$a"; then
        printf '  ok      %-26s stands for %s in %s (version appended at runtime)\n' \
          "$a" "''${RTV[$pair]}" "$obj"
      else
        printf '  FAIL    %-26s stale spelling: %s no longer names it as a live literal\n' "$a" "$obj"
        rc=1
      fi
    done
    for a in $(printf '%s\n' "''${!ALIAS[@]}" | sort); do
      if [ -n "''${SUBST[$a]-}" ]; then continue; fi
      if someObjectTries "$a"; then
        printf '  ok      %-26s stands for %s (second spelling)\n' "$a" "''${ALIAS[$a]}"
      else
        printf '  FAIL    %-26s stale spelling: no longer a live literal in any shipped ELF\n' "$a"
        rc=1
      fi
    done

    # -------------------------------------------------------- 3. NOVELTY
    echo
    echo "== novelty: every soname string is classified"
    # Payload-wide reasons only. A DT_NEEDED soname anywhere is one the build
    # resolved and the closure carries, so another object naming it needs no
    # decision — reachability already made it prove it can reach it. A waiver
    # is the opposite: it says this package deliberately does *not* provide the
    # library, which is a statement about the object that probes for it, so it
    # is checked per (object, soname) below.
    declare -A KNOWN=()
    for s in $provided $dependsOnly "''${!NEEDED[@]}" "''${!BUNDLED[@]}" "''${!ALIAS[@]}"; do
      KNOWN["$s"]=1
    done
    # An object's own DT_SONAME is a name this payload declares for itself, and
    # it appears in that object's strings whatever the file is called. BUNDLED
    # only sees filenames matching lib*.so*, so a shared object shipped as
    # plugin.node with DT_SONAME=libplugin.so.1 would otherwise be reported as
    # an unclassified soname. Reachability still makes any *other* object that
    # names it prove it can load it — a declared soname is not a file.
    for rel in "''${!SONAME[@]}"; do
      if [ -n "''${SONAME[$rel]}" ]; then KNOWN["''${SONAME[$rel]}"]=1; fi
    done

    unknown=()
    for s in "''${!SCANNED[@]}"; do
      if [ -n "''${KNOWN[$s]-}" ]; then continue; fi
      while IFS= read -r rel; do
        if [ -z "$rel" ]; then continue; fi
        if [ -n "''${WAIVED[$rel$'\t'$s]-}" ]; then continue; fi
        unknown+=("$rel"$'\t'"$s")
      done <<< "''${SEENIN[$s]-}"
    done

    if [ ''${#unknown[@]} -eq 0 ]; then
      echo "  ok      all ''${#SCANNED[@]} classified (DT_NEEDED, bundled or declared as a shipped object's soname, provided, a declared spelling, or waived for the object naming it)"
    else
      # read, not a $(...) loop: the pairs are tab-separated and word
      # splitting would tear them in half.
      while IFS= read -r pair; do
        printf '  FAIL    %-26s unclassified for %s\n' "''${pair#*$'\t'}" "''${pair%%$'\t'*}"
        rc=1
      done < <(printf '%s\n' "''${unknown[@]}" | sort)
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

      no longer a live upstream stopped probing for it — any occurrence left is
      literal          linkage metadata or debug information, not a call site.
                       Drop it from dlopenSonames
                       (and from runtimeLibs if nothing else needs it), or move
                       it to dlopenSonamesDependsOnly if the .deb still lists
                       it in Depends.

      stale waiver     upstream stopped naming a soname we had waived. Delete
                       the entry from dlopenSonamesUnprovided — leaving it
                       would silently pre-approve the soname if a later
                       release brings it back for something that matters.

      unclassified     that object started naming something nothing accounts
                       for. Decide which it is: add it to runtimeLibs +
                       dlopenSonames if this package should provide it, or to
                       that object's list in dlopenSonamesUnprovided with the
                       reason if it should not. A waiver written for a
                       different object does not carry over — the second one
                       naming it is a second decision.
    MSG
      exit 1
    fi

    touch $out
  ''
