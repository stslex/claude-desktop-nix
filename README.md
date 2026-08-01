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

## Dependency provenance

`buildInputs` is derived from an `ldd` sweep of every ELF object in the `.deb`,
not copied from another package. `auto-patchelf: 0 dependencies could not be
satisfied` on a clean build.

The subtlety is that **`ldd` is not sufficient by itself**. Four libraries in
upstream's `Depends` appear in no `DT_NEEDED` entry at all, and a further dozen
are `dlopen`ed. `autoPatchelfHook` cannot see any of these; they are injected via
`LD_LIBRARY_PATH` in the wrapper (see `runtimeLibs` in
`pkgs/claude-desktop.nix`). Notably `libsecret-1.so.0` — miss it and credential
storage silently degrades with no build-time error.

`resources/virtiofsd` needs `libseccomp.so.2` + `libcap-ng.so.0` and
`node-pty`'s `pty.node` needs `libstdc++.so.6`; both are in `buildInputs` so
autopatchelf stays clean, but neither is wired into any feature here — Cowork
and KVM plumbing is out of scope.

## Updating

`pkgs/update.sh` parses the APT index, picks the newest version, prefetches it,
**cross-checks the download hash against the SHA256 the signed index
advertises**, and rewrites `sources.json`. A divergence is a hard failure.

`.github/workflows/update.yml` runs it daily and on demand. It opens a PR only
after `nix build .#default` and `nix flake check` both pass — a version that
bumps cleanly but builds broken fails the workflow instead of producing a red PR.

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

## Licence

The packaging in this repository is MIT. Claude Desktop itself is proprietary —
`meta.license = lib.licenses.unfree`, `meta.sourceProvenance =
[ lib.sourceTypes.binaryNativeCode ]`. See
`$out/share/doc/claude-desktop/copyright`.
