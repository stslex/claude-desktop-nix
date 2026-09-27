{
  lib,
  runCommand,

  # Any FHS variant. The paths asserted here are the same for plain and cowork,
  # so the check runs against the plain one and no QEMU gets built for it.
  claude-desktop-fhs,
}:

# The FHS variant's other reason to exist, beside MCP tooling: the absolute
# paths inside app.asar that no wrapper can satisfy on NixOS. Each is a failure
# a green build cannot show: the app runs the path, gets ENOENT, and turns
# a feature off without saying so. The list comes from the package's own
# passthru, so what is documented there and what is tested here cannot drift.
#
# Like cowork-fhs-paths, this inspects the rootfs the bwrap launcher mounts,
# not a running sandbox. The rootfs's own /bin, /lib64 and so on are absolute
# symlinks into /usr, which only resolve inside the sandbox, so each path is
# mapped to its /usr counterpart the same way the mount does.
runCommand "${claude-desktop-fhs.pname}-host-paths" { } ''
  set -uo pipefail
  fail() { echo "FAIL: $*" >&2; exit 1; }

  launcher=${claude-desktop-fhs}/bin/${claude-desktop-fhs.meta.mainProgram}
  test -x "$launcher" || fail "$launcher missing or not executable"
  rootfs=$(grep -om1 '/nix/store/[^ "]*-fhsenv-rootfs' "$launcher") || true
  test -n "''${rootfs:-}" || fail "no fhsenv-rootfs path found in $launcher"

  for p in ${lib.escapeShellArgs claude-desktop-fhs.fhsHostPaths}; do
    case "$p" in
      /usr/*) inside=$p ;;
      *) inside=/usr$p ;;
    esac
    test -x "$rootfs$inside" \
      || fail "$p is not present in the sandbox (looked for $rootfs$inside)"
    echo "ok      $p -> $(readlink -f "$rootfs$inside")"
  done

  # Present is not the same as runnable: a dangling link into a store path
  # that was never part of the closure fails -x above, but a binary that
  # cannot start would not. Run the three commands for real.
  "$rootfs/usr/bin/busctl" --version >/dev/null || fail "busctl does not run"
  "$rootfs/usr/bin/ps" --version >/dev/null || fail "ps does not run"
  # secret-tool has no --version: run bare, it prints its usage and exits 2.
  st_out=$("$rootfs/usr/bin/secret-tool" 2>&1 || true)
  grep -q '^usage: secret-tool' <<<"$st_out" || fail "secret-tool does not run: $st_out"

  touch $out
''
