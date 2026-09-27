#!/usr/bin/env bash
# T1.4 — evidence collector. Run this in a second terminal, before or after
# starting the app; it waits, then captures proof one way or the other.
#
# "The gate opened" is not the thing being measured. What is being measured is
# whether a QEMU process exists with a vhost-vsock device, holding open KVM vcpu
# fds, with a virtiofsd behind it — i.e. a VM that actually booted.
set -uo pipefail

ROOT=${COWORK_TEST_ROOT:-/tmp/cowork-t14}
DEADLINE=${COWORK_TEST_DEADLINE:-900}   # seconds to wait for a VM

# Beside the profile, never inside it. The documented cleanup for this test is
# `rm -rf $ROOT`, so a report written under $ROOT is destroyed by the very step
# the README tells you to run — which is how the first green lean run lost its
# evidence. $ROOT=/tmp/cowork-t14 puts this at /tmp/cowork-t14-evidence.txt.
REPORT=${COWORK_TEST_REPORT:-${ROOT%/}-evidence.txt}
LOGDIR="$ROOT/config/Claude/logs"

mkdir -p "$ROOT" "$(dirname "$REPORT")"
exec > >(tee "$REPORT") 2>&1

echo "=== T1.4 evidence — started $(date -Is) ==="
echo "profile root: $ROOT"
echo "report:       $REPORT  (outside the profile; survives cleanup)"
echo "waiting up to ${DEADLINE}s for a Cowork VM to appear"
echo

# Our QEMU, and only ours. There is an Android-emulator qemu-system-x86_64 on
# this host; matching on the binary name alone would report it as a success.
# The vhost-vsock device is the discriminator: the Android emulator never uses
# one, and the Cowork helper always does.
# Scan /proc rather than `pgrep -x qemu-system-x86_64`: nixpkgs' qemu is a
# wrapper, so the real process is .qemu-system-x86_64-wrapped and its comm is
# truncated to ".qemu-system-x8". `pgrep -x` matches comm, never matched ours,
# and the collector reported NO VM while a VM was demonstrably running — the
# exact false negative this script exists to rule out. argv[0] is still
# "qemu-system-x86_64", so match on the cmdline instead.
find_qemu() {
  local d pid c
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    # 2>/dev/null must precede the input redirection: redirections are applied
    # left to right, and a process that exits between the glob and the read
    # would otherwise print "No such file or directory" into the report.
    c=$(tr '\0' ' ' 2>/dev/null < "$d/cmdline") || continue
    case "$c" in
      # t14/fhs-boot-probe.nix boots a qemu with a vhost-vsock device of its
      # own, and t14/README.md offers it as a pre-flight for this very session.
      # So the discriminator that keeps the Android emulator out does not keep
      # the probe out: run both and this collector would report a throwaway
      # 10-second guest as a booted Cowork VM. The probe marks itself with
      # `-name cowork-boot-probe` precisely so this loop can decline it.
      *cowork-boot-probe*) continue ;;
      *qemu-system-x86_64*vhost-vsock-pci*) echo "$pid"; return 0 ;;
    esac
  done
  return 1
}

# Same reasoning as find_qemu, for processes that need no discriminator beyond
# their identity. Matching /proc/PID/exe rather than comm or the cmdline is
# immune to all three traps this script has hit: comm's 15-character
# truncation, nixpkgs' `.foo-wrapped` indirection (the wrapper's exe still
# contains the name), and a pattern that matches the shell running the scan,
# whose exe is bash.
find_by_exe() {
  local pat=$1 d e hit=1
  for d in /proc/[0-9]*; do
    e=$(readlink "$d/exe" 2>/dev/null) || continue
    case "$e" in
      *"$pat"*) echo "${d#/proc/}"; hit=0 ;;
    esac
  done
  return $hit
}

start=$(date +%s); qemu=""
while [ $(( $(date +%s) - start )) -lt "$DEADLINE" ]; do
  if qemu=$(find_qemu); then break; fi
  qemu=""
  sleep 2
done

dump_proc() {
  local pid=$1 label=$2
  echo "  pid $pid  ($label)"
  echo "  started: $(ps -o lstart= -p "$pid" 2>/dev/null | xargs)"
  echo "  argv:"
  tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/^/    /'
}

if [ -n "$qemu" ]; then
  echo "############ VM FOUND ############"
  echo
  echo "--- 1. the qemu process and its argv ---"
  dump_proc "$qemu" "qemu-system-x86_64"
  # Corroboration, not a gate: the argv above is the evidence, and this says
  # who produced it. A Cowork VM is forked by cowork-linux-helper. Anything
  # else named here — a shell, an init, this script — means the qemu that was
  # found is not the one the test is about, however well its argv matched.
  ppid=$(awk '/^PPid:/{print $2}' "/proc/$qemu/status" 2>/dev/null)
  echo "  parent:  pid ${ppid:-?} -> $(readlink "/proc/${ppid:-0}/exe" 2>/dev/null || echo '(exited or not ours to read)')"
  echo
  echo "--- 2. open fds: KVM vcpus and the vsock device ---"
  ls -l "/proc/$qemu/fd" 2>/dev/null | grep -E 'kvm|vhost-vsock|vhost-net' | sed 's/^/    /'
  echo "  (anon_inode:kvm-vcpu:N means the guest has running virtual CPUs;"
  echo "   /dev/vhost-vsock open means the host<->guest RPC transport exists)"
  echo
  echo "--- 3. virtiofsd ---"
  vfsd=$(find_by_exe virtiofsd) \
    && for p in $vfsd; do dump_proc "$p" "virtiofsd"; done \
    || echo "    NONE RUNNING — the share is not mounted"
  echo
  echo "--- 4. cowork-linux-helper ---"
  helper=$(find_by_exe cowork-linux-helper) \
    && for p in $helper; do dump_proc "$p" "helper"; done \
    || echo "    NONE RUNNING"
  echo
  echo "--- 5. vsock: kernel module and sockets ---"
  lsmod | grep -E '^(vsock|vhost_vsock|vmw_vsock)' | sed 's/^/    /'
  echo "  guest-cid from qemu argv: $(tr '\0' ' ' < "/proc/$qemu/cmdline" | grep -o 'guest-cid=[0-9]*')"
  ss -A vsock 2>/dev/null | sed 's/^/    /'
  echo
  echo "--- 6. helper socket ---"
  ls -la "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/claude-cowork-vm.sock" 2>&1 | sed 's/^/    /'
else
  echo "############ NO VM AFTER ${DEADLINE}s ############"
  echo
  echo "--- processes that did exist ---"
  for p in $(find_by_exe cowork-linux-helper) $(find_by_exe virtiofsd); do
    dump_proc "$p" "$(basename "$(readlink "/proc/$p/exe" 2>/dev/null)")"
  done
  echo "    (any qemu below without a vhost-vsock device is NOT ours:)"
  for p in $(find_by_exe qemu-system); do dump_proc "$p" "qemu"; done
fi

echo
echo "--- 7. VM bundle (downloaded rootfs.img) ---"
ls -la "$ROOT/config/Claude/vm_bundles/claudevm.bundle/" 2>&1 | sed 's/^/    /'

echo
echo "--- 8. app log: gate, helper, VM startup ---"
if [ -d "$LOGDIR" ]; then
  echo "    log files: $(ls "$LOGDIR" 2>/dev/null | tr '\n' ' ')"
  grep -hE '\[linux-vm\]|\[linux-vm-helper\]|\[VM:start\]|\[vm\]|\[qemu\]|\[virtiofsd\]|\[Bundle:status\]|\[downloadVM\]|virtualization|Cowork|unsupportedCode' \
    "$LOGDIR"/*.log 2>/dev/null | tail -80 | sed 's/^/    /'
else
  echo "    no log directory at $LOGDIR — did the app start with COWORK_TEST_ROOT set?"
fi

echo
echo "=== finished $(date -Is) — full report at $REPORT ==="
