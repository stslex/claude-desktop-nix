# Handoff — Cowork enablement (Track 1)

Branch `claude/cowork-enablement`. Uncommitted by design; decide in the morning.

## 1. T1.4 — live test, exact steps

Scripts were in `/tmp` and would not survive a reboot. They are now in
**`t14/`** at the repo root, gitignored via a new `/t14/` line in `.gitignore`
(the only uncommitted tracked change). `t14/fhs-boot-probe.nix` is also there —
it boots a QEMU in the same sandbox with no Claude Desktop involved, which is
how to tell a sandbox failure from an app failure without guessing.

**Precondition — quit Claude Desktop from the tray first.** The helper socket is
`$XDG_RUNTIME_DIR/claude-cowork-vm.sock` and is *not* covered by the throwaway
`XDG_CONFIG_HOME`. Yesterday a dev-build app (pid 940578) and its
`cowork-linux-helper` (pid 940892) owned it; a second instance would talk to the
wrong helper. `t14-run.sh` refuses to start if either is up.

```bash
# 0. quit Claude Desktop from the tray, then confirm (expect no output).
#    NOT pgrep -f: this checkout is named claude-desktop-nix, so any process
#    that merely mentions the directory matches and reports a phantom.
ls -l /proc/*/exe 2>/dev/null | grep -E 'claude-desktop|cowork-linux-helper'

# 1. terminal A — evidence collector, waits up to 15 min for a VM
./t14/t14-evidence.sh

# 2. terminal B — launch against a throwaway profile
./t14/t14-run.sh
```

Then in the GUI: sign in, open Cowork. The bootable disk is not in the `.deb`;
expect a **1.24 GiB** `rootfs.img.zst` download from `downloads.claude.ai` into
the throwaway profile, decompressing to a 10 GiB sparse `rootfs.img` beside a
10 GiB sparse `sessiondata.img`.

**Disk-space precondition: budget ~15 GB.** Measured after a real run,
`/tmp/cowork-t14` occupies ~13 GB (~23 GB apparent — the images are sparse). On
this host `/tmp` is on `/` (`/dev/nvme0n1p2`, 1.9 TB) and not a tmpfs, so it is
fine; on a host where `/tmp` is RAM-backed, set `COWORK_TEST_ROOT` elsewhere.

`t14-run.sh` redirects `XDG_{CONFIG,CACHE,DATA,STATE}_HOME` under
`/tmp/cowork-t14`. Your real `~/.config/Claude` is never read or written;
`rm -rf /tmp/cowork-t14` undoes the test.

Report is written to `/tmp/cowork-t14-evidence.txt` — beside the profile, not
inside it, so `rm -rf /tmp/cowork-t14` does not delete it. Success is a QEMU
process with a `vhost-vsock-pci` device, `anon_inode:kvm-vcpu:*` fds and a live
`virtiofsd` — not the gate opening. The collector discriminates on
`vhost-vsock-pci` so the Android-emulator QEMU (pid 46382) is not mistaken for
ours.

Optional pre-flight, proves the sandbox half independently:
`nix build --no-link --print-out-paths --impure --file t14/fhs-boot-probe.nix`
then run `<result>/bin/cowork-boot-probe`.

## 2. Open decisions

- **push/PR workflow + lean check as its own job gated on `flake.lock`** —
  recommended, not done. Needs `nix flake check` replaced by explicit per-check
  builds (no per-check skip exists). Note the repo has *no* push/PR CI at all
  today, so commits go unverified until the next upstream bump.
- **T1.6 `leanQemu` flip to default** — blocked on T1.4 being green. Unchanged.
- **M3 `base: dev` + `ref: dev`** — still FLAGGED even though PR #2 merged.

## 3. Branch state

```
b1731a4  docs: the Cowork output, and a known-gaps section
aa8cdff  claude-desktop-cowork: a Cowork-enabled FHS output
6382cd4  claude-desktop: add a dev packaging channel   (base, = dev)
```

Committed: `pkgs/ovmf-fhs.nix`, `pkgs/cowork-fhs-paths.nix`,
`pkgs/claude-desktop-fhs.nix`, `flake.nix`, `README.md`.

Uncommitted: `.gitignore` (one `/t14/` line), `HANDOFF.md`, `t14/` (ignored).

Verified on the committed tree: `packages.default` and
`packages.claude-desktop-fhs` byte-identical to pre-branch
(`8m91vicl…-claude-desktop-1.24012.9.drv`,
`233ljqlh…-claude-desktop-fhs-1.24012.9.drv`); `nix build .#default
.#claude-desktop-fhs .#claude-desktop-cowork` and `nix flake check` all pass.

Not yet asserted anywhere: the end-to-end path through the app itself
(gate → helper → bundle download → `startVM`). That is what T1.4 is for, and
the README says so rather than implying more.

## 4. Host — still to do

Add to your NixOS config:

```nix
boot.kernelModules = [ "vhost_vsock" ];
```

Nothing is *strictly* missing — `/dev/kvm` and `/dev/vhost-vsock` are both mode
`0666` from systemd's own udev rules, `/dev/vhost-vsock` is a static node that
demand-loads the module on first open, and the probe already returns
`kvm: "ok"`. This is about the failure mode, not the happy path.

**The `/lib/modules` ENOENT finding.** If the demand-load ever fails, the app's
fallback does:

```js
return (await W.access(C.posix.join("/lib/modules", Xe.release())), "vsock_module_missing");
} catch {
  return "vsock_kernel_unsupported";
}
```

`/lib/modules` **does not exist on NixOS at all** — modules live under
`/run/booted-system/kernel-modules/lib/modules/<rel>`. So the `access()` always
throws `ENOENT`, and the app reports `vhost_vsock_kernel_unsupported`:

> "Cowork isn't available on this device: the operating system's kernel doesn't
> include the virtualization support Cowork needs, and it can't be added
> manually. This is common on ChromeOS and other container-based Linux
> environments."

That is wrong on NixOS and points at the wrong layer entirely — the module is
right there under `/run/booted-system/`. Loading it at boot makes the branch
unreachable. Also in the README's new Cowork section.
