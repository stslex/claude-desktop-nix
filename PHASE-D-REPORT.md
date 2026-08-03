# Phase D report

Reporting only — no code, flake, workflow or hook changes were made while
producing the original of this file.

**Revised 2026-08-03, in response to the review on PR #1.** Two claims did not
survive scrutiny and are corrected in place rather than annotated, so that what
is written here is what the tree actually does; a third was challenged, held up
under measurement, and now carries the evidence it should have had:

- **D3** claimed the soname list "cannot drift" from `runtimeLibs` because the
  two sit next to each other in the same file. Adjacency is a convention, not
  a mechanism. The guard now rescans the shipped ELFs on every run and
  reconciles the lists against that scan — and the first such scan found four
  of the twenty-two entries no longer confirmable, i.e. the drift the original
  wording called impossible had already happened.
- **D4**'s verdict named the SNI host as the owner of the tray behaviour on
  evidence that cannot establish ownership; the same section then admitted no
  click was ever observed. The verdict is rewritten to claim only what was
  measured.
- **Gap 3** described the leaked keyring value as "a local OSCrypt key for
  Chrome, not for Claude" and showed nothing to back it, which reads as a
  contradiction of this report's own v11 finding. Measured since: the leaked
  item carries `application=chrome` (Google Chrome), Claude Desktop's carries
  `application=Claude`, and both are *labelled* by product rather than by app —
  which is exactly what makes them easy to confuse. The claim stands; the proof
  is now in D1.

Thirteen further review rounds on the rewrite found eighteen more holes in the
guard, all now closed and described in D3. Round two: `DT_NEEDED` was classified
globally rather than per object, so one object could dlopen a soname only
another object links with nothing checking it could reach it; and a waiver
could outlive the string that justified it. Round three: waivers were still
keyed by soname alone, so a waiver written for one binary excused every other
binary that started naming the same soname; and the unversioned-stem fallback
was a blanket rule, so dropping `libnotify.so.1` while `libnotify.so` remained
would have kept the stale entry alive. Waivers are now object-scoped and the
stem rule is gone, replaced by declared spelling tables. Round four: a second
spelling that sits *beside* an exact soname was still being accepted as proof
that the exact one was still named, and `$ORIGIN` in a RUNPATH was tested as a
literal directory rather than resolved against the object — the first would
have let a waiver go stale unnoticed, the second would have failed a bump that
works at runtime. Round five found two more of that second kind: a
runtime-versioned spelling was resolved as the literal string the binary never
opens, and the bundled-library inventory counted only regular files, so a
library shipped the ordinary way — soname as a symlink onto a versioned file —
would have been reported as an unclassified soname. Round six found one of
each: object paths were held in a space-delimited string, so an ELF under a
path containing whitespace was split into objects that do not exist; and the
second-spelling fallback was granted payload-wide, so an object that only ever
opens the generic spelling was called reachable on the strength of a different
object naming the exact one. Round seven closed the same hole one level down:
scoping the fallback to the object was not enough, because an object's
`DT_NEEDED` entries and its own `DT_SONAME` live in `.dynstr` and so appear in
a string scan — linkage metadata was being read as evidence of a second
`dlopen` attempt. Round eight then corrected the correction: subtracting those
names outright was too blunt, since an ELF may legitimately link a soname *and*
carry it as a literal fallback. Round nine finished the thought — "outside
`.dynstr`" is not the same as "reachable by a call", because `dontStrip = true`
keeps `.comment`, `.shstrtab` and `.gnu_debuglink` in the file, and a soname
sitting in one of those is a note about the binary rather than something it can
open. The evidence is now an occurrence inside a `PT_LOAD` segment and outside
`.dynstr`. Round ten removed the last fail-open default in that machinery:
`.dynstr` was located by section-header *name*, and ELF section headers are
optional, so an object that hid them fell through to "no linkage table to
exclude". It is derived from `PT_DYNAMIC`'s `DT_STRTAB`/`DT_STRSZ` now — what
the loader itself reads. Round eleven scoped the last global table: the
runtime-versioned spellings carried no object identity, so a *different* ELF
naming `libva.so` as an ordinary literal would have had `libva.so.2` checked on
its behalf. Round twelve found the one path that never reached the
mapped-literal gate — a spelling could inherit its target's waiver with no
evidence that the object treats them as the same library, so a probe for the
generic name was excused by a waiver on a name the object merely links. Round
thirteen applied the same rule to a runtime-versioned declaration, which was
honoured and kept alive on any occurrence of the prefix at all, including one
surviving only in debug metadata; round fourteen applied it to the plainest
path of the lot, the provided sonames themselves, whose reference assertion was
still satisfied by a bare scan hit.

The D3 gap is separately closed: the workflow has since run in CI on a real
bump. All of this is detailed in the sections below.

| Item | Status |
| --- | --- |
| D1 — leak audit | **DONE** |
| D2 — profile hygiene | **DONE** |
| D3 — v10/v11 regression guard | **DONE** — all five requirements met; one residual inference is stated at the end of that section |
| D4 — tray | **DONE** (investigation delivered; the verdict is bounded by what was actually measured — see the section) |

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

### Which key it is — added 2026-08-03

Review challenged the claim in gap 3 that this value is "a local OSCrypt key
for Chrome, not for Claude", on the grounds that it contradicts B0: Claude's
`sessionKey` cookies carry the **v11** tag, so they *are* sealed with a
Secret-Service-derived key. That was a fair reading of a bare assertion — the
original showed no evidence for it. Here is the measurement.

The command that produced the leak looked the item up by attribute:

```
$ secret-tool lookup application chrome      # label = Chrome Safe Storage
```

Every Chromium-family app stores its own OSCrypt key under the same libsecret
schema (`chrome_libsecret_os_crypt_password_v2`), separated by an `application`
attribute. Read from this host's Secret Service — `Label` and `Attributes`
properties only, no secret values:

```
LABEL "Chrome Safe Storage"        ATTRS  "application" "chrome"     <- the leaked one
LABEL "Chromium Safe Storage"      ATTRS  "application" "Claude"     <- Claude Desktop
LABEL "Chromium Safe Storage"      ATTRS  "application" "chromium"
(four further unrelated Chromium/Electron apps redacted)
```

The **label** is not a discriminator: Electron apps keep Chromium's default
product name, so Claude Desktop's item is labelled `Chromium Safe Storage` —
`strings` on the shipped binary finds exactly that literal and no
`Claude Safe Storage`. The `application` attribute is what separates them, and
the leaked lookup used `chrome`.

So the transcript holds **Google Chrome's** OSCrypt key. It decrypts Chrome's
own cookie and password stores on this host; it does not decrypt
`~/.config/Claude/Cookies`, which is sealed with the separate
`application=Claude` item. B0's v11 finding is untouched — Claude's cookies are
keyring-derived, from a different keyring entry.

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

## D3 — v10/v11 regression guard — DONE

All five requested items are complete. The guard was rewritten in response to
review (see the note at the top of this file); what follows describes the
version now in the tree, not the original.

### 1. The check, and the three properties it asserts

It moved out of `flake.nix` into `pkgs/dlopen-runpath.nix` when it grew a
scanner. `flake.nix` now only calls it:

```nix
# Static regression guard for the dlopen'd libraries: resolve,
# reference and novelty assertions against a fresh scan of the
# shipped ELFs. The rationale, and the limits of a string scan, are
# documented at the top of the file itself.
dlopen-runpath = pkgs.callPackage ./pkgs/dlopen-runpath.nix {
  inherit claude-desktop;
};
```

The reason it exists is unchanged. `nix build` stays green when a dlopen'd
soname stops resolving, because dlopen failure is a runtime event, not a link
error. If `libsecret-1.so.0` drops out of the RUNPATH — an Electron bump
changing layout, someone editing `runtimeLibs`, `appendRunpaths` breaking —
os_crypt falls back from a keyring-derived **v11** key to the
hardcoded-password **v10** path, and the session token quietly stops being
protected.

What changed is the recognition that resolving a hand-written list only proves
that the hand-written list still resolves. Three assertions now run against a
fresh scan of every ELF object in the output:

| | Assertion | The regression it catches |
| --- | --- | --- |
| 1 | **RESOLVE** — every soname the package claims to provide resolves from the main executable's RUNPATH | the library leaves the closure, or the RUNPATH stops reaching it |
| 1b | **REACHABILITY** — *every* (object, soname) pair the scan produced resolves from that object's own RUNPATH — resolving what the loader is actually asked for, which for a spelling the *naming object* is declared to compose at runtime is the mapped soname rather than the string in the binary, and for a second spelling is the literal unless *this same object* carries the exact soname where a call could reach it — inside a `PT_LOAD` segment and outside the dynamic string table located through `PT_DYNAMIC`, rather than in linkage metadata or in a section that is never mapped — exempting only the object's own `DT_SONAME`, its **own** `DT_NEEDED`, and sonames waived **for that object** | object A dlopening something only object B links, or something waived only because B probes for it. Both `DT_NEEDED` and a waiver are per-object facts; a global union of either vouches for A on B's evidence |
| 2 | **REFERENCE** — every soname the lists mention is still named by the payload: provided sonames anywhere, waivers by the object they were written for, declared aliases anywhere | upstream drops a dlopen and the entry becomes an assertion that passes forever while testing nothing; or a waiver or alias goes stale and silently pre-approves a soname that later comes back for something that matters |
| 3 | **NOVELTY** — every soname-shaped string in the payload is accounted for: `DT_NEEDED`, bundled with the app, provided by us, or waived by name with a reason | upstream *adds* a dlopen — which the others cannot see at all |

Assertions (1b), (2) and (3) are what tie the lists to the binary. The original
version had none of them, which is why its "the two cannot drift" claim was
wrong: `dlopenSonames` sitting next to `runtimeLibs` is a convention for the
person editing the file, and conventions are exactly what an upstream bump
ignores. (1b) and the waiver half of (2) came out of the second review round — the
first rewrite still classified `DT_NEEDED` globally and still let a waiver
outlive the string that justified it. The third round removed the last two
global assumptions: waivers are now keyed by `(object, soname)` rather than by
soname, and there is no stem matching anywhere.

The exemptions in (1b) are each per-object for a reason. An ELF's own
`DT_SONAME` appears in its own strings. A soname in *this* object's
`DT_NEEDED` is already the build's problem — autopatchelf would have failed —
and `libc` and friends resolve through the patched interpreter's own search
path rather than any RUNPATH, so demanding a RUNPATH hit for them would fail
on a correct package. "We chose not to provide it" is the only other answer
that excuses a soname from resolving — and it is a claim about one binary.
"crashpad probes for libcurl and no crash server is configured" says nothing
about the main executable suddenly probing for it, so waivers are scoped to
the object that earned them.

**No stem matching.** An unversioned spelling counts as a reference to a
versioned soname only where `passthru.dlopenSonamesRuntimeVersioned` declares
it, one spelling to one target — and only there. The six entries in
`dlopenSonamesSecondSpellings` classify their string and make it inherit the
target's waiver or provision, but they never stand in as *proof*, because the
exact string is present today: `libcurl.so` disappearing from crashpad is
nothing, `libcurl.so.4` disappearing is news. Measured at 1.24012.9: every
second-spelling target is named exactly by at least one object, while
`libva.so.2` and `libva-drm.so.2` are named by none — which is what puts them
in different tables. The blanket rule they replaced was leaky in both
directions: it would have accepted `libnotify.so` as evidence that a dropped
`libnotify.so.1` probe was still alive, and — measured, not hypothesised — it
had been silently *waiving* `libnotify.so` in the reachability pass, on the
grounds that it is the stem of the waived `libnotify.so.1`, even though it is
the alias of `libnotify.so.4`, which this package does provide. Removing the
rule moved that pair from "exempt" to "checked": 36 pairs became 37.

It is still deliberately static — sonames are resolved against RUNPATH entries
rather than by launching the app. An Xvfb launch check would be strictly worse
here: it needs a display, a D-Bus session and a live Secret Service provider to
tell v10 from v11, none of which exist in the build sandbox, and it would be
slow and flaky in exchange for testing the same property this resolves
directly.

**Limits of the scan, stated rather than papered over.** It is a string scan.
A soname assembled at runtime is invisible to it — `libva` is the live example,
and the reason an unversioned stem counts as a reference. A string can be
present without any code path reaching the `dlopen`. Only ELF objects are
scanned; nothing inside `app.asar` is. So (3) is a tripwire for the common
case, not a proof of completeness.

### 2. The three lists, and the drift the first scan found

They live in `pkgs/claude-desktop.nix` as `passthru`, still next to
`runtimeLibs` — but now because that is convenient to read, not because
adjacency is load-bearing.

```nix
# Sonames this package is responsible for providing: named by a shipped
# ELF, covered by no DT_NEEDED entry, and required to resolve from the
# RUNPATH of the object that opens them.
dlopenSonames = [
  "libsecret-1.so.0"       # os_crypt keyring -> v11 vs v10
  "libnotify.so.4"         # desktop notifications
  "libgdk_pixbuf-2.0.so.0" # image loading
  "libgdk-3.so.0"          # GTK loader, alongside DT_NEEDED libgtk-3.so.0
  "libpulse.so.0"          # audio output
  "libGL.so.1"             # GPU compositing
  "libEGL.so.1"
  "libGLESv2.so.2"
  "libvulkan.so.1"         # Vulkan backend
  "libva.so.2"             # VA-API hardware video decode
  "libva-drm.so.2"
  "libpci.so.3"            # GPU enumeration
  "libgssapi_krb5.so.2"    # SPNEGO / Negotiate auth
  "libdbusmenu-glib.so.4"  # tray menus
  "libspeechd.so.2"        # accessibility TTS
  "libnssckbi.so"          # NSS builtin trust roots
  "libXcursor.so.1"
  "libX11-xcb.so.1"
  "libxcb-dri3.so.0"
  "libxcb-glx.so.0"
  "libxcb-present.so.0"
  "libxcb-sync.so.1"
];

# Held to the resolve assertion but exempt from the reference assertion:
# upstream's `Depends` lists them, so runtimeLibs keeps providing them,
# but no string in any shipped ELF names them (rechecked at 1.24012.9).
dlopenSonamesDependsOnly = [
  "libuuid.so.1"
  "libXtst.so.6"
];

# Named by the payload and deliberately NOT provided, keyed by the
# object that names it — a waiver is a claim about one binary, and does
# not carry over to another that starts naming the same soname.
dlopenSonamesUnprovided = {
  "lib/claude-desktop/claude-desktop" = [ /* 20, grouped by reason */ ];
  "lib/claude-desktop/chrome_crashpad_handler" = [
    "libcurl.so.4" "libcurl-gnutls.so.4" "libcurl-nss.so.4"
  ];
  "lib/claude-desktop/libvk_swiftshader.so" = [
    "libwayland-client.so.0" "libxcb-shm.so.0"
  ];
};

# Keyed by the object that composes the version at runtime: there the
# versioned string never appears, so the unversioned form is the only
# evidence there is and *does* stand in for an exact reference. Another
# object naming the same string is asking for that exact file.
dlopenSonamesRuntimeVersioned = {
  "lib/claude-desktop/claude-desktop" = {
    "libva.so" = "libva.so.2";
    "libva-drm.so" = "libva-drm.so.2";
  };
};

# Spellings the payload carries *in addition to* the exact soname. They
# classify the string and inherit the target's waiver or provision, but
# never count as proof that the exact string is still named.
dlopenSonamesSecondSpellings = {
  "libGL.so" = "libGL.so.1";
  "libcurl.so" = "libcurl.so.4";
  "libdbusmenu-glib.so" = "libdbusmenu-glib.so.4";
  "libnotify.so" = "libnotify.so.4";
  "libpci.so" = "libpci.so.3";
  "libvulkan.so" = "libvulkan.so.1";
};
```

**What the reference assertion found immediately.** The original wrote that
"every entry is a soname string-scanned out of the main executable during the
A2 investigation". At `1.24012.9`, four of the twenty-two entries no longer
match that description:

| Entry | Named by the payload? | Disposition |
| --- | --- | --- |
| `libva.so.2` | as `libva.so` | the ABI version is appended at runtime, so the unversioned spelling is declared as its alias |
| `libva-drm.so.2` | as `libva-drm.so` | same |
| `libuuid.so.1` | **no** — no string in any shipped ELF, and no `DT_NEEDED` entry | moved to `dlopenSonamesDependsOnly`: upstream's `Depends` lists it, so `runtimeLibs` keeps providing it, but the guard no longer claims a reference it cannot show |
| `libXtst.so.6` | **no** — same | same |

Whether those two were ever dlopen'd or were only ever `Depends` entries, the
old check could not tell the difference and the old report asserted the
stronger claim. The new one records what is actually observable.

**What the novelty assertion forced.** Its first run surfaced 35 soname
strings that were neither `DT_NEEDED`, bundled, nor listed anywhere:

- **8** are unversioned spellings of sonames the package already provides or
  waives (`libGL.so` beside `libGL.so.1`, and so on). These are declared one by
  one, split across two tables by whether the exact string exists elsewhere in
  the payload; the stem-matching rule that used to cover them was removed in
  the third review round, because a blanket rule cannot tell "the binary spells
  it both ways" from "the versioned probe is gone and only the generic string
  is left".
- **2** resolve from the RUNPATH today and are now asserted rather than waived:
  `libgdk-3.so.0` (from gtk3, beside the `DT_NEEDED` `libgtk-3.so.0`) and
  `libnssckbi.so` (from nss, beside `libnss3.so`). Both were satisfied only as a side
  effect of gtk3 and nss being in the closure for other reasons; they are now
  checked on purpose.
- **25** are waived by name in `dlopenSonamesUnprovided`, grouped with the
  reason: probe alternates the binary tries in turn (`libnotify.so.1/.5`,
  Heimdal `libgssapi.so.*`, `libgtk-4.so.1`, `libunity.so.*`), libraries that
  come from the impure driver link and cannot exist in a build sandbox
  (`libGLX_nvidia.so.0`, `libvulkan_{intel,radeon,freedreno}.so`), glibc's own
  NSS modules, optional Google components upstream fetches at runtime
  (`libsoda.so`, the three `libLiteRt*`), crashpad's libcurl transport,
  RenderDoc, and two sonames named only by the bundled SwiftShader.

`libnotify.so.1` / `libnotify.so.5` remain excluded for the reason the original
gave — the binary probes several libnotify versions and needs one, nixpkgs
ships `.so.4` — but they are now excluded *by name in a list the guard reads*,
rather than by omission:

```
  RESOLVES   libnotify.so.4
  MISSING    libnotify.so.1
  MISSING    libnotify.so.5
```

The check also still rejects an empty RUNPATH element — the `DT_RUNPATH`
analogue of the `LD_LIBRARY_PATH` bug fixed in `0652904` — and now does so for
every shipped ELF rather than the main executable alone.

### 3. Negative tests — one per assertion (verbatim)

Each was produced by editing `pkgs/claude-desktop.nix` (or, for REACHABILITY,
a copy of the built output), running the check, and restoring. Exit codes were
measured without a pipe.

**RESOLVE** — `libsecret` removed from `runtimeLibs`:

```
claude-desktop-dlopen-runpath>   FAIL    libsecret-1.so.0           unresolvable from RUNPATH
...
claude-desktop-dlopen-runpath>   ok      libsecret-1.so.0           named by lib/claude-desktop/claude-desktop
error: Cannot build '/nix/store/kglj45ggsmv23rfl6jbqxfjnx29mczh2-claude-desktop-dlopen-runpath.drv'.

RESOLVE (libsecret dropped from runtimeLibs): nix build exit code = 1
```

Note the second line: the library is gone but the *reference* is still there,
which is exactly how this failure looks in the field.

**REFERENCE** — `libkrb5.so.3` added to `dlopenSonames`. It is in the closure
(krb5 is already a `runtimeLibs` entry for `libgssapi_krb5.so.2`) but no
shipped ELF names it, so it resolves and still fails — the two assertions are
independent:

```
claude-desktop-dlopen-runpath>   ok      libkrb5.so.3               -> /nix/store/gh32nqhnvx2an8hdkb2z8z3kv405s226-krb5-1.22.2-lib/lib
claude-desktop-dlopen-runpath>   FAIL    libkrb5.so.3               no longer named by any shipped ELF

REFERENCE (listed soname the payload never names): nix build exit code = 1
```

**NOVELTY** — one entry (`libsoda.so`) deleted from
`dlopenSonamesUnprovided`, simulating a soname the payload names that nobody
has classified:

```
claude-desktop-dlopen-runpath> == novelty: every soname string is classified
claude-desktop-dlopen-runpath>   FAIL    libsoda.so                 unclassified, named by lib/claude-desktop/claude-desktop

NOVELTY (a named soname left unclassified): nix build exit code = 1
```

**REACHABILITY** — the second review round's case: an object naming a soname
that only *another* object links. `libvk_swiftshader.so` names `libxcb.so.1`
and does not have it in its own `DT_NEEDED`; the main executable does. Removing
the libxcb entry from that one object's RUNPATH (17 → 16 entries) leaves every
other assertion green and fails only this one:

```
  FAIL    libxcb.so.1                named by lib/claude-desktop/libvk_swiftshader.so, unresolvable from its RUNPATH
  ok      36 (object, soname) pairs resolve; 114 exempt (own soname, that object's DT_NEEDED, or waived)

exit code = 1
```

Note what stays silent: `libxcb.so.1` is not on the provided list, so RESOLVE
never looks at it, and it is `DT_NEEDED` *somewhere*, so NOVELTY classifies it
happily. Before this assertion existed the whole run was green. A store path
cannot be mutated in place, so this one was produced by running the check's own
`buildCommand` — extracted with `nix derivation show` — against a writable copy
of the output with that single RUNPATH edited; the store path was left
untouched and the copy deleted afterwards.

**STALE WAIVER** — `libunity.so.42` added to `dlopenSonamesUnprovided`,
standing in for a waiver upstream has stopped naming:

```
claude-desktop-dlopen-runpath> == reference: waivers are still named by the payload
claude-desktop-dlopen-runpath>   FAIL    libunity.so.42             stale waiver: no longer named by any shipped ELF

STALE WAIVER: nix build exit code = 1
```

**WAIVER SCOPE** — the third review round's case: a waiver that belongs to a
different binary. Moving crashpad's three libcurl entries onto the main
executable's list, leaving the strings where they are:

```
== reachability: each named soname resolves from the RUNPATH of the object naming it
  FAIL    libcurl.so.4               named by lib/claude-desktop/chrome_crashpad_handler, unresolvable from its RUNPATH
  FAIL    libcurl.so                 named by lib/claude-desktop/chrome_crashpad_handler, unresolvable from its RUNPATH
  FAIL    libcurl-gnutls.so.4        named by lib/claude-desktop/chrome_crashpad_handler, unresolvable from its RUNPATH
  FAIL    libcurl-nss.so.4           named by lib/claude-desktop/chrome_crashpad_handler, unresolvable from its RUNPATH
== reference: waivers are still named by the object they were written for
  FAIL    libcurl.so.4               stale waiver: lib/claude-desktop/claude-desktop no longer names it
  FAIL    libcurl-gnutls.so.4        stale waiver: lib/claude-desktop/claude-desktop no longer names it
  FAIL    libcurl-nss.so.4           stale waiver: lib/claude-desktop/claude-desktop no longer names it

  nix build exit code = 1
```

Both halves fire, from opposite directions: crashpad names sonames nothing
waives *for it*, and the main executable holds waivers for strings it does not
name. NOVELTY stays silent throughout — the sonames are still classified — which
is why the scoping had to live in the other two assertions.

**ALIAS STRICTNESS** — `libnotify.so.9` added as a waiver. Nothing names it;
the generic `libnotify.so` is present but is declared as the alias of
`libnotify.so.4`, so it cannot stand in:

```
  FAIL    libnotify.so.9             stale waiver: lib/claude-desktop/claude-desktop no longer names it

  nix build exit code = 1
```

Under the stem rule this passed, because `libnotify.so` is the stem of
`libnotify.so.9` as much as of `libnotify.so.4`. That ambiguity is what the
one-alias-one-target table removes.

**SPELLING CLASS** — the fourth round's first case. Demoting `libva.so` from
`dlopenSonamesRuntimeVersioned` to `dlopenSonamesSecondSpellings`, i.e.
claiming the exact string exists when it does not, with `libva-drm` left alone
as the control:

```
  FAIL    libva.so.2                 no longer named by any shipped ELF
  ok      libva-drm.so.2             named as libva-drm.so (version appended at runtime)

  nix build exit code = 1
```

Same payload, same two libraries, opposite results — which is the whole point
of the split. A second spelling standing beside an exact string proves nothing
about that string, so `libcurl.so` cannot vouch for a `libcurl.so.4` waiver
that crashpad has stopped naming.

**LOADER TOKENS** — the fourth round's second case, and the only finding so far
that was about a *false failure* rather than a false pass. `libGLESv2.so`'s
RUNPATH set to `$ORIGIN` on a copy of the output, where `libvulkan.so.1` sits
in the same directory and is therefore genuinely reachable at runtime:

```
round-3 check (literal path test)         round-4 check ($ORIGIN expanded)
  FAIL  libpci.so       …                   FAIL  libpci.so       …
  FAIL  libGL.so.1      …                   FAIL  libGL.so.1      …
  FAIL  libpci.so.3     …                   FAIL  libpci.so.3     …
  FAIL  libvulkan.so    …                   FAIL  libvulkan.so    …
  FAIL  libvulkan.so.1  …  <-- false        FAIL  libEGL.so.1     …
  FAIL  libEGL.so.1     …
```

The five that fail in both really are unreachable — those store paths were
removed from the RUNPATH. `libvulkan.so.1` is the difference: it is the one
library sitting next to the object, and under the old literal test it would
have blocked an automated bump for a package that works. Tokens the check does
*not* model (`$LIB`, `$PLATFORM`) are refused by name rather than guessed at:

```
FAIL: unsupported loader token in RUNPATH of lib/claude-desktop/libGLESv2.so: $ORIGIN/../$LIB
      only $ORIGIN is modelled; teach resolveIn the rest before trusting this
```

The last two rounds turned up **false failures** rather than false passes —
cases where the guard would have blocked a bump that works. Both were caught
the same way, by running the previous revision of the check and the current one
against the same doctored copy of the output.

**RUNTIME-VERSIONED RESOLUTION.** nixpkgs routinely keeps the unversioned
`libfoo.so` symlink in a package's `dev` output while the runtime library
`libfoo.so.N` sits in the main one. Pointing the RUNPATH at a libva directory
that carries only `libva.so.2` and `libva-drm.so.2` — no unversioned symlinks —
is enough to show it:

```
round-4 check (resolves the literal)            round-5 check (resolves the mapped soname)
  FAIL  libva.so      … unresolvable              ok  libva.so.2      named as libva.so
  FAIL  libva-drm.so  … unresolvable              ok  libva-drm.so.2  named as libva-drm.so
```

The binary never opens `libva.so`; it appends the ABI version and opens
`libva.so.2`, which was present the whole time. Second spellings keep resolving
the literal, with the mapped soname as a fallback, because those the binary
does try by both names.

**BUNDLED SONAME SYMLINKS.** Shipping `libEGL.so -> libEGL.so.1.5.0` in the app
directory is the ordinary way to ship a library, and `find -type f` records only
the target, so the soname itself went missing from the bundled inventory:

```
round-4 check (-type f)                         round-5 check (-xtype f)
  FAIL  libEGL.so  unclassified, named by …       ok  all 93 classified
```

It resolved fine — `[ -e ]` follows the link — it was only the classification
that broke, which is enough to block the automated bump. `-xtype f` follows the
link and tests the target, so a dangling symlink still does not count as
bundled.

**WHITESPACE IN OBJECT PATHS.** Objects naming a soname were held in a
space-delimited string. Dropping a copy of `libGLESv2.so` at
`resources/My Helper/` — everything it names is reachable from its intact
RUNPATH — is enough:

```
round-5 check (space-delimited)                          round-6 check (newline-delimited)
  FAIL  libX11.so.6  named by lib/…/resources/My …         ok  43 (object, soname) pairs resolve
  FAIL  libX11.so.6  named by Helper/libGLESv2.so …
  FAIL  libpci.so    named by lib/…/resources/My …
  FAIL  libpci.so    named by Helper/libGLESv2.so …
```

Two objects that do not exist, each with an empty RUNPATH record, failing
everything the real one names. The pair tables are tab-separated for the same
reason — an object path is a file path.

**SECOND-SPELLING FALLBACK SCOPE.** A second spelling is one the binary tries
*alongside* the exact name, so resolving the mapped soname instead of the
literal is only defensible when the same object names both. It was being
granted payload-wide. Built directly: a small ELF whose only libnotify string
is `libnotify.so`, with a RUNPATH pointing at a directory holding
`libnotify.so.4` and no unversioned symlink — i.e. an object whose `dlopen`
fails at runtime:

```
round-5 check                                round-6 check
  (no finding — 38 pairs resolve)              FAIL  libnotify.so  named by lib/…/libspell.so,
                                                     unresolvable from its RUNPATH
```

**LINKAGE METADATA IS NOT EVIDENCE — AND NEITHER IS ITS ABSENCE BY NAME.**
Scoping the fallback to the naming object still read `.dynstr` as if it were
`.rodata`: an ELF linked against `libnotify.so.4` carries that string whether or
not any code calls it. Round seven subtracted `DT_NEEDED` and `DT_SONAME` names
outright, which round eight showed to be too blunt — an ELF may link a soname
*and* carry it as a literal fallback, and that object does try both. The
question is settled by offset instead. Two shared objects built to order, both
linked against `libnotify.so.4`, on a RUNPATH holding only the versioned file:

```
libboth.so   .dynstr at 0x398 + 0x106      libonly.so   .dynstr at 0x370 + 0x106
  libnotify.so.4 at offset 1009  <- linkage    libnotify.so.4 at offset 969  <- linkage
  libnotify.so.4 at offset 8205  <- literal    (no other occurrence)

round-7 check (subtracts names)            round-8 check (offset decides)
  FAIL  libnotify.so  … libboth.so   <- false   FAIL  libnotify.so  … libonly.so
  FAIL  libnotify.so  … libonly.so
```

`libboth.so` does try both spellings and works; `libonly.so` does not and is
broken. Only the second is reported now, and round seven's finding is kept.

Round nine then closed the remaining gap in that test: *outside `.dynstr`* is
not the same as *reachable by a call*. This package sets `dontStrip = true`, so
`.comment`, `.shstrtab` and `.gnu_debuglink` survive into the store path, and a
soname appearing in one of them was being counted as a literal. A third object,
`libmeta.so` — `libonly.so` plus the exact soname in a section marked
`noload` — shows the difference:

```
  .fakemeta at file offset 0x3022
  PT_LOAD:  0x000000+0x568  0x001000+0x111  0x002000+0xe8  0x002de8+0x228  0x004000+0x218
                                                    ^ ends at 0x3010          ^ starts at 0x4000

round-8 check (offset outside .dynstr)   round-9 check (and inside PT_LOAD)
  FAIL  libnotify.so … libonly.so          FAIL  libnotify.so … libmeta.so
                                           FAIL  libnotify.so … libonly.so
```

`libboth.so` is reported by neither, which is the point: three objects, three
different kinds of occurrence, one verdict each.

The original round-seven fixture, for the record — a shared object linked
against the exact soname whose only string literal is the generic spelling, on
a RUNPATH holding only the versioned file:

```
  DT_NEEDED:     libnotify.so.4 libc.so.6
  string scan:   libnotify.so libnotify.so.4      <- the second one is .dynstr
  RUNPATH holds: libnotify.so.4

round-6 check                          round-7 check
  (no finding — 38 pairs resolve)        FAIL  libnotify.so  named by lib/…/libspell.so,
                                               unresolvable from its RUNPATH
```

`dlopen` matches on the name it is asked for, so that call returns NULL however
the object is linked.

**A FAIL-OPEN DEFAULT, AND WHAT LOOKING FOR IT TURNED UP.** `.dynstr` was found
by section-header name, and section headers are optional in ELF: an object
without them fell through to `dynOff=-1`, meaning "no linkage table to exclude",
so every `DT_NEEDED` name in the mapped string table counted as a literal. It is
derived from `PT_DYNAMIC`'s `DT_STRTAB` and `DT_STRSZ` now, which is what the
loader itself reads. Verified against the section headers on three real
objects, byte for byte:

```
  claude-desktop           PT_DYNAMIC -> [218107904 218954328]   sections -> [218107904 218954328]
  libGLESv2.so             PT_DYNAMIC -> [6427200 6470926]       sections -> [6427200 6470926]
  chrome_crashpad_handler  PT_DYNAMIC -> [1921568 1931616]       sections -> [1921568 1931616]
```

**No before/after transcript for this one, and the reason is worth recording.**
Two fixtures were built to exercise the old path — an object with
`--strip-section-headers`, and one with `.dynstr` renamed — and neither showed a
difference, because `patchelf` refuses both files as well. Its `--print-rpath`
and `--print-needed` exit 1, the object ends up with an empty RUNPATH record,
and everything it names fails in *both* revisions. The hole was real in the code
and unreachable in practice, masked by an accident of a different tool. Deriving
the range from `PT_DYNAMIC` is still the right fix — the guard should not depend
on that accident, and a later change of how the RUNPATH is read would silently
reopen it — but nothing about the current payload changes.

What the fixtures did expose is a reporting bug. An object patchelf cannot parse
used to produce a stream of "unresolvable from its RUNPATH" lines, which is the
right verdict reached by the wrong route and explained misleadingly. It now says
so:

```
  FAIL    libnotify.so.4   named by lib/…/libnosh.so, whose dynamic metadata patchelf cannot read
          (a stripped section-header table or a self-decompressing binary:
           its RUNPATH is unknown, so this cannot be shown to resolve)
```

The diagnosis is attached to the sonames such an object actually names, not to
the object itself — `resources/cowork-linux-helper` is exactly that kind of
binary today, and it names no sonames at all, so nothing about it needs
reporting.

**A SUBSTITUTION APPLIED TO AN OBJECT THAT NEVER EARNED IT.** `libva.so`
standing for `libva.so.2` is true of the main executable, which appends the ABI
version at runtime. It is not a property of the string. A second object naming
`libva.so` as an ordinary `dlopen` literal, on a RUNPATH holding only
`libva.so.2` — which is what a runtime output normally carries, the unversioned
symlink living in `dev`:

```
round-10 check (global map)               round-11 check (scoped to the declarer)
  (no finding)                              FAIL  libva.so  named by lib/…/libvaprobe.so,
                                                  unresolvable from its RUNPATH
```

`dlopenSonamesRuntimeVersioned` is keyed by object now, and the staleness
assertion asks whether *that* object still names the spelling. Second spellings
keep a payload-wide table, because their substitution is already gated per
object by the literal test — declaring what is verified would add bookkeeping
without adding a guarantee.

**A WAIVER INHERITED WITHOUT EVIDENCE.** `libcurl.so` inherits the waiver
written for `libcurl.so.4`, which is right when the object treats them as one
library and wrong when it does not. The inheritance had no gate, so the
mapped-literal rule the fallback had gained in rounds 7–9 did not apply here. An
object linking the exact soname — `.dynstr` only — while probing the generic
spelling, with the waiver declared for it:

```
round-11 check                       round-12 check
  (no finding)                         FAIL  libnotify.so    named by lib/…/libwv.so,
                                             unresolvable from its RUNPATH
                                       FAIL  libnotify.so.4  stale waiver:
                                             lib/…/libwv.so no longer names it
```

Both halves are right. The probe is unresolvable and no longer excused; and the
waiver is stale, because an object that *links* a library is not an object that
probes for one we declined to provide — the build resolved it. Waiver staleness
now takes the same literal evidence for the same reason.

**A DECLARATION HONOURED ON A DEAD STRING.** "This object composes the ABI
version at runtime" is a statement about a live call site. It was being applied
to any scanned occurrence of the prefix, and kept alive by any occurrence too —
so a build that stopped composing the soname, while the prefix survived in debug
metadata, would have passed every assertion and gone on satisfying the
`libva.so.2` reference on nothing's behalf. An object whose only `libva.so` is
in a `noload` section, with `libva.so.2` on its RUNPATH and the declaration
made for it:

```
round-12 check                                    round-13 check
  ok  libva.so  stands for libva.so.2 in            FAIL  libva.so  declared in lib/…/libvartv.so as
      lib/…/libvartv.so (version appended)                composing its version, but no longer a
                                                          live literal there
                                                    FAIL  libva.so  stale spelling: lib/…/libvartv.so
                                                          no longer names it as a live literal
```

Reported from both sides on purpose: the substitution is refused, and the
declaration is called stale. The real `libva.so` and `libva-drm.so` in the main
executable are `.rodata` literals, so nothing about the shipped payload changes.

**AND THE PLAINEST PATH OF ALL.** The provided sonames — the original list, the
thing the guard was built around — still had their reference assertion satisfied
by any occurrence of the string. A probe removed upstream while the name stayed
in `DT_NEEDED` or in debug metadata would leave the entry looking current, with
`runtimeLibs` keeping it resolvable, so every assertion stayed green over a dead
declaration. An object whose only `libkrb5.so.3` is in a `noload` section, with
krb5 on its RUNPATH and the soname added to `dlopenSonames`:

```
round-13 check                                round-14 check
  ok  libkrb5.so.3  -> …-krb5-1.22.2-lib/lib    ok    libkrb5.so.3  -> …-krb5-1.22.2-lib/lib
  ok  libkrb5.so.3  named by lib/…/libprov.so   FAIL  libkrb5.so.3  no longer a live literal
                                                      in any shipped ELF
```

The resolve assertion passes in both — the library really is in the closure.
Only the reference assertion tells the truth about whether anything still asks
for it.

With this the same evidence rule covers every assertion and every table:
provided sonames, waivers, both spelling tables, in both the per-object and the
payload-wide direction. All twenty-two provided entries and all six second
spellings pass it unchanged, which is the point — they are genuine `.rodata`
probe literals, and the rule exists to require that they stay so.

All twenty-one print the same guidance block before exiting, which names the fix
for each failure mode:

```
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
```

### 4. Positive test — PASSES on HEAD (verbatim)

Abridged only where marked; the resolve block is 24 consecutive `ok` lines of
the same shape.

```
scanned 14 ELF objects, 93 distinct soname strings

== resolve: provided sonames, from the main executable's RUNPATH
  ok      libsecret-1.so.0           -> /nix/store/xplgg6bnv5zglgrf3djibil77nr7b7qm-libsecret-0.21.7/lib
  ok      libnotify.so.4             -> /nix/store/c4cad93fv7d0gzcvsjpqp5l8kw092ypi-libnotify-0.8.8/lib
  ok      libgdk-3.so.0              -> /nix/store/sfipg5lg6yrzvhh4lafialb5sqnk5pvx-gtk+3-3.24.52/lib
  ok      libvulkan.so.1             -> /nix/store/6nhncb2xssshqrfx20nydgvbcs5h4j19-claude-desktop-1.24012.9/lib/claude-desktop
  ok      libnssckbi.so              -> /nix/store/s0h8ra4wcl1nbxracs4hm4qc6czllx6y-nss-3.112.5/lib
  [17 further ok lines elided]
  ok      libuuid.so.1               -> /nix/store/m4q3a226wx3qjd3yrmwv2q0rzsjqf5zg-util-linux-2.42.2-lib/lib
  ok      libXtst.so.6               -> /nix/store/sn84f2wa25q1f0qvq2c1x5sbr6gp8qgy-libxtst-1.2.5/lib

== reachability: each named soname resolves from the RUNPATH of the object naming it
  ok      37 (object, soname) pairs resolve; 113 exempt (own soname, that object's DT_NEEDED, or waived for that object)

== reference: provided sonames are still named by the payload
  ok      libsecret-1.so.0           named by lib/claude-desktop/claude-desktop
  ok      libgdk-3.so.0              named by lib/claude-desktop/claude-desktop
  ok      libva.so.2                 named as libva.so (ABI version appended at runtime)
  ok      libva-drm.so.2             named as libva-drm.so (ABI version appended at runtime)
  ok      libnssckbi.so              named by lib/claude-desktop/claude-desktop
  [17 further ok lines elided]
  n/a     libuuid.so.1               Depends-only, not expected in the scan
  n/a     libXtst.so.6               Depends-only, not expected in the scan

== reference: waivers are still named by the object they were written for
  ok      libnotify.so.1             still named by lib/claude-desktop/claude-desktop
  ok      libcurl.so.4               still named by lib/claude-desktop/chrome_crashpad_handler
  [23 further ok lines elided]

== reference: declared spellings are still named by the payload
  ok      libva.so                   stands for libva.so.2 (version appended at runtime)
  ok      libGL.so                   stands for libGL.so.1 (second spelling)
  [6 further ok lines elided]

== novelty: every soname string is classified
  ok      all 93 classified (DT_NEEDED, bundled, provided, waived, or a declared spelling)
```

24/24 resolve, 37 (object, soname) pairs reachable, 22/22 provided sonames,
25/25 waivers and 8/8 declared spellings still named, 93/93 classified. `nix flake check` passes with both
checks built.

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

### GAP — closed, and the one inference that remains

The original gap was that the workflow had never executed: the repo had no git
remote, so "a bump fails loudly" rested entirely on a local exit code plus
Actions' documented gating semantics. **That is closed.** The repo has a remote,
and the updater has now run end to end on a real bump once per revision of the
guard — `30801047214` (pre-review), `30804260785` (first rewrite),
`30805384864` (per-object `DT_NEEDED`), `30806151997` (object-scoped waivers
and the spelling table), `30806981647` (the spelling split and `$ORIGIN`
expansion), `30807553403` (mapped-soname resolution and the symlink-aware
bundled inventory), `30808111140` (whitespace-safe object paths and the
per-object spelling fallback), `30808676346` (linkage metadata excluded from
that fallback), `30809133986` (that exclusion decided by offset rather than by
name), `30809740850` (evidence narrowed to mapped segments), `30810420891`
(the string table located through `PT_DYNAMIC`), `30810940553`
(runtime-versioned spellings scoped to the composing object), `30811371458`
(waiver inheritance gated on literal evidence) and `30811830842` (the
runtime-versioned declaration gated on the same, i.e. what is in the tree). Each was a
`workflow_dispatch` from a branch with `sources.json` pinned one release back,
which is the only way to exercise the bump path on demand — without a pin there
is nothing to bump and every gated step skips. The last one:

```
Bump sources.json      version=1.24012.9
                       changed=true
Build the new version  success
Guard - dlopen'd libraries still resolve from RUNPATH
                       claude-desktop-dlopen-runpath> scanned 14 ELF objects, 93 distinct soname strings
                       claude-desktop-dlopen-runpath> == resolve: provided sonames, from the main executable's RUNPATH
                       claude-desktop-dlopen-runpath> == reachability: each named soname resolves from the RUNPATH of the object naming it
                       claude-desktop-dlopen-runpath>   ok  37 (object, soname) pairs resolve; 113 exempt
                       claude-desktop-dlopen-runpath> == reference: provided sonames are still named by the payload
                       claude-desktop-dlopen-runpath> == reference: waivers are still named by the object they were written for
                       claude-desktop-dlopen-runpath> == reference: declared spellings are still named by the payload
                       claude-desktop-dlopen-runpath> == novelty: every soname string is classified
                       claude-desktop-dlopen-runpath>   ok  all 93 classified (DT_NEEDED, bundled, provided, waived, or a declared spelling)
Run flake checks       success
Open pull request      pull-request-operation = none
```

So the gated steps do run in order on a real bump, and the guard executes
against a freshly built package in CI rather than only on this laptop — the
scan included, on a runner that had never seen this store path. One footnote:
`pull-request-operation = none` in both runs because the pinned branch bumped
back to the version `dev` already carried, so there was nothing to open a PR
about. The pin branch was deleted after the run.

**What remains an inference:** no CI run has yet had the guard *fail*, so "a
failing guard blocks PR creation" is still read off `if:` semantics rather than
observed. Every element of it has been measured separately — the check exits
`1` (three ways, above), the step is not `continue-on-error`, and every later
step carries an `if:` that Actions ANDs with an implicit `success()` — but the
composition has not been watched end to end. Forcing that would mean landing a
deliberately broken guard on `dev` to watch a scheduled run go red, which costs
more than it proves.

---

## D4 — tray — DONE

### Verdict

**Nothing in this package or its closure explains the behaviour. Which
component *does* own it was not established.**

What the evidence below supports:

- the tray item registers with the watcher and is live, alongside working
  applets — so this is not a packaging failure;
- the closure is not missing an appindicator library. Electron 42 /
  Chromium 148 uses its own native SNI and needs none; `libdbusmenu-glib` is
  present, so the menu path is provisioned;
- the app advertises `ItemIsMenu = false` — it does not declare itself
  menu-only — and an `Activate` call against its object returns success.

What it does **not** support, and the original verdict asserted anyway: that
the SNI host owns the behaviour. `Activate` returning `0` proves the method
exists and did not error; it does not prove the app raises the window rather
than opening a menu or doing nothing, because nobody watched the screen while
that call was made. No real left click was ever traced either, so neither
waybar nor upstream Claude is excluded. Naming waybar would have pointed the
next debugging session at a component that may have nothing to do with it.

**What would settle it:** watch the session bus during a genuine left click —
`dbus-monitor` filtered on the item's object path — and record whether the host
emits `Activate`, `ContextMenu`, or nothing, then what the app does in
response. That measurement was never taken; driving a GUI click was out of
scope for this phase.

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

**3. It advertises left-click activation, and the method is callable:**

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

### Where the evidence stops

`ItemIsMenu = false` proves **what the application advertises**, not **what the
host honours**. A host is free to bind left-click to the context menu
regardless of that property, and nothing in the SNI spec compels it to call
`Activate`. So the evidence rules out "the app declared itself menu-only" and
"the app has no `Activate`" as explanations; it does not establish what waybar
actually does on click, nor what the app does when `Activate` arrives.

Related limit: **no actual left-click was ever observed.** The reported
behaviour ("clicking the tray icon opens a context menu") is your observation,
not something reproduced here. Waybar's tray config being default narrows where
a click mapping *could* come from, but "default config" is not a trace.

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

1. ~~**D3 requirement 5 — the updater guard has never run in CI.**~~ **Closed.**
   The repo has a remote and the updater has run end to end on a real bump
   (run `30801047214`), guard step included and green. What is still an
   inference rather than an observation is that a *failing* guard blocks PR
   creation — see the D3 gap section for exactly which parts were measured.
2. **`suidSandbox = true` has never been runtime-tested.** B3's variant was
   verified only structurally (bundled helper absent, `CHROME_DEVEL_SANDBOX`
   set in the wrapper, builds clean). No host without a usable namespace
   sandbox was available, so it has never actually launched. The mechanism it
   relies on *was* measured directly (`setuid_sandbox_host.cc:166` vs `:156`),
   but end-to-end it is unproven.
3. **The leaked Chrome Safe Storage key is still in the transcript.** Not
   deleted, per instruction. It is **Google Chrome's** OSCrypt key
   (`application=chrome`), not Claude Desktop's (`application=Claude`) — the
   original stated that as a bare assertion and review rightly challenged it;
   the measurement is now under D1, *"Which key it is"*. Rotate it anyway: it
   decrypts Chrome's own cookie and password stores on this host. Rotating
   means deleting that keyring item — Chrome mints a fresh key on next launch,
   and anything sealed with the old one stops being readable.
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
9. ~~**`PHASE-D-REPORT.md` is untracked**~~ **Closed** by `bc1b793`, which
   committed this file (sanitized) as part of PR #1.
10. ~~**The rewritten D3 guard has not itself run in CI yet.**~~ **Closed** by
    run `30811830842`: the version now in the tree ran on a real bump on a
    clean runner and passed, reporting the same 37 reachable pairs and 93
    classified sonames as it does locally. What has still never been observed
    in CI is the guard *failing* — see the D3 gap section for which parts of
    that are measured and which are inferred.

Phase C is **closed, not a gap**: you selected option 2 (one `/goal` per
phase), so the proposed goal-text change was never needed and no hook config
was touched.

---

## Commits

SHAs are the ones on `dev` (the earlier draft of this table quoted pre-rebase
hashes that no longer exist).

| SHA | What landed |
| --- | --- |
| `0652904` | **Phase B.** Confirmed v11 keyring path (B0); removed the empty `LD_LIBRARY_PATH` element, then dropped the variable entirely in favour of `DT_RUNPATH` via `appendRunpaths` (B2a/B2b); added the `suidSandbox` option with the default output unchanged (B3); `set -euo pipefail` in every workflow `run:` block, closing the `\| tee` swallow (B5); README on the Secret Service requirement and Cowork's real state (B1/B4). |
| `687cbd7` | **Phase D.** Added `checks.dlopen-runpath` with the soname list in `passthru.dlopenSonames`, wired it into the updater as its own named step (D3); documented profile snapshotting and the throwaway `XDG_CONFIG_HOME` test invocation in the README (D2). |
| `bc1b793` | This report, sanitized. |
| *(this commit)* | **Review response.** Rewrote the D3 guard around a scan of the shipped ELFs — resolve, reference and novelty assertions — in `pkgs/dlopen-runpath.nix`; split the soname list into provided / Depends-only / deliberately-unprovided; corrected the D4 verdict and this report's D3 and gap-3 claims. |
| `a769a22` | *(Phase 0–2, for context.)* Initial packaging of the official Linux `.deb`: derivation, FHS variant, overlay, daily updater workflow. |

D1 and D4 produced no code commits — both were investigations.
