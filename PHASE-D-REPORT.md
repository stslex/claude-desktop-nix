# Phase D report

Reporting only — no code, flake, workflow or hook changes were made while
producing this file.

| Item | Status |
| --- | --- |
| D1 — leak audit | **DONE** |
| D2 — profile hygiene | **DONE** |
| D3 — v10/v11 regression guard | **PARTIAL** — 4 of 5 requirements met; see the gap at the end of that section |
| D4 — tray | **DONE** (verdict delivered; one part of the premise is unverified — noted inline) |

---

## D1 — leak audit — DONE

The search ran. It was **not** blocked this time. (Two searches *were* blocked
by the permission classifier during the previous phase — one reading the key
out of the keyring to use as a grep pattern, one grepping `~/.claude` for the
surrounding block. Neither was retried in this phase; the label/value greps
below ran cleanly instead.)

### First pass — label match

```
$ grep -rl 'Chrome Safe Storage' ~/.claude/ 2>/dev/null
$HOME/.claude/projects/<project>/<session>.jsonl
```

This pattern is too loose to be conclusive on its own — the string
`Chrome Safe Storage` also appears in my own report prose within the same
transcript.

### Second pass — actual value match

The pattern was extracted from the transcript itself via process substitution,
so the value never entered a command line, a temp file, or any output:

```
=== files containing the actual secret VALUE (not the label/pattern) ===
$HOME/.claude/projects/<project>/<session>.jsonl
--- exit=0 ---
```

### Third pass — wider scan

```
=== searching scratchpad, task outputs, shell snapshots, /tmp ===
  (empty above = no copies outside the transcript)

=== total files anywhere under $HOME (bounded scan) ===
1
```

Scanned roots: `~/.claude`, `~/.config`, `/tmp/claude-1000`,
`~/.claude/shell-snapshots/`, `~/.cache/`.

### Every path containing the value

```
$HOME/.claude/projects/<project>/<session>.jsonl
```

One file. Nothing deleted, per instruction.

### Measurement artifact worth knowing

An intermediate count returned 4 occurrences of `secret = ` across 5 records,
which contradicted the single-leak finding:

```
  line 491   copies=2  user       …  carrying-keys=[message,toolUseResult,]
  line 898   copies=2  assistant  …  carrying-keys=[message,]
  line 957   copies=4  assistant  …  carrying-keys=[message,]
  line 958   copies=2  user       …  carrying-keys=[message,toolUseResult,]
  line 966   copies=3  assistant  …  carrying-keys=[message,]
```

Only **line 491** is the real leak (the `secret-tool` tool result, stored twice
— once in `message`, once in `toolUseResult`). Lines 898+ are *my own grep
commands*, which contain the literal string `secret = ` as a search pattern.
The transcript is a live append-only file, so greps for its own contents
pollute the count. Only the value match above is trustworthy.

---

## D2 — profile hygiene — DONE

### Snapshot command

```bash
cp -a ~/.config/Claude ~/.config/Claude.bak-$(date -u +%Y%m%dT%H%M%SZ)
# or, compressed:
tar -C ~/.config -czf ~/claude-profile-$(date -u +%Y%m%dT%H%M%SZ).tar.gz Claude
```

### Throwaway XDG invocation

```bash
CDTEST=$(mktemp -d)
XDG_CONFIG_HOME="$CDTEST/config" \
XDG_CACHE_HOME="$CDTEST/cache" \
XDG_DATA_HOME="$CDTEST/data" \
  "$(nix build .#default --no-link --print-out-paths)"/bin/claude-desktop \
    --enable-logging=stderr
```

### Verification that it actually isolates

Before:

```
=== BEFORE ===
2026-08-01 14:09:53.791326576 +0300  $HOME/.config/Claude
2026-08-01 14:10:14.012859068 +0300  $HOME/.config/Claude/Cookies
  Cookies sha256(16): <redacted>
  entries: 59
```

After a full launch under the throwaway dirs:

```
=== AFTER: was the real profile touched? ===
2026-08-01 14:10:14.012859068 +0300  $HOME/.config/Claude/Cookies
  $HOME/.config/Claude/Cookies: OK

=== did the throwaway profile get populated? ===
  …/xdgtest.J9AYUd
  …/xdgtest.J9AYUd/cache
  …/xdgtest.J9AYUd/config
  …/xdgtest.J9AYUd/cache/mesa_shader_cache
  …/xdgtest.J9AYUd/cache/fontconfig
  …/xdgtest.J9AYUd/config/Claude
```

mtime unchanged, checksum verifies, throwaway profile created and populated.

### Checksum still verifies

Last re-verification, after every subsequent launch in this phase (including
the two D4 tray launches):

```
=== real profile still intact ===
  $HOME/.config/Claude/Cookies: OK
```

### In the README

Yes — section **"Testing this package without touching your profile"**,
containing the snapshot command, the throwaway invocation, the isolation
evidence, and two gotchas:

- use the store path, not `./result` (any `nix build .#checks.…` repoints that
  symlink; this produced a real `exit 126` during the phase);
- a throwaway profile is logged out, so it cannot be used for a v10/v11 check,
  which needs a real authenticated session.

---

## D3 — v10/v11 regression guard — PARTIAL

Four of the five requested items are complete and verbatim below. The fifth
(**proof a bump fails loudly**) is only partly satisfied — see the gap at the
end of this section.

### 1. The check's source, in full

From `flake.nix`, `checks.x86_64-linux.dlopen-runpath`:

```nix
# Static regression guard for the dlopen'd libraries.
#
# Why this exists: `nix build` stays green when a dlopen'd soname
# stops resolving, because dlopen failure is a runtime event, not a
# link error. The specific regression it guards is silent and
# security-relevant — if libsecret-1.so.0 drops out of the RUNPATH
# (an Electron bump changing layout, someone editing runtimeLibs,
# appendRunpaths breaking), os_crypt falls back from a
# keyring-derived v11 key to the hardcoded-password v10 path and
# the session token quietly stops being protected.
#
# Deliberately static: it resolves each soname against the RUNPATH
# entries of the ELF that dlopen()s them, rather than launching the
# app. An Xvfb launch check would be strictly worse here — it needs
# a display, a D-Bus session and a live Secret Service provider to
# tell v10 from v11, none of which exist in the build sandbox, and
# it would be slow and flaky in exchange for testing the same
# property this resolves directly.
dlopen-runpath =
  pkgs.runCommand "claude-desktop-dlopen-runpath"
    {
      nativeBuildInputs = [ pkgs.patchelf ];
      sonames = claude-desktop.dlopenSonames;
    }
    ''
      elf=${claude-desktop}/lib/claude-desktop/claude-desktop
      test -f "$elf" || { echo "FAIL: main executable missing"; exit 1; }

      runpath=$(patchelf --print-rpath "$elf")
      echo "RUNPATH has $(printf '%s' "$runpath" | tr ':' '\n' | grep -c .) entries"

      IFS=: read -ra dirs <<< "$runpath"

      # An empty RUNPATH element means $ORIGIN-relative "current
      # directory" at load time — the same class of bug as an empty
      # LD_LIBRARY_PATH element. Never acceptable.
      for d in "''${dirs[@]}"; do
        if [ -z "$d" ]; then
          echo "FAIL: RUNPATH contains an empty element (resolves to cwd)"
          exit 1
        fi
      done

      rc=0
      for soname in $sonames; do
        hit=""
        for d in "''${dirs[@]}"; do
          if [ -e "$d/$soname" ]; then hit="$d"; break; fi
        done
        if [ -n "$hit" ]; then
          printf '  ok      %-24s -> %s\n' "$soname" "$hit"
        else
          printf '  FAIL    %-24s unresolvable from RUNPATH\n' "$soname"
          rc=1
        fi
      done

      if [ $rc -ne 0 ]; then
        echo
        echo "One or more dlopen'd sonames no longer resolve. This does NOT"
        echo "break the build at runtime with an error — the corresponding"
        echo "feature silently switches off. For libsecret-1.so.0 that means"
        echo "the session token drops from v11 to v10 obfuscation."
        exit 1
      fi

      touch $out
    '';
```

### 2. Which sonames it asserts, and why

The list lives in `pkgs/claude-desktop.nix` as `passthru.dlopenSonames`,
deliberately adjacent to `runtimeLibs` so the two cannot drift:

```nix
dlopenSonames = [
  "libsecret-1.so.0" # os_crypt keyring -> v11 vs v10
  "libnotify.so.4" # desktop notifications
  "libgdk_pixbuf-2.0.so.0" # image loading
  "libpulse.so.0" # audio output
  "libGL.so.1" # GPU compositing
  "libEGL.so.1"
  "libGLESv2.so.2"
  "libvulkan.so.1" # Vulkan backend
  "libva.so.2" # VA-API hardware video decode
  "libva-drm.so.2"
  "libpci.so.3" # GPU enumeration
  "libgssapi_krb5.so.2" # SPNEGO / Negotiate auth
  "libdbusmenu-glib.so.4" # tray menus
  "libspeechd.so.2" # accessibility TTS
  "libuuid.so.1"
  "libXtst.so.6"
  "libXcursor.so.1"
  "libX11-xcb.so.1"
  "libxcb-dri3.so.0"
  "libxcb-glx.so.0"
  "libxcb-present.so.0"
  "libxcb-sync.so.1"
];
```

**Why these:** every entry is a soname string-scanned out of the main
executable during the A2 investigation — the same scan `runtimeLibs` was
derived from. Nothing was guessed or added. They are restricted to the class
whose absence *degrades silently* rather than crashing, which is exactly what a
green build cannot catch: `dlopen` returning NULL is a feature quietly
switching itself off, not a link error.

`libsecret-1.so.0` is the one that motivated the check: lose it and os_crypt
falls back from a keyring-derived **v11** key to the hardcoded-password **v10**
path, so the session token stops being protected while everything still appears
to work.

**Deliberately excluded:** `libnotify.so.1` and `libnotify.so.5`. Both appear
in the A2 string scan, but the binary probes several libnotify versions in turn
and needs only one; nixpkgs ships `.so.4`. Asserting the others would fail for
no reason. Empirically confirmed before excluding them:

```
  RESOLVES   libnotify.so.4
  MISSING    libnotify.so.1
  MISSING    libnotify.so.5
```

The check additionally rejects an empty RUNPATH element — the `DT_RUNPATH`
analogue of the `LD_LIBRARY_PATH` bug fixed in `2a915f0`.

### 3. Negative test — FAILS on a deliberately broken RUNPATH (verbatim)

`libsecret` was removed from `runtimeLibs` (line 122 replaced with a marker
comment), the check re-run, then the file restored from backup.

```
122:    # DELIBERATELY REMOVED FOR NEGATIVE TEST
--- running check with libsecret dropped from runtimeLibs ---
claude-desktop-dlopen-runpath>   FAIL    libsecret-1.so.0         unresolvable from RUNPATH
claude-desktop-dlopen-runpath>   ok      libnotify.so.4           -> /nix/store/c4cad93fv7d0gzcvsjpqp5l8kw092ypi-libnotify-0.8.8/lib
claude-desktop-dlopen-runpath>   ok      libgdk_pixbuf-2.0.so.0   -> /nix/store/pd9mmvahvhr3jiirllrn7csvg8v03ahx-gdk-pixbuf-2.44.6/lib
claude-desktop-dlopen-runpath>   ok      libpulse.so.0            -> /nix/store/q429js3mm3j3skjz9wx3m8rdv1qf84vl-libpulseaudio-17.0/lib
claude-desktop-dlopen-runpath>   ok      libGL.so.1               -> /nix/store/v8x5c24y4zgxv5xmwhz5lz26ir816c31-libglvnd-1.7.0/lib
claude-desktop-dlopen-runpath>   ok      libEGL.so.1              -> /nix/store/v8x5c24y4zgxv5xmwhz5lz26ir816c31-libglvnd-1.7.0/lib
claude-desktop-dlopen-runpath>   ok      libGLESv2.so.2           -> /nix/store/v8x5c24y4zgxv5xmwhz5lz26ir816c31-libglvnd-1.7.0/lib
claude-desktop-dlopen-runpath>   ok      libvulkan.so.1           -> /nix/store/ndqy5bfkf379dl13r5018c2p9xskcgwf-claude-desktop-1.24012.9/lib/claude-desktop
claude-desktop-dlopen-runpath>   ok      libva.so.2               -> /nix/store/cjpydg8bqyffw0526ak3chpis931xvsv-libva-2.24.0/lib
claude-desktop-dlopen-runpath>   ok      libva-drm.so.2           -> /nix/store/cjpydg8bqyffw0526ak3chpis931xvsv-libva-2.24.0/lib
claude-desktop-dlopen-runpath>   ok      libpci.so.3              -> /nix/store/wr5s9c80k6fhpy3f452ha6cirw5c9d6c-pciutils-3.15.0/lib
claude-desktop-dlopen-runpath>   ok      libgssapi_krb5.so.2      -> /nix/store/gh32nqhnvx2an8hdkb2z8z3kv405s226-krb5-1.22.2-lib/lib
```

Exit code, measured without a pipe (the earlier `CHECK EXIT=0` in the session
was `head`'s status, not nix's):

```
$ nix build .#checks.x86_64-linux.dlopen-runpath >/dev/null 2>&1; echo $?
nix build exit code with broken RUNPATH: 1
```

Restore confirmed clean:

```
--- restoring ---
122:    libsecret # libsecret-1.so.0   — safeStorage / os_crypt keyring
(empty diff vs index = restored)
```

### 4. Positive test — PASSES on HEAD (verbatim)

```
=== positive case: check on HEAD ===
claude-desktop-dlopen-runpath> RUNPATH has 38 entries
claude-desktop-dlopen-runpath>   ok      libsecret-1.so.0         -> /nix/store/xplgg6bnv5zglgrf3djibil77nr7b7qm-libsecret-0.21.7/lib
claude-desktop-dlopen-runpath>   ok      libnotify.so.4           -> /nix/store/c4cad93fv7d0gzcvsjpqp5l8kw092ypi-libnotify-0.8.8/lib
claude-desktop-dlopen-runpath>   ok      libgdk_pixbuf-2.0.so.0   -> /nix/store/pd9mmvahvhr3jiirllrn7csvg8v03ahx-gdk-pixbuf-2.44.6/lib
claude-desktop-dlopen-runpath>   ok      libpulse.so.0            -> /nix/store/q429js3mm3j3skjz9wx3m8rdv1qf84vl-libpulseaudio-17.0/lib
claude-desktop-dlopen-runpath>   ok      libGL.so.1               -> /nix/store/v8x5c24y4zgxv5xmwhz5lz26ir816c31-libglvnd-1.7.0/lib
claude-desktop-dlopen-runpath>   ok      libEGL.so.1              -> /nix/store/v8x5c24y4zgxv5xmwhz5lz26ir816c31-libglvnd-1.7.0/lib
claude-desktop-dlopen-runpath>   ok      libGLESv2.so.2           -> /nix/store/v8x5c24y4zgxv5xmwhz5lz26ir816c31-libglvnd-1.7.0/lib
claude-desktop-dlopen-runpath>   ok      libvulkan.so.1           -> /nix/store/6nhncb2xssshqrfx20nydgvbcs5h4j19-claude-desktop-1.24012.9/lib/claude-desktop
claude-desktop-dlopen-runpath>   ok      libva.so.2               -> /nix/store/cjpydg8bqyffw0526ak3chpis931xvsv-libva-2.24.0/lib
claude-desktop-dlopen-runpath>   ok      libva-drm.so.2           -> /nix/store/cjpydg8bqyffw0526ak3chpis931xvsv-libva-2.24.0/lib
claude-desktop-dlopen-runpath>   ok      libpci.so.3              -> /nix/store/wr5s9c80k6fhpy3f452ha6cirw5c9d6c-pciutils-3.15.0/lib
claude-desktop-dlopen-runpath>   ok      libgssapi_krb5.so.2      -> /nix/store/gh32nqhnvx2an8hdkb2z8z3kv405s226-krb5-1.22.2-lib/lib
claude-desktop-dlopen-runpath>   ok      libdbusmenu-glib.so.4    -> /nix/store/0c2m6gdnxxfh5k3xp1zxvmrby0r6qbr3-libdbusmenu-glib-16.04.0/lib
claude-desktop-dlopen-runpath>   ok      libspeechd.so.2          -> /nix/store/xbjhaipy3ddlhllz0bcily2k8brwkfml-speech-dispatcher-0.12.1/lib
claude-desktop-dlopen-runpath>   ok      libuuid.so.1             -> /nix/store/m4q3a226wx3qjd3yrmwv2q0rzsjqf5zg-util-linux-2.42.2-lib/lib
claude-desktop-dlopen-runpath>   ok      libXtst.so.6             -> /nix/store/sn84f2wa25q1f0qvq2c1x5sbr6gp8qgy-libxtst-1.2.5/lib
claude-desktop-dlopen-runpath>   ok      libXcursor.so.1          -> /nix/store/nbmch0g2bi2rjpfxvyi056j21f2l1pkr-libxcursor-1.2.3/lib
claude-desktop-dlopen-runpath>   ok      libX11-xcb.so.1          -> /nix/store/45naqds5dkzsmmrh61wbxbfci73san7n-libx11-1.8.13/lib
claude-desktop-dlopen-runpath>   ok      libxcb-dri3.so.0         -> /nix/store/2chpcgwndk5iphqgwf9r7x4yjysmkd2z-libxcb-1.17.0/lib
claude-desktop-dlopen-runpath>   ok      libxcb-glx.so.0          -> /nix/store/2chpcgwndk5iphqgwf9r7x4yjysmkd2z-libxcb-1.17.0/lib
claude-desktop-dlopen-runpath>   ok      libxcb-present.so.0      -> /nix/store/2chpcgwndk5iphqgwf9r7x4yjysmkd2z-libxcb-1.17.0/lib
claude-desktop-dlopen-runpath>   ok      libxcb-sync.so.1         -> /nix/store/2chpcgwndk5iphqgwf9r7x4yjysmkd2z-libxcb-1.17.0/lib
exit=0
```

22/22 resolve. Both checks are exposed and build:

```
=== checks exposed by the flake ===
  dlopen-runpath
  wrapper-flags

=== both build ===
  both ok
```

### 5. Where it is wired into the updater

`.github/workflows/update.yml`, lines 70–82 — its own named step, placed
*before* the general `nix flake check`:

```yaml
      # Called out as its own step rather than left to `nix flake check`
      # below, because this is the one regression that is silent and
      # security-relevant: if a new upstream build shifts layout such that
      # libsecret-1.so.0 no longer resolves from the RUNPATH, the package
      # still builds and still runs, but the session token drops from a
      # keyring-derived v11 key to v10 obfuscation. A version bump must fail
      # loudly and by name here, not merely somewhere inside flake check.
      - name: Guard - dlopen'd libraries still resolve from RUNPATH
        if: steps.bump.outputs.changed == 'true'
        run: |
          set -euo pipefail
          nix build .#checks.x86_64-linux.dlopen-runpath -L
```

### GAP — why D3 is PARTIAL

**Requirement 5 is only half-proven.** What is proven: the check exits `1` on a
broken RUNPATH (measured above), the step exists, it carries
`set -euo pipefail`, and every later step — including
`peter-evans/create-pull-request` — is gated on `steps.bump.outputs.changed`
with Actions' implicit `success()`, so a failure here cannot reach PR creation.

What is **not** proven: the workflow has never actually executed. This repo has
no git remote —

```
=== remotes ===
(empty above = no remote configured)
```

— so no CI run exists, and "a bump fails loudly" is an inference from the local
exit code plus Actions' documented gating semantics, not an observation. It
becomes real evidence the first time the workflow runs against a genuine
upstream bump. Closing this needs a push and one real (or manually dispatched)
run; it cannot be closed locally.

---

## D4 — tray — DONE

### Verdict

**The SNI host owns this behaviour — it is neither this package's nor
upstream Claude's.**

### Evidence

**1. An SNI host is present.** niri has no XEmbed tray, but waybar is running
and owns the watcher:

```
=== StatusNotifier services on the session bus ===
(unrelated tray applets redacted)
org.kde.StatusNotifierHost-<pid>-0       <pid>  <sni-host>  …
org.kde.StatusNotifierWatcher            <pid>  <sni-host>  …

=== is a StatusNotifierWatcher name owned? ===
b true
```

**2. The app registers correctly.** It appears in the watcher's registry
alongside working tray applets:

```
=== what the Watcher currently has registered ===
  ":1.278/StatusNotifierItem"          <- Claude Desktop
  (other registered tray applets redacted)
```

**3. It advertises left-click activation and implements it:**

```
=== SNI properties ===
  Id          s "Claude_status_icon_1"
  Title       s ""
  Status      s "Active"
  Category    s "ApplicationStatus"
  ItemIsMenu  b false
  Menu        o "/com/canonical/dbusmenu"

=== definitive test: call Activate() directly ===
  call exit=0
```

`busctl introspect` returns no methods for this item; that is normal — Chromium's
SNI implementation publishes no introspection XML. It is not a defect, and the
direct `Activate` call proves the method exists regardless.

**4. Not a missing library in our closure:**

```
=== is libayatana/libappindicator in our closure? ===
  matches: 0
=== is libdbusmenu in our closure? ===
  matches: 1
```

Zero appindicator, yet the item registered successfully — which proves
Electron 42 / Chromium 148 uses its own native SNI and does not need
`libappindicator`. `libdbusmenu-glib` is present, so the menu path is
provisioned.

Waybar's tray config is default — `icon-size` and `spacing` only, no click
mapping — so whatever it does with a left click is waybar 0.15.0's built-in
handling.

### Important caveat on what this proves

`ItemIsMenu = false` proves **what the application advertises**, not **what the
host honours**. A host is free to bind left-click to the context menu
regardless of that property, and nothing in the SNI spec compels it to call
`Activate`. So the evidence rules out "the app declared itself menu-only" and
"the app has no Activate" as explanations; it does not, by itself, establish
what waybar actually does on click.

Related limit: **I never observed an actual left-click.** The reported
behaviour ("clicking the tray icon opens a context menu") is your observation,
not something I reproduced — driving a GUI click was out of scope. If you want
that nailed down, the next step is instrumenting waybar or watching the bus for
an `Activate` call during a real click, and the target is waybar, not this
flake.

### UPower note — environmental, not packaging

The only ERROR emitted during the tray runs:

```
[174707:0801/145942.396588:ERROR:dbus/object_proxy.cc:572] Failed to call method:
org.freedesktop.DBus.Properties.GetAll:
object_path= /org/freedesktop/UPower/devices/DisplayDevice:
org.freedesktop.DBus.Error.ServiceUnknown: The name is not activatable
```

`org.freedesktop.UPower` is not running on this host, so the battery-status
probe fails. This is a **system service** that is absent, not a library this
package should carry — adding UPower to the closure would not help, since the
app needs the running daemon, not the library. Harmless, unrelated to the tray,
and out of scope. Enable `services.upower.enable = true;` if you want it gone.

Zero tray/SNI/dbusmenu diagnostics appeared in the run logs, so nothing was
failing silently behind the scenes.

---

## Known gaps

Open items across phases A–D, including things flagged in passing that never
got a response.

1. **D3 requirement 5 — the updater guard has never run in CI.** No git remote
   exists, so the workflow has never executed. See the D3 gap section.
2. **`suidSandbox = true` has never been runtime-tested.** B3's variant was
   verified only structurally (bundled helper absent, `CHROME_DEVEL_SANDBOX`
   set in the wrapper, builds clean). No host without a usable namespace
   sandbox was available, so it has never actually launched. The mechanism it
   relies on *was* measured directly (`setuid_sandbox_host.cc:166` vs `:156`),
   but end-to-end it is unproven.
3. **The leaked Chrome Safe Storage key is still in the transcript.** Not
   deleted, per instruction. Rotation is your call; it is a local OSCrypt key
   for Chrome, not for Claude.
4. **`~/.config/Claude` was never snapshotted *before* it was polluted.** The
   earliest checksum I hold was taken in D2, i.e. after the early Phase A/B
   launches had already rotated cookies. The D2 isolation prevents further
   drift but cannot undo that.
5. **`~/.local/share/applications/mimeapps.list` conflict is documented, not
   fixed.** The startup `Read-only file system` error persists until you apply
   the declarative `xdg.mimeApps.defaultApplications` snippet from the README.
   Flagged in Phase A; no response since.
6. **The derivation is version-specific by design.** Proven in A5: upstream
   renamed the desktop entry between releases
   (`claude-desktop.desktop` → `com.anthropic.Claude.desktop`), and building an
   older `.deb` fails at `substituteInPlace`. This is the intended trade — fail
   visibly rather than ship a package with no desktop entry — but it means some
   upstream bumps will need a manual fix, not just a hash bump.
7. **`claude-desktop-fhs` nested-namespace behaviour is verified only on this
   kernel.** It launches correctly here; on a kernel forbidding nested user
   namespaces it will not start, and that path is untested.
8. **arm64 remains unimplemented** (explicit non-goal). `TODO(arm64)` markers
   are in `flake.nix` and `pkgs/claude-desktop.nix`; upstream ships arm64 at
   version parity.
9. **`PHASE-D-REPORT.md` is untracked** at the time of writing — this file was
   created as a reporting deliverable and has not been committed, since the
   task specified no code or repo changes.

Phase C is **closed, not a gap**: you selected option 2 (one `/goal` per
phase), so the proposed goal-text change was never needed and no hook config
was touched.

---

## Commits

Phase B and Phase D landed in two commits. (`4753550` predates both and is
listed for continuity.)

| SHA | What landed |
| --- | --- |
| `2a915f0` | **Phase B.** Confirmed v11 keyring path (B0); removed the empty `LD_LIBRARY_PATH` element, then dropped the variable entirely in favour of `DT_RUNPATH` via `appendRunpaths` (B2a/B2b); added the `suidSandbox` option with the default output unchanged (B3); `set -euo pipefail` in every workflow `run:` block, closing the `\| tee` swallow (B5); README on the Secret Service requirement and Cowork's real state (B1/B4). |
| `b8a465f` | **Phase D.** Added `checks.dlopen-runpath` with the soname list in `passthru.dlopenSonames`, wired it into the updater as its own named step (D3); documented profile snapshotting and the throwaway `XDG_CONFIG_HOME` test invocation in the README (D2). |
| `4753550` | *(Phase 0–2, for context.)* Initial packaging of the official Linux `.deb`: derivation, FHS variant, overlay, daily updater workflow. |

D1 and D4 produced no commits — both were investigations, and D4's verdict was
that nothing in this repo owns the behaviour.
