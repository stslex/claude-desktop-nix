# Handoff — Cowork enablement (Track 1)

## How to read this file

Twice now this file has described a tree that no longer existed. The first time
it was written against a commit four commits behind the one that introduced it,
and shipped already wrong. The second time it went on claiming the branch had
never been pushed while a pull request against `dev` was open and green.

Both failures have the same cause: it transcribed facts that git and `gh`
already answer, and transcriptions rot. So this file no longer holds a commit
log, a branch state or a PR status. Where you want one, the command that
produces it is named instead:

```bash
git log --oneline origin/dev..HEAD     # what this branch adds
git status -sb                         # where it is, and whether it is pushed
gh pr list                             # what is open
gh run list --branch "$(git branch --show-current)"   # what CI has said
```

What stays here is what none of those can tell you: what is still open, why,
and what has been measured by hand.

## 1. What is open

### Nothing, on the Cowork path itself

T1.4 was re-run on 1.32352.1 on 2026-08-18 and passed; the evidence is in §3.
The next re-run is due on the next bump that moves
`resources/cowork-linux-helper` or `resources/smol-bin.x64.img`, per the rule in
`t14/README.md`. Neither file is inspectable from packaging, so only a live boot
answers it.

### The host prerequisite

```nix
boot.kernelModules = [ "vhost_vsock" ];
```

Still absent from this host's NixOS configuration. Nothing is strictly broken —
`/dev/vhost-vsock` is a static node at mode 0666 and demand-loads the module on
first open, which was *measured* rather than assumed: the module was not loaded
before the boot probe ran and was loaded after it. This is about the failure
mode, not the happy path. If a demand-load ever fails, the app falls back to
`access("/lib/modules/$(uname -r)")` — a path NixOS does not have — and reports
`vhost_vsock_kernel_unsupported`, blaming the kernel for a module sitting in
`/run/booted-system/kernel-modules/lib/modules/`. Loading it at boot makes that
branch unreachable. Written up in `README.md` § Cowork and `t14/README.md`.

### Landing the branch

Nothing blocks it technically: `dev` is merged in, the tree is green, and both
CI jobs have completed. Merging is the owner's call.

## 2. T1.4 — exact steps

**Precondition: quit Claude Desktop from the tray first.** The helper socket is
`$XDG_RUNTIME_DIR/claude-cowork-vm.sock` and is *not* covered by the throwaway
`XDG_CONFIG_HOME`; a second instance would talk to the wrong helper.
`t14-run.sh` refuses to start if either process is up.

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

**Budget ~15 GB of disk.** Measured after a real run, `/tmp/cowork-t14` occupies
~13 GB (~23 GB apparent — the images are sparse). On this host `/tmp` is on `/`
and not a tmpfs, so it is fine; elsewhere, set `COWORK_TEST_ROOT`.

`t14-run.sh` redirects `XDG_{CONFIG,CACHE,DATA,STATE}_HOME` under
`/tmp/cowork-t14`, so `~/.config/Claude` is never touched and
`rm -rf /tmp/cowork-t14` undoes the test. The report lands in
`/tmp/cowork-t14-evidence.txt`, beside the profile rather than inside it, so
cleanup does not delete the evidence.

Success is not the gate opening. It is a QEMU process with a `vhost-vsock-pci`
device, `anon_inode:kvm-vcpu:*` fds and a live `virtiofsd` behind it.

## 3. What has been verified by hand

Re-run these and they answer for themselves:

```bash
nix build .#claude-desktop-cowork .#default .#claude-desktop-fhs
nix flake check                     # four checks; compiles QEMU from source
nix build --no-link --print-out-paths --impure --file t14/fhs-boot-probe.nix
```

**T1.4 passed on 1.32352.1** (2026-08-18). Full argv and fd listing in
`/tmp/cowork-t14-evidence.txt` at the time of the run; the load-bearing parts:

- `qemu-system-x86_64 -name claude-cowork-vm`, **forked by
  `cowork-linux-helper`** — which is what distinguishes it from any other QEMU
  on the host, and from the boot probe;
- `-device vhost-vsock-pci,guest-cid=208399576`, and the helper's own log
  showing `guest connected from vm(208399576)` → `guest ready` on that same
  CID;
- fds on `/dev/kvm`, `kvm-vcpu:0`, `kvm-vcpu:1`, `/dev/vhost-vsock`;
- `virtiofsd --shared-dir / --sandbox none` behind a `vhost-user-fs-pci` tagged
  `claudeshared`; `smol-bin.x64.img` attached read-only;
- `[VM:start] Startup complete, total time: 38726ms`, and the guest answered
  `uname -a` / `cat /etc/os-release` as Ubuntu 24.04.4, kernel 6.18.5.

Two things that capture settled, neither of which packaging could have shown:

- **The helper asks QEMU for its own seccomp sandbox** —
  `-sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny`,
  the first option after `-name`. Nothing asserted it. A QEMU built without
  seccomp exits 1 at argument parsing while passing the gate and every other
  assertion, so this is now `coworkQemuNeeds.sandbox` and is exercised by
  invocation rather than by grepping a listing, because `-sandbox` has no
  listing. Proven able to fail: with a bogus value the check reports
  `Parameter 'enable' expects 'on' or 'off'` and the build stops.
- **The boot was a direct kernel boot**, `-kernel` + `-initrd` from the
  downloaded bundle, with zero `pflash` arguments. The 1.24012.9 run booted
  through OVMF. So the firmware pair is required by the gate and by the
  helper's conditional EFI path, not by the boot the app performs by default —
  corrected in `README.md` § Cowork and in the boot probe's header, both of
  which had presented OVMF as what boots the guest.

The guest's kernel string is `6.18.5-fc-v20`, and the `-fc-` suffix reads like
Firecracker. It is not evidence of anything: the same image is shipped for both,
and the Cowork agent itself concluded from it that it was running in the cloud,
while the local QEMU it was running under was visible in `ps` the whole time.
The process parent and the matching vsock CID are what settle it. A cloud
session had in fact been refused twenty seconds earlier —
`startRemoteCoworkSession: 403` — which is why the local VM was used at all.

What is worth recording because re-deriving it is expensive or impossible:

- **The boot probe passes 3/3 against the trimmed QEMU** — the one the package
  actually ships, not the cached `qemu_kvm` it used to reach for. virtiofsd
  survives the nested user namespace; QEMU boots holding fds on `/dev/kvm`,
  `kvm-vcpu:0`, `kvm-vcpu:1` and `/dev/vhost-vsock`; the OVMF pair executes
  (241 bytes of serial, BdsDxe reaching PXE — correct, the probe gives the guest
  no boot device).
- **`coworkProbe` and `coworkQemuNeeds` still describe the 1.32352.1 payload.**
  Both OVMF candidates, both virtiofsd candidates, `qemu-system-x86_64`, the
  `OVMF_CODE`→`OVMF_VARS` substitution, and all nine QEMU features in the
  helper. Checked by hand, because `pkgs/cowork-fhs-paths.nix` warns in its own
  header that a bump can invalidate that transcription while the check stays
  green. A green build does not cover this.
- **The trimmed QEMU does build on a GitHub runner without a cache**: 10m05s of
  QEMU, 11m40s for the job, on `ubuntu-24.04`, run 32151939933. This had never
  completed before and was assumed to be far worse than the ~18 minutes it takes
  locally. It is not.
- **The evidence collector used to mistake the boot probe for a Cowork VM.**
  With the probe's guest alive, the old matcher returned its pid — a false
  `VM FOUND`, from the tool whose entire job is not producing one. The probe now
  carries `-name cowork-boot-probe` and the collector declines it; both
  behaviours were re-measured after the fix.

A trap the re-run exposed, now fixed in `t14-run.sh`: redirecting
`XDG_CONFIG_HOME` moves the whole desktop-integration context, not just the
app's profile, so `xdg-open` inside the sandbox could not find the host's
browser and fell back to launching a different one — with the throwaway XDG
dirs, i.e. an empty browser profile, in which an OAuth sign-in can never
complete. Four attempts failed before this was understood, and nothing in either
log said why. The script now resolves the host's browser to an absolute path and
seeds the throwaway `mimeapps.list` with it. Naming the host's `.desktop` file
is not enough: this host's `zen.desktop` carries a bare `Exec=zen`, and PATH
inside the sandbox is the sandbox's own.

## 4. Traps on this host

- An Android emulator `qemu-system-x86_64` runs here. It never uses a
  `vhost-vsock-pci` device, which is exactly why `t14/t14-evidence.sh`
  discriminates on that. Do not "fix" the collector to match on process name.
- Never use `pgrep -f` to look for Claude Desktop. The checkout is named
  `claude-desktop-nix`, so any process merely mentioning the directory — your
  editor, a grep, the shell doing the check — matches. It caused four false
  readings in one session. Match `/proc/PID/exe` instead; it is also immune to
  `comm`'s 15-character truncation and to nixpkgs' `.foo-wrapped` indirection.

## 5. Known gap, recorded and deliberately not fixed

`cowork-linux-helper` starts virtiofsd with `--shared-dir /` and
`--sandbox none` (observed live), so the guest's `claudeshared` tag is a view of
the sandbox root, not of a chosen directory. The argv is built inside the
shipped helper binary, so it is unreachable from packaging without patching that
binary or `app.asar`, which this repository does not do. A VM boundary is easy
to mistake for a filesystem boundary; here it is not one. Also in `README.md`
§ Known gaps.
