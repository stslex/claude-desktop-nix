# T1.4 — Cowork live-test harness

Manual test for `packages.claude-desktop-cowork`. Nothing here is referenced by
the flake, built by `nix flake check`, or run in CI: it needs a GUI, a sign-in
and a ~27 MB download from `downloads.claude.ai`, so it cannot be a check. It
lives in the repo because it has to be re-run by hand after any upstream bump
that touches Cowork's support probe or its VM helper.

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
pgrep -af 'claude-desktop|cowork-linux-helper'   # expect no output
```

## The files

| file | what it does |
| --- | --- |
| `t14-run.sh` | Builds `.#claude-desktop-cowork` and launches it against a throwaway profile. Refuses to run alongside another Claude Desktop or an orphaned helper. |
| `t14-evidence.sh` | Watches for a Cowork VM for up to 15 minutes, then writes a report proving it either did or did not boot. Safe to start before or after the app. |
| `fhs-boot-probe.nix` | Optional. Boots a QEMU in the *same* sandbox composition with no Claude Desktop involved, to tell a sandbox failure from an app failure. |

## Running it

```bash
./t14/t14-evidence.sh   # terminal A — collector, waits for a VM
./t14/t14-run.sh        # terminal B — the app
```

Then sign in and open Cowork in the GUI. The bootable disk is not in the `.deb`;
expect a ~27 MB `rootfs.img.zst` to download into the throwaway profile on first
use.

The report is written to `/tmp/cowork-t14/t14-evidence.txt`.

**What counts as success.** Not the feature gate opening — a QEMU process
carrying a `vhost-vsock-pci` device, holding `anon_inode:kvm-vcpu:*` fds, with a
live `virtiofsd` behind it. The collector discriminates on `vhost-vsock-pci`
specifically so that an Android-emulator `qemu-system-x86_64`, which never uses
one, is not reported as a pass.

## Isolation and cleanup

`t14-run.sh` redirects `XDG_{CONFIG,CACHE,DATA,STATE}_HOME` under
`/tmp/cowork-t14`. Your real `~/.config/Claude` is never read or written, and
`rm -rf /tmp/cowork-t14` undoes the whole test. Override the location with
`COWORK_TEST_ROOT`, the repo with `COWORK_REPO`, and the collector's deadline
with `COWORK_TEST_DEADLINE`.

The boot probe is impure and evaluates the flake from this checkout:

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
