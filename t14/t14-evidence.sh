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
REPORT="$ROOT/t14-evidence.txt"
LOGDIR="$ROOT/config/Claude/logs"

mkdir -p "$ROOT"
exec > >(tee "$REPORT") 2>&1

echo "=== T1.4 evidence — started $(date -Is) ==="
echo "profile root: $ROOT"
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
    c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
    case "$c" in
      *qemu-system-x86_64*vhost-vsock-pci*) echo "$pid"; return 0 ;;
    esac
  done
  return 1
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
  echo
  echo "--- 2. open fds: KVM vcpus and the vsock device ---"
  ls -l "/proc/$qemu/fd" 2>/dev/null | grep -E 'kvm|vhost-vsock|vhost-net' | sed 's/^/    /'
  echo "  (anon_inode:kvm-vcpu:N means the guest has running virtual CPUs;"
  echo "   /dev/vhost-vsock open means the host<->guest RPC transport exists)"
  echo
  echo "--- 3. virtiofsd ---"
  for p in $(pgrep -x virtiofsd 2>/dev/null); do dump_proc "$p" "virtiofsd"; done
  pgrep -x virtiofsd >/dev/null 2>&1 || echo "    NONE RUNNING — the share is not mounted"
  echo
  echo "--- 4. cowork-linux-helper ---"
  for p in $(pgrep -f 'cowork-linux-helper' 2>/dev/null); do dump_proc "$p" "helper"; done
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
  pgrep -af 'cowork-linux-helper|virtiofsd' | sed 's/^/    /' || echo "    none"
  echo "    (any qemu-system-x86_64 below without vhost-vsock is NOT ours:)"
  pgrep -af qemu-system-x86_64 | sed 's/^/    /' || echo "    none"
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
