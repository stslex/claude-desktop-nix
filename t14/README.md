# T1.4 — Cowork live-test harness

Manual test for `packages.claude-desktop-cowork`. Nothing here is referenced by
the flake, built by `nix flake check`, or run in CI: it needs a GUI, a sign-in
and a 1.24 GiB download from `downloads.claude.ai`, so it cannot be a check. It
lives in the repo because it has to be re-run by hand after any upstream bump
that touches Cowork's support probe or its VM helper.

**Disk space — budget ~15 GB before running this.** See "Isolation and cleanup"
below; the throwaway profile is not small.

## Precondition — quit Claude Desktop from the tray first

The Cowork helper socket is `$XDG_RUNTIME_DIR/claude-cowork-vm.sock`, and it is
*not* covered by the throwaway `XDG_CONFIG_HOME` the harness sets up. If any
Claude Desktop is already running, its `cowork-linux-helper` — a different
binary from a different build — owns that path, and a second instance talks to
that helper instead of its own. The test would then be measuring the wrong
process.

`t14-run.sh` refuses to start in that situation rather than producing a
misleading result. Quitting from the tray (not closing the window) is what
releases the socket; check with:

```bash
# expect no output
ls -l /proc/*/exe 2>/dev/null | grep -E 'claude-desktop|cowork-linux-helper'
```

Not `pgrep -f`. This checkout is itself named `claude-desktop-nix`, so any
process whose command line merely *mentions* the directory — your editor, a
`grep`, the shell running the check — matches the pattern and is reported as a
running Claude Desktop. That cost four false readings in one session. Matching
`/proc/PID/exe` asks what binary is actually executing, which is also immune to
`comm`'s 15-character truncation and to nixpkgs' `.foo-wrapped` indirection.

## The files

| file | what it does |
| --- | --- |
| `t14-run.sh` | Builds `.#claude-desktop-cowork` and launches it against a throwaway profile. Refuses to run alongside another Claude Desktop or an orphaned helper. |
| `t14-evidence.sh` | Watches for a Cowork VM for up to 15 minutes, then writes a report proving it either did or did not boot. Safe to start before or after the app. |
| `fhs-boot-probe.nix` | Optional. Boots a QEMU from the same pieces the sandbox carries — the trimmed QEMU, the OVMF pair, a real virtiofsd — with no Claude Desktop involved, to tell a sandbox failure from an app failure. |

## Running it

```bash
./t14/t14-evidence.sh   # terminal A — collector, waits for a VM
./t14/t14-run.sh        # terminal B — the app
```

Then sign in and open Cowork in the GUI. The bootable disk is not in the `.deb`;
expect a **1.24 GiB** `rootfs.img.zst` to download into the throwaway profile on
first use, decompressing to a 10 GiB sparse `rootfs.img` alongside a 10 GiB
sparse `sessiondata.img` created locally. Measured: **~13 GB actually occupied**,
~23 GB apparent.

The report is written to `/tmp/cowork-t14-evidence.txt` — deliberately *beside*
the throwaway profile rather than inside it, so that `rm -rf /tmp/cowork-t14`
does not delete the evidence the run was performed to produce. Override with
`COWORK_TEST_REPORT`.

**What counts as success.** Not the feature gate opening — a QEMU process
carrying a `vhost-vsock-pci` device, holding `anon_inode:kvm-vcpu:*` fds, with a
live `virtiofsd` behind it. The collector discriminates on `vhost-vsock-pci`
specifically so that an Android-emulator `qemu-system-x86_64`, which never uses
one, is not reported as a pass.

That discriminator does not separate the collector from `fhs-boot-probe.nix`,
though, which boots a QEMU with a `vhost-vsock-pci` device of its own — and this
file recommends running it for the same session. Measured: with the probe's
guest alive, the original matcher returned its pid and would have written
`VM FOUND` for a VM that was never Cowork's. The probe therefore names itself
(`-name cowork-boot-probe`) and the collector declines any process carrying that
marker, so the two are safe to run together. The report also prints the parent
of whichever QEMU it found: a real Cowork VM is forked by
`cowork-linux-helper`, and anything else named there means the argv matched for
the wrong reason.

## Sign-in opens a browser, and the browser has to be yours

`t14-run.sh` resolves the host's default browser to an absolute path and seeds
the throwaway `mimeapps.list` with it before starting the app. That is not
tidiness — without it the test cannot be completed at all.

Redirecting `XDG_CONFIG_HOME` moves the whole desktop-integration context, not
just the app's profile. The throwaway config has no http/https association, so
`xdg-open` inside the sandbox cannot find the browser you use and falls back to
the first application registered for the scheme — launching it with the
throwaway XDG dirs too, i.e. with an empty browser profile. Sign-in is an OAuth
round trip through the system browser and only completes in a browser already
signed in to the identity provider, so it fails there every time. Measured on
2026-08-18: four attempts, four silent failures, and nothing in either log
naming the cause.

Naming the host's `.desktop` file would not have been enough either. This host's
`zen.desktop` carries `Exec=zen --name zen %U` — a bare name resolved through
PATH, and PATH inside the FHS sandbox is the sandbox's own, where no browser
exists. That is exactly why the fallback had picked a chromium: its entry
happened to carry an absolute store path.

The other half of the round trip is on the host. The callback is a `claude://`
deep link, and the browser resolves it through *your* desktop entries — which
point at your normally installed Claude Desktop and its real profile, not at the
instance under test. Handling that requires a temporary handler in
`~/.local/share/applications`, which is outside this harness's blast radius and
so is deliberately not automated: `rm -rf $ROOT` must remain the whole cleanup.
Install one by hand if you need the callback to land in the test instance, and
remember to remove it, or complete the sign-in and accept that the deep link
opened your real app.

## Isolation and cleanup

`t14-run.sh` redirects `XDG_{CONFIG,CACHE,DATA,STATE}_HOME` under
`/tmp/cowork-t14`. Your real `~/.config/Claude` is never read or written, and
`rm -rf /tmp/cowork-t14` undoes the whole test. Override the location with
`COWORK_TEST_ROOT`, the repo with `COWORK_REPO`, and the collector's deadline
with `COWORK_TEST_DEADLINE`.

That directory reaches **~13 GB** once a VM has booted, so `/tmp` must be real
disk. On a host where `/tmp` is a tmpfs, or is size-capped, set
`COWORK_TEST_ROOT` somewhere else rather than discovering the limit halfway
through a 1.24 GiB download. Clean up with:

```bash
rm -rf /tmp/cowork-t14      # or "$COWORK_TEST_ROOT"
```

Quit the app first — deleting the profile under a running VM leaves QEMU writing
into unlinked files.

The boot probe carries the same trimmed QEMU `claude-desktop-cowork` ships —
`flake.nix` pins `leanQemu = true`, and the probe reads it back off
`passthru.qemu` rather than reaching for `pkgs.qemu_kvm`. Booting the cached
full QEMU would have answered a question nobody asked: a trim that dropped a
device the helper needs would still show 3/3 while the app could not start a VM
at all, which is the one confusion this probe exists to prevent.

It is impure and evaluates the flake from this checkout:

```bash
nix build --no-link --print-out-paths --impure --file t14/fhs-boot-probe.nix
```

then run `<result>/bin/cowork-boot-probe`. If it passes and the app still cannot
start a VM, the fault is in the app or the gate; if it fails, the fault is in
the sandbox, the OVMF pair or the host.

## Host prerequisite

`/dev/vhost-vsock` is a static device node that demand-loads `vhost_vsock` on
first open, so the happy path works without configuration. It is still worth
loading the module at boot:

```nix
boot.kernelModules = [ "vhost_vsock" ];
```

If the demand-load ever fails, the app falls back to checking
`/lib/modules/$(uname -r)` — a path that does not exist on NixOS at all, since
modules live under `/run/booted-system/kernel-modules/lib/modules/`. The
`access()` therefore always throws `ENOENT` and the app reports
`vhost_vsock_kernel_unsupported`, blaming the kernel for a module that is
present on disk. Loading it at boot makes that branch unreachable. See the
Cowork section of the top-level `README.md`.
