# Diagnostic only. Not part of the repository, never referenced by the flake.
#
# Boots a real QEMU inside the *same* bubblewrap composition claude-desktop-cowork
# uses, with the same OVMF pair, the same vhost-vsock device and a real virtiofsd,
# and then kills it. Nothing about Claude Desktop is involved.
#
# The point is to split T1.4's single opaque outcome in two. If this passes and
# the app still cannot start a VM, the fault is in the app or the gate. If this
# fails, the fault is in the sandbox, the firmware pair or the host — and the app
# was never going to work regardless.
let
  flake = builtins.getFlake (toString ../.);
  pkgs = (import flake.inputs.nixpkgs {
    system = "x86_64-linux";
    config.allowUnfree = true;
  }).extend flake.overlays.default;

  ovmf-fhs = pkgs.callPackage ../pkgs/ovmf-fhs.nix { };

  script = pkgs.writeShellScript "cowork-boot-probe" ''
    set -u
    work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
    ok=0; bad=0
    pass() { echo "  PASS  $*"; ok=$((ok+1)); }
    fail() { echo "  FAIL  $*"; bad=$((bad+1)); }

    echo "=== 1. virtiofsd starts inside the nested user namespace ==="
    # This is the one piece with a real reason to fail here: virtiofsd sandboxes
    # itself by unsharing its own user namespace, nested inside bubblewrap's.
    mkdir -p "$work/share"
    virtiofsd --socket-path="$work/vfsd.sock" --shared-dir="$work/share" \
      --sandbox=namespace >"$work/vfsd.log" 2>&1 &
    vfsd=$!
    sleep 2
    if kill -0 $vfsd 2>/dev/null && [ -S "$work/vfsd.sock" ]; then
      pass "virtiofsd alive (pid $vfsd), socket created"
    else
      fail "virtiofsd did not survive startup"
      sed 's/^/        /' "$work/vfsd.log"
    fi

    echo
    echo "=== 2. QEMU boots with the OVMF pair, KVM and vhost-vsock ==="
    # The vars template is read-only in the store; the helper copies it before
    # use and so must we.
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$work/vars.fd"
    chmod +w "$work/vars.fd"

    # A guest-cid nobody else is using. 3 is reserved for the host-facing side.
    cid=$(( (RANDOM % 60000) + 2000 ))

    qemu-system-x86_64 \
      -machine q35,accel=kvm \
      -cpu host -smp 2 -m 512 \
      -object memory-backend-memfd,id=mem0,size=512M,share=on \
      -numa node,memdev=mem0 \
      -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
      -drive if=pflash,format=raw,file="$work/vars.fd" \
      -device vhost-vsock-pci,guest-cid=$cid \
      -chardev socket,id=vfsd0,path="$work/vfsd.sock" \
      -device vhost-user-fs-pci,chardev=vfsd0,tag=probeshare \
      -device virtio-rng-pci \
      -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
      -display none -serial file:"$work/serial.log" -no-reboot \
      >"$work/qemu.log" 2>&1 &
    qemu=$!
    sleep 6

    if kill -0 $qemu 2>/dev/null; then
      pass "qemu alive (pid $qemu, guest-cid $cid)"
      echo "        argv:"
      tr '\0' ' ' < /proc/$qemu/cmdline | fold -w 100 -s | sed 's/^/          /'
      echo "        fds onto the virt devices:"
      ls -l /proc/$qemu/fd 2>/dev/null | grep -E 'kvm|vhost-vsock' | sed 's/^/          /' \
        || echo "          (none visible)"
    else
      fail "qemu exited during startup"
      sed 's/^/        /' "$work/qemu.log"
    fi

    echo
    echo "=== 3. the guest firmware actually executed ==="
    sleep 4
    if [ -s "$work/serial.log" ]; then
      pass "serial output produced ($(wc -c <"$work/serial.log") bytes) — firmware ran"
      head -c 400 "$work/serial.log" | tr -d '\r' | sed 's/^/        /'
    else
      fail "no serial output; the firmware pair did not execute"
    fi

    kill $qemu $vfsd 2>/dev/null
    wait 2>/dev/null

    echo
    echo "=== result: $ok passed, $bad failed ==="
    [ $bad -eq 0 ]
  '';
in
pkgs.buildFHSEnv {
  pname = "cowork-boot-probe";
  version = pkgs.claude-desktop-cowork.version;
  targetPkgs = _: [
    pkgs.claude-desktop
    pkgs.coreutils
    pkgs.bashInteractive
    pkgs.gnugrep
    pkgs.gnused
    pkgs.which
    pkgs.qemu_kvm
    pkgs.virtiofsd
    ovmf-fhs
  ];
  runScript = "${script}";
}
