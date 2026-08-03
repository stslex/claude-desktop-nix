# claude-desktop-nix

Anthropic's first-party **Claude Desktop for Linux**, packaged for Nix from the
official `.deb` at `downloads.claude.ai`.

This is a native Linux build. Nothing is patched, spoofed, transcoded, or
emulated — the derivation unpacks upstream's payload, resolves its shared
libraries, and wraps the binary. There is no `app.asar` rewriting, no platform
spoofing, and no macOS artifact anywhere in the pipeline.

```console
$ nix run github:<you>/claude-desktop-nix
```

## Outputs

| Output | What it is |
| --- | --- |
| `packages.default` / `packages.claude-desktop` | The app. Use this one. |
| `packages.claude-desktop-fhs` | Same app inside a `buildFHSEnv` that provides `npx`, `uvx`, `docker`, `git`, `python3` at conventional FHS paths, so published MCP server configs work unmodified. |
| `overlays.default` | Adds `claude-desktop` and `claude-desktop-fhs` to a nixpkgs instance. |
| `checks.wrapper-flags` | Asserts the wrapper keeps its flags, never gains `--no-sandbox`, ships `chrome-sandbox`, and has a valid desktop entry with rewritten `Exec=` lines. |
| `checks.dlopen-runpath` | Scans every shipped ELF for soname strings and asserts that each library this package provides resolves from the RUNPATH of every object naming it, that nothing on the lists has stopped being named, and that nothing *new* is named without being classified. See [Dependency provenance](#dependency-provenance). |

### NixOS

```nix
{
  inputs.claude-desktop-nix.url = "github:<you>/claude-desktop-nix";

  # …
  nixpkgs.overlays = [ inputs.claude-desktop-nix.overlays.default ];
  environment.systemPackages = [ pkgs.claude-desktop ];
  nixpkgs.config.allowUnfree = true; # or allowUnfreePredicate for just this
}
```

## The sandbox

**This package does not pass `--no-sandbox`, and you should not add it.**

Upstream's `.deb` ships `chrome-sandbox` setuid root (4755) as a *fallback* for
Ubuntu 24.04+, where `kernel.apparmor_restrict_unprivileged_userns=1` blocks
`CLONE_NEWUSER` — their `postinst` installs an AppArmor `flags=(unconfined)`
profile as the primary fix and calls the SUID helper "belt-and-suspenders".

Nix strips setuid bits from store paths unconditionally, so `chrome-sandbox`
lands here as a plain `0555` binary. That is fine. Chromium only consults the
SUID helper when the namespace sandbox is unavailable — `ZygoteHostImpl::Init`
computes `using_suid_sandbox` as *"SUID path non-empty **and** namespace sandbox
unsupported"* — and NixOS neither restricts unprivileged user namespaces nor
ships an AppArmor userns policy. The namespace sandbox is always taken and the
helper's mode is never examined.

Verified on a live run: renderer processes carry `--enable-sandbox` and sit in a
different user namespace from the browser process.

```console
$ pgrep -af 'claude-desktop --type=renderer' | head -1     # → --enable-sandbox
$ readlink /proc/<browser>/ns/user                          # → user:[4026531837]
$ readlink /proc/<renderer>/ns/user                         # → user:[4026534073]
```

If you have deliberately set `user.max_user_namespaces = 0`, restore it rather
than disabling the sandbox.

### Hosts that cannot use the namespace sandbox

On a hardened kernel, with `security.allowUserNamespaces = false`, or under an
AppArmor userns restriction, the default output does not silently run
unsandboxed — it **aborts**:

```
FATAL:sandbox/linux/suid/client/setuid_sandbox_host.cc:166]
  The SUID sandbox helper binary was found, but is not configured correctly …
  owned by root and has mode 4755
```

For those hosts there is an opt-in variant:

```nix
pkgs.claude-desktop.override { suidSandbox = true; }   # pairs with:
security.chromiumSuidSandbox.enable = true;            # provides /run/wrappers/bin/chrome-sandbox
```

**Both halves are required.** The variant deletes the bundled `chrome-sandbox`
and sets `CHROME_DEVEL_SANDBOX=/run/wrappers/bin/chrome-sandbox`. Deleting it is
mandatory, not cosmetic: Chromium reads `CHROME_DEVEL_SANDBOX` **only** when no
`chrome-sandbox` sits beside the executable. Measured directly — with the
bundled helper present the error comes from `setuid_sandbox_host.cc:166` and
names the store path (env var ignored); with it removed the error comes from
line `156` and names `$CHROME_DEVEL_SANDBOX`. Setting the variable alone does
nothing at all.

The default output is unchanged by this option, and still never passes
`--no-sandbox`.

## `--password-store`

Defaults to `gnome-libsecret`, not `detect`. The bundled binary supports exactly
two real backends — libsecret (`dlopen` of `libsecret-1.so.0`) and KWallet (pure
D-Bus) — plus `basic`, which stores your session token **in plaintext**.

`detect` keys off `XDG_CURRENT_DESKTOP`. On GNOME and KDE it picks correctly,
but on wlroots compositors (sway, niri, Hyprland, river) it matches nothing and
silently degrades to `basic`. `gnome-libsecret` instead talks to whatever
implements the freedesktop Secret Service API — gnome-keyring, KeePassXC, or
KWallet's secret-service bridge — so it works there too, and when no Secret
Service is running Chromium falls back to `basic` on its own, i.e. exactly where
`detect` would have landed. The default is never worse and frequently better.

KDE users running kwalletd without the secret-service bridge:

```nix
pkgs.claude-desktop.override { passwordStore = "kwallet6"; }
```

### You must actually run a Secret Service provider

This is a **host configuration requirement, not something the package can
provide**. `gnome-libsecret` needs something owning `org.freedesktop.secrets`
on the session bus. Without it Chromium falls back to a key derived from a
hardcoded constant — still ciphertext, but decryptable by anyone with the file.

NixOS:

```nix
services.gnome.gnome-keyring.enable = true;
# and, so the keyring unlocks at login instead of prompting:
security.pam.services.login.enableGnomeKeyring = true;
```

home-manager: `services.gnome-keyring.enable = true;`. KeePassXC with "Secret
Service Integration" enabled also satisfies this.

Verify it is live, and — more importantly — verify the *result*:

```bash
busctl --user list | grep org.freedesktop.secrets      # must be owned

cp ~/.config/Claude/Cookies /tmp/c
sqlite3 /tmp/c "select name, hex(substr(encrypted_value,1,3)) \
  from cookies where name like 'sessionKey%'"
```

`763131` is ASCII **`v11`** — key came from the secret service. `763130`
(**`v10`**) means libsecret was never reached and the encryption is
obfuscation only. Checking that the value is merely "encrypted" does not
distinguish the two; only the version tag does.

Measured on this package: `sessionKey` and `sessionKeyLC` both `763131`.

## Dependency provenance

`buildInputs` is derived from an `ldd` sweep of every ELF object in the `.deb`,
not copied from another package. `auto-patchelf: 0 dependencies could not be
satisfied` on a clean build.

The subtlety is that **`ldd` is not sufficient by itself**. Four libraries in
upstream's `Depends` appear in no `DT_NEEDED` entry at all, and a further dozen
are `dlopen`ed. `autoPatchelfHook` cannot discover any of these; they are named
explicitly in `runtimeLibs` and appended to the **`DT_RUNPATH`** of every
bundled ELF via the hook's `appendRunpaths`. Notably `libsecret-1.so.0` — miss
it and credential storage silently degrades with no build-time error.

**Why RUNPATH and not `LD_LIBRARY_PATH`.** `dlopen()` resolves against the
calling object's own `DT_RUNPATH`, so the app finds these either way — but
`LD_LIBRARY_PATH` is inherited by every child process, and it is searched
*ahead of* a child's own `DT_RUNPATH`. The app spawns MCP servers, an
integrated terminal and `cowork-linux-helper`; exporting the variable made
those children prefer this package's `krb5` / `util-linux` / `libx11` over the
versions they were linked against. RUNPATH is a property of the file, not the
environment, so it does not leak. Verified: `libsecret-1.so.0` is mapped into
the browser process with no `LD_LIBRARY_PATH` set at all.

Note if you ever add to this: `autoPatchelfHook` registers itself in
`postFixupHooks` and therefore runs **after** `postFixup`, calling
`--set-rpath`. Hand-rolled `patchelf --add-rpath` in `postFixup` is silently
discarded — use `appendRunpaths`.

`resources/virtiofsd` needs `libseccomp.so.2` + `libcap-ng.so.0` and
`node-pty`'s `pty.node` needs `libstdc++.so.6`; both are in `buildInputs` so
autopatchelf stays clean, but neither is wired into any feature here — Cowork
and KVM plumbing is out of scope.

**How this list is kept honest across upstream bumps.**
`checks.dlopen-runpath` re-derives the picture from the binary on every run
instead of trusting the hand-written list. It scans every shipped ELF for
soname-shaped strings, then requires each string to be accounted for as
`DT_NEEDED`, bundled with the app, provided by us (`passthru.dlopenSonames`),
or waived with a reason (`passthru.dlopenSonamesUnprovided`) — and requires
every `(object, soname)` pair to resolve from *that object's* RUNPATH, not
merely from the main executable's. Both halves of that are per-object: being
`DT_NEEDED` of one object says nothing about whether another can reach it, and
a waiver ("crashpad probes for libcurl and we ship no crash server") is a claim
about one binary, so the same soname named by another one is a fresh decision
rather than a free pass.

So a bump that starts `dlopen`ing something new fails the check with that
soname named, rather than shipping a feature that silently does nothing; a bump
that stops using one fails too, waivers included, so no entry can rot into an
assertion that passes while testing nothing. It is a string scan, so it cannot
see a soname assembled at runtime — `libva` is the live case, and why
`passthru.dlopenSonamesRuntimeVersioned` declares `libva.so` as the spelling
that stands for `libva.so.2`. Only those may substitute: the six entries in
`dlopenSonamesSecondSpellings` are spellings the binary carries *beside* the
exact soname, so they classify the string but never prove the exact one is
still there. It reads ELF objects only, nothing inside `app.asar`, and it
expands `$ORIGIN` per object the way the loader does rather than testing it as
a literal path.

## Updating

`pkgs/update.sh` parses the APT index, picks the newest version, prefetches it,
**cross-checks the download hash against the SHA256 the signed index
advertises**, and rewrites `sources.json`. A divergence is a hard failure.

`.github/workflows/update.yml` runs it daily and on demand. It opens a PR only
after `nix build .#default` and `nix flake check` both pass — a version that
bumps cleanly but builds broken fails the workflow instead of producing a red PR.

## Testing this package without touching your profile

Claude Desktop keeps everything under `$XDG_CONFIG_HOME/Claude`. A test launch
against your real profile rewrites cookies (including `cf_clearance` /
`__cf_bm`) and rotates state, which makes a later v10/v11 check ambiguous — you
can no longer tell whether a tag came from the build you are testing or from a
previous run.

**Snapshot first** if you are about to touch the real profile:

```bash
cp -a ~/.config/Claude ~/.config/Claude.bak-$(date -u +%Y%m%dT%H%M%SZ)
# or, compressed:
tar -C ~/.config -czf ~/claude-profile-$(date -u +%Y%m%dT%H%M%SZ).tar.gz Claude
```

**Better: never touch it.** Run every test launch against throwaway XDG dirs:

```bash
CDTEST=$(mktemp -d)
XDG_CONFIG_HOME="$CDTEST/config" \
XDG_CACHE_HOME="$CDTEST/cache" \
XDG_DATA_HOME="$CDTEST/data" \
  "$(nix build .#default --no-link --print-out-paths)"/bin/claude-desktop \
    --enable-logging=stderr
```

Verified isolating: after a launch this way the real `~/.config/Claude/Cookies`
is byte-identical (`sha256sum -c` passes, mtime unchanged) while
`$CDTEST/config/Claude` is created and populated.

Two practical notes. Use the store path rather than `./result` — any other
`nix build` (a `.#checks.…` invocation, say) repoints that symlink and you will
launch the wrong thing, or get exit 126. And a throwaway profile is logged out,
so it is the right tool for testing startup, library resolution and the
sandbox, but not for a v10/v11 check, which needs a real authenticated session.

## Known issues

**`Failed to create file "/nix/store/…-mimeapps.list.XXXXXX": Read-only file
system`** on startup. Not a packaging bug — the app is trying to register itself
as the `x-scheme-handler/claude` handler, and your `~/.config/mimeapps.list` is a
symlink into the store (home-manager's `xdg.mimeApps`). Register it declaratively
instead:

```nix
xdg.mimeApps.defaultApplications."x-scheme-handler/claude" =
  "com.anthropic.Claude.desktop";
```

**`claude-desktop-fhs` and nested namespaces.** `buildFHSEnv` is itself a
bubblewrap user namespace and Chromium nests its own sandbox inside it. Verified
working on a stock NixOS kernel (renderers land in their own user namespace
inside the bwrap one); if your kernel forbids nested user namespaces this variant
will not start. The fix is the kernel setting — this package will not add `--no-sandbox`
to paper over it. Use `packages.default` if you do not need MCP subprocess
tooling.

## Not implemented

- **aarch64.** Upstream publishes `arm64` debs at parity with `amd64` in the same
  pool. Adding it needs a second `sources.json` entry plus an updater that only
  bumps when both arches carry the same version. Deliberately left out of v1;
  see the `TODO(arm64)` markers.
- **Cowork / KVM / Computer Use.** The `.deb` ships `virtiofsd`,
  `cowork-linux-helper` and a 27 MB `smol-bin.x64.img`; none of it is wired up.
  The app reports `computerUse: unsupported_platform` on Linux regardless.

  **Cowork cannot start**, and that is by design here: the VM path requires
  `qemuPath`, `firmwarePath` (OVMF) *and* `virtiofsd`, and neither qemu nor
  OVMF is anywhere in this package's closure (`nix path-info -r … | grep -c
  qemu` → `0`). `virtiofsd` is present only so `autoPatchelfHook` resolves its
  `libseccomp` / `libcap-ng` and the build stays clean. Opening the Cowork tab
  shows upstream's own message — *"requires QEMU. Install it with
  `{installCommand}`, then restart Claude"* — where `{installCommand}` is an
  **`apt` command that is wrong and unactionable on NixOS**. This is cosmetic;
  nothing is broken by it.

## Licence

The packaging in this repository is MIT. Claude Desktop itself is proprietary —
`meta.license = lib.licenses.unfree`, `meta.sourceProvenance =
[ lib.sourceTypes.binaryNativeCode ]`. See
`$out/share/doc/claude-desktop/copyright`.
