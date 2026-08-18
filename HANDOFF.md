# Handoff — Cowork enablement (Track 1)

Branch `claude/cowork-enablement`, local only — it has never been pushed, so
there is no copy of it anywhere but this working tree.

## 1. T1.4 — live test, exact steps

Scripts were in `/tmp` and would not survive a reboot. They are now committed
under **`t14/`** at the repo root. `t14/fhs-boot-probe.nix` is also there — it
boots a QEMU in the same sandbox with no Claude Desktop involved, which is how
to tell a sandbox failure from an app failure without guessing.

**Read §2 before running this.** T1.4 already passed once, end to end, on
1.24012.9 — the steps below are for the *re-run* the version jump requires, not
for a first attempt.

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

- **Re-run T1.4 on 1.32352.1.** Not a first run: it passed end to end on
  1.24012.9, and the evidence is in c0a7cb7's commit message — `startVM`, a
  guest that reached Ubuntu 24.04 userspace and ran commands, `v_str` ESTAB
  from host CID 2. An earlier version of this file said T1.4 was outstanding;
  it was written before c0a7cb7 and committed after it without being updated.

  The re-run is required rather than precautionary. `t14/README.md` sets the
  rule — re-run after any bump that touches Cowork's support probe or its VM
  helper — and this bump touches both: `resources/cowork-linux-helper` changed
  (3 236 024 → 3 285 176 bytes, different hash) and `resources/smol-bin.x64.img`
  changed too, same size, different content. Neither is inspectable from
  packaging; only a live boot answers whether they still work here.

  What the re-run does *not* have to re-establish is the sandbox half — see
  §3 for the probe, which is green on this exact tree.
- **Push this branch.** It exists in exactly one place. Seven commits of work
  and a merge, with no remote copy.
- **Land it into `dev`.** Nothing blocks the merge — `dev` is already merged
  *in*, and the tree is green on 1.32352.1.

Closed since the previous handoff, recorded so they are not re-litigated:

- ~~push/PR workflow + lean check gated on `flake.lock`~~ — done, `ci.yml`.
  The gate is *not* `flake.lock` alone: `pkgs/claude-desktop-fhs.nix` holds the
  override list, and trimming one option too many is the exact failure the
  check exists to catch, so gating on the lock file alone would have skipped it
  precisely when it mattered. `update.yml` also stopped calling `nix flake
  check` — see the comment there for why a bump cannot move that check's
  inputs, and therefore why leaving it out costs no coverage.
- ~~T1.6 `leanQemu` flip to default~~ — done in c0a7cb7; `flake.nix` pins
  `leanQemu = true`.
- ~~M3 `base: dev` + `ref: dev`~~ — resolved by the channel split now merged
  from `dev`: `update.yml` derives both the verified tree and the landing
  branch from one `TARGET_REF`, so they cannot drift.

## 3. Branch state

```
4d549fb  Merge branch 'dev' into claude/cowork-enablement   (= dev, 1.32352.1)
b455df8  Create HANDOFF.md
0022a99  t14: write the report beside the profile, not inside it
c0a7cb7  cowork: xdg-utils, leanQemu by default, and honest process matching
ff50c2f  t14: fix a false negative and the deep-link callback
c1983dc  t14: commit the Cowork live-test harness
b1731a4  docs: the Cowork output, and a known-gaps section
aa8cdff  claude-desktop-cowork: a Cowork-enabled FHS output
6382cd4  claude-desktop: add a dev packaging channel        (original base)
```

The working tree is clean; nothing is left uncommitted, and `/t14/` is no
longer in `.gitignore`.

**Re-verified on 1.32352.1**, after the merge carried the branch across eight
upstream releases at once:

- `nix build .#claude-desktop-cowork .#default .#claude-desktop-fhs` — pass.
- `nix flake check` — pass, all four checks.
- `t14/fhs-boot-probe.nix` — **3/3 pass**. virtiofsd survives the nested user
  namespace; QEMU boots holding fds on `/dev/kvm`, `kvm-vcpu:0`, `kvm-vcpu:1`
  and `/dev/vhost-vsock`; the OVMF pair executes (241 bytes of serial, BdsDxe
  reaching PXE — correct, the probe gives the guest no boot device).
- The hand-transcribed `coworkProbe` and `coworkQemuNeeds` were re-scanned
  against the 1.32352.1 payload and **all still describe it**: both OVMF
  candidates, both virtiofsd candidates, `qemu-system-x86_64`, the
  `OVMF_CODE`→`OVMF_VARS` substitution, and all nine QEMU features in the
  helper. `cowork-fhs-paths.nix` warns that a bump can silently invalidate that
  list, so this was checked by hand rather than inferred from a green build.
- The `/lib/modules` finding in §4 still holds on 1.32352.1 — the string and
  both `vsock_*` status values are still in the bundle.

Also measured rather than reasoned about this time: `vhost_vsock` was **not**
loaded before the probe and was loaded after it, confirming that the static
`/dev/vhost-vsock` node really does demand-load the module.

What is *not* re-established on 1.32352.1: the end-to-end path through the app
itself (gate → helper → bundle download → `startVM`). It was asserted on
1.24012.9 and nowhere since, and the two binaries that carry it both changed in
this bump — hence the re-run in §2. The README describes the guarantee at that
strength rather than implying more.

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
