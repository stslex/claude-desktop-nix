{
  lib,
  runCommand,

  # The variant under test. Parameterised rather than hardcoded so both QEMUs
  # are covered: the trimmed default, which is the one with a real reason to
  # fail these assertions, and the `leanQemu = false` escape hatch, which is
  # supported and therefore has to keep evaluating.
  claude-desktop-cowork,
}:

# Guards the Cowork variant's entire reason for existing. Every assertion here
# covers a failure that a green build cannot show:
#
#   - a probe path that stopped resolving (nixpkgs moves virtiofsd to libexec,
#     OVMF changes its layout) closes the gate again, and the app reports it to
#     the user as "install qemu with apt";
#   - a firmware code file with no matching vars file beside it passes the gate
#     and then fails at boot;
#   - a QEMU trimmed past the point of usefulness — the live risk `leanQemu`
#     introduces — also passes the gate and fails at boot.
#
# The expected values are read from the package's own passthru rather than
# restated here, so the list that documents upstream and the list that is tested
# cannot drift apart.
#
# What this does NOT do, stated so nobody reads more into a green run than is
# there: it does not rescan the app payload. `coworkProbe` and `coworkQemuNeeds`
# are hand-transcribed from the bundle, and if an upstream bump changes the
# paths the app searches, these assertions will keep passing against a list that
# no longer describes it. That is a weaker guarantee than the sibling
# dlopen-runpath check, which rescans the shipped ELFs on every run.
let
  inherit (claude-desktop-cowork) coworkProbe coworkQemuNeeds;
in
runCommand
  "${claude-desktop-cowork.pname}-fhs-paths-${
    if claude-desktop-cowork.leanQemu then "lean" else "full"
  }-qemu"
  { }
  ''
    set -uo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }

    echo "variant: ${claude-desktop-cowork.pname} (leanQemu=${lib.boolToString claude-desktop-cowork.leanQemu})"

    launcher=${claude-desktop-cowork}/bin/${claude-desktop-cowork.meta.mainProgram}
    test -x "$launcher" || fail "$launcher missing or not executable"

    # The bwrap launcher ro-binds the FHS rootfs into / entry by entry, so the
    # rootfs store path it names is the ground truth for what the sandbox will
    # present at /usr.
    rootfs=$(grep -om1 '/nix/store/[^ "]*-fhsenv-rootfs' "$launcher") || true
    test -n "''${rootfs:-}" || fail "no fhsenv-rootfs path found in $launcher"
    test -d "$rootfs" || fail "fhsenv-rootfs $rootfs is not a directory"
    echo "rootfs: $rootfs"

    # --- qemu: found by a PATH walk, so both halves must hold ----------------
    qemu="$rootfs/usr/bin/${coworkProbe.qemuBin}"
    test -x "$qemu" || fail "${coworkProbe.qemuBin} not executable at $qemu"

    # Scoped to the PATH assignment rather than grepping the whole file: a
    # mention of /usr/bin in a comment or an unrelated variable must not be
    # allowed to stand in for the thing the probe actually walks.
    grep -qE '^export PATH=.*[:"]/usr/bin[:"]' "$rootfs/etc/profile" \
      || fail "/usr/bin is not in the PATH export in the sandbox's /etc/profile; the PATH walk would miss ${coworkProbe.qemuBin}"
    echo "qemu: $qemu"

    # --- firmware: first readable candidate, plus its vars pair --------------
    firmware=""
    for c in ${lib.escapeShellArgs coworkProbe.firmwareCandidates}; do
      if [ -r "$rootfs$c" ]; then firmware="$c"; break; fi
    done
    test -n "$firmware" \
      || fail "no OVMF code file at any of: ${toString coworkProbe.firmwareCandidates}"
    echo "firmware: $firmware"

    # The app derives this by replacing the first occurrence only, so sed
    # without /g is the faithful translation.
    vars=$(echo "$firmware" | sed 's|${coworkProbe.firmwareVarsSubstitution.from}|${coworkProbe.firmwareVarsSubstitution.to}|')
    test "$vars" != "$firmware" \
      || fail "vars substitution did not change $firmware; the pair cannot be formed"
    test -r "$rootfs$vars" \
      || fail "$firmware resolves but its vars template $vars does not; the gate would pass and the VM would not boot"
    echo "firmware vars: $vars"

    # --- virtiofsd: first readable candidate ---------------------------------
    virtiofsd=""
    for c in ${lib.escapeShellArgs coworkProbe.virtiofsdCandidates}; do
      if [ -r "$rootfs$c" ]; then virtiofsd="$c"; break; fi
    done
    test -n "$virtiofsd" \
      || fail "no virtiofsd at any of: ${toString coworkProbe.virtiofsdCandidates}"
    echo "virtiofsd: $virtiofsd"

    # --- qemu capabilities the helper's argv names ---------------------------
    #
    # The five `-<kind> help` listings each have their own layout (`name
    # "virtio-blk-pci", bus PCI` vs a bare indented word vs a name-and-
    # description column). Rather than one regex per layout, split every listing
    # into identifier-shaped tokens and match whole tokens: `q35` is then found
    # in the alias line without also matching inside `pc-q35-9.2`, which stays a
    # single token.
    check_group() {
      kind="$1"
      shift
      listing=$("$qemu" "-$kind" help 2>&1) \
        || fail "qemu -$kind help exited non-zero"
      tokens=$(tr -c 'A-Za-z0-9_.-' '\n' <<<"$listing")
      for n in "$@"; do
        grep -qxF "$n" <<<"$tokens" \
          || fail "this qemu has no $kind '$n'; the gate would still pass and the VM would fail at boot"
        echo "  $kind $n: ok"
      done
    }

    check_group machine ${lib.escapeShellArgs coworkQemuNeeds.machines}
    check_group accel   ${lib.escapeShellArgs coworkQemuNeeds.accels}
    check_group device  ${lib.escapeShellArgs coworkQemuNeeds.devices}
    check_group object  ${lib.escapeShellArgs coworkQemuNeeds.objects}
    check_group netdev  ${lib.escapeShellArgs coworkQemuNeeds.netdevs}

    touch $out
  ''
