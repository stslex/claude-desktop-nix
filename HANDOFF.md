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

### T1.4's GUI half — needs a human

The live test must be re-run on the current version. This is a rule, not
caution: `t14/README.md` says re-run after any bump that touches Cowork's
support probe or its VM helper, and the merge from `dev` touched both.
`resources/cowork-linux-helper` went 3 236 024 → 3 285 176 bytes with a
different hash, and `resources/smol-bin.x64.img` changed content at identical
size. Neither is inspectable from packaging; only a live boot answers whether
they still work here.

It passed end to end once, on 1.24012.9 — the evidence is in `c0a7cb7`'s commit
message, down to a guest that reached Ubuntu 24.04 userspace and ran commands,
with `v_str` ESTAB from host CID 2. So this is a re-run, not a first attempt.

The sandbox half does **not** need re-establishing; see §3. What the re-run has
to cover is the path through the app: gate → helper → bundle download →
`startVM`. Steps are in §2.

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

What is **not** established on 1.32352.1: the end-to-end path through the app
itself. It was asserted on 1.24012.9 and nowhere since, and the two binaries
that carry it both changed. Hence §1.

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
