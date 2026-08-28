{
  lib,
  buildFHSEnv,
  claude-desktop,

  # Toolchain reachable from MCP server definitions. Kept deliberately small:
  # these are the launchers MCP configs actually name (`npx`, `uvx`, `docker`),
  # plus what those need to bootstrap.
  nodejs,
  uv,
  python3,
  git,
  docker-client,
  cacert,
  coreutils,
  bashInteractive,
  curl,
  gnutar,
  gzip,
  which,

  # URL-scheme dispatch. Not part of the MCP toolchain — this is what makes
  # `claude://` links work at all. Electron hands external URLs to `xdg-open`,
  # and inside a mount namespace only what this list provides exists: without
  # it there is no dispatcher in the sandbox, so the sign-in callback and the
  # desktop entry's own `claude://claude.ai/new` actions resolve to nothing and
  # fail silently. Confirmed by a live run before this was added.
  xdg-utils,

  # --- Cowork VM toolchain (only referenced when `cowork` is true) -----------
  qemu,
  qemu_kvm,
  virtiofsd,

  # OVMF restated under the filenames the probe searches; see pkgs/ovmf-fhs.nix.
  # Not in nixpkgs, so it has no default here and the overlay passes it in.
  # Required when `cowork` is set, unused otherwise.
  ovmf-fhs ? null,

  # Build the Cowork-enabled variant: same application, same sandbox, plus the
  # three host-side pieces the VM path needs at the paths it looks for them.
  # Off by default, so `claude-desktop-fhs` carries none of the VM toolchain.
  #
  # This lives here rather than in a file of its own because the FHS sandbox is
  # not incidental to Cowork — it is the whole mechanism. Two of the three
  # missing paths are hardcoded absolute FHS locations in the app bundle
  # (`/usr/share/OVMF/...`, `/usr/{libexec,bin}/virtiofsd`), reachable through a
  # mount namespace and nothing else. See the comment above `coworkTargetPkgs`.
  cowork ? false,

  # Use a trimmed, headless QEMU instead of `qemu_kvm`. Off by default.
  #
  # `qemu_kvm` is cached by hydra; the trimmed build is not, so turning this on
  # trades a few minutes of local compilation for roughly half the closure. The
  # features dropped are display, audio and smartcard front-ends — a VM driven
  # over vsock with virtiofs shares and no framebuffer touches none of them.
  # Everything the helper's argv actually names (q35, kvm, virtio-blk-pci,
  # vhost-vsock-pci, vhost-user-fs-pci, virtio-net-pci, virtio-rng-pci,
  # virtio-serial, memory-backend-memfd, `-netdev user` via libslirp) survives —
  # and checks.cowork-fhs-paths holds that claim to the trimmed binary itself,
  # rather than to the untrimmed one where it could not fail.
  leanQemu ? false,
}:

assert cowork -> ovmf-fhs != null;

# Why this exists: MCP servers are launched by the app as plain subprocesses,
# and the overwhelming majority of published configs shell out to `npx -y ...`
# or `uvx ...`. On a normal distro those resolve against /usr/bin; on NixOS
# they resolve against nothing. This variant runs the *same* store-built
# application inside an FHS sandbox where those launchers exist at conventional
# paths, so upstream MCP config snippets work unmodified.
#
# Caveat, stated rather than papered over: buildFHSEnv is itself a bubblewrap
# user namespace, and Chromium then nests its own namespace sandbox inside it.
# That works on a stock NixOS kernel, but if your kernel forbids nested user
# namespaces this variant will fail to start. The fix is the kernel setting —
# this package deliberately does not add --no-sandbox to paper over it. Use
# packages.default if you do not need MCP subprocess tooling.
let
  channel = claude-desktop.channel or "stable";
  variant = if cowork then "cowork" else "fhs";

  pname = "claude-desktop-${lib.optionalString (channel == "dev") "dev-"}${variant}";

  qemuPackage =
    if leanQemu then
      qemu.override {
        # x86_64 host only — the guest is the same architecture as the host, so
        # every other target emulator is dead weight.
        hostCpuOnly = true;

        # Display, audio and peripheral front-ends. The VM is headless: the
        # helper drives it over vsock and shares files over virtiofs, and its
        # QEMU argv names no display device at all.
        #
        # Dropping the audio stack is what pays for itself: pipewire pulls
        # ffmpeg, which pulls clang and llvm — about 1.4 GiB of compiler for a
        # machine that never renders a frame.
        gtkSupport = false;
        sdlSupport = false;
        openGLSupport = false;
        virglSupport = false;
        pipewireSupport = false;
        pulseSupport = false;
        alsaSupport = false;
        jackSupport = false;
        spiceSupport = false;
        smartcardSupport = false;
        usbredirSupport = false;
        vncSupport = false;
        ncursesSupport = false;
        brlttySupport = false;
        guestAgentSupport = false;
        libiscsiSupport = false;
        tpmSupport = false;
        canokeySupport = false;
      }
    else
      qemu_kvm;

  # The three host-side pieces the Cowork gate requires, placed where the app
  # looks for them. Each is a separate mechanism, and only one of the three is
  # satisfiable outside a mount namespace:
  #
  #   qemu       `Rsn(Asn)` walks `process.env.PATH` for `qemu-system-x86_64`.
  #              buildFHSEnv's /etc/profile puts /usr/bin on PATH, so this
  #              resolves to /usr/bin/qemu-system-x86_64. The Go helper then
  #              resolves the same basename again, independently, via
  #              os/exec.LookPath against the PATH it inherits — the app never
  #              forwards the path it found, so both halves need this and both
  #              get it from the same place.
  #
  #   ovmf-fhs   `Ast(Csn)` reads two hardcoded absolute paths and nothing else.
  #              No PATH, no environment variable, no app-relative fallback —
  #              which is why a wrapper cannot satisfy it and the FHS rootfs can.
  #
  #   virtiofsd  `Ast(Tsn)` over /usr/libexec/virtiofsd and /usr/bin/virtiofsd,
  #              same story. The .deb *does* bundle a virtiofsd, and this
  #              package already patches it — but it is unreachable here:
  #
  #                async function xsn(e) {
  #                  const t = await Ast(Tsn);
  #                  return t || (e ? ooe(ksn, Y.constants.X_OK) : null);
  #                }
  #
  #              `e` is true only when /etc/os-release reports ID=ubuntu and
  #              VERSION_ID 22.x. On NixOS the bundled copy is dead code, so the
  #              FHS path has to provide a real one. nixpkgs installs it to
  #              $out/bin, i.e. /usr/bin/virtiofsd — the second candidate.
  coworkTargetPkgs = [
    qemuPackage
    ovmf-fhs
    virtiofsd
  ];
in
buildFHSEnv {
  # Follows the wrapped package's channel, so a dev FHS build is not named
  # like a stable one in the store or in a profile.
  inherit pname;
  inherit (claude-desktop) version;

  targetPkgs =
    _:
    [
      claude-desktop
      nodejs
      uv
      python3
      git
      docker-client
      cacert
      coreutils
      bashInteractive
      curl
      gnutar
      gzip
      which
      xdg-utils
    ]
    ++ lib.optionals cowork coworkTargetPkgs;

  runScript = "${lib.getExe claude-desktop}";

  # buildFHSEnv only produces bin/<name>; carry the desktop entry and icons
  # across so the FHS variant is installable as a real desktop app, with Exec
  # repointed at this wrapper rather than the inner package.
  extraInstallCommands = ''
    mkdir -p $out/share
    cp -r ${claude-desktop}/share/icons $out/share/icons

    install -Dm644 \
      ${claude-desktop}/share/applications/com.anthropic.Claude.desktop \
      $out/share/applications/com.anthropic.Claude.desktop

    substituteInPlace $out/share/applications/com.anthropic.Claude.desktop \
      --replace-fail "${claude-desktop}/bin/claude-desktop" \
                     "$out/bin/${pname}"
  '';

  passthru = {
    inherit cowork leanQemu;
    inherit (claude-desktop) channel;

    # The Cowork gate's search paths, verbatim from the constants in the app
    # bundle. Consumed by pkgs/cowork-fhs-paths.nix, which reconciles them
    # against the FHS rootfs this derivation actually produced.
    #
    # Kept here rather than inlined in the check for the same reason
    # dlopenSonames lives on claude-desktop: the list is a claim about upstream,
    # and a claim that stops describing upstream should fail somewhere visible
    # rather than quietly stop being tested. Every entry is a string the app
    # passes to `access()`; none of them is a path this repository invented.
    coworkProbe = {
      # `Rsn(Asn)` — basename, resolved by walking PATH.
      qemuBin = "qemu-system-x86_64";

      # `Ast(Csn)` — absolute, first readable wins.
      firmwareCandidates = [
        "/usr/share/OVMF/OVMF_CODE_4M.fd"
        "/usr/share/OVMF/OVMF_CODE.fd"
      ];

      # `Ast(Tsn)` — absolute, first readable wins.
      virtiofsdCandidates = [
        "/usr/libexec/virtiofsd"
        "/usr/bin/virtiofsd"
      ];

      # `Usn(e)` — how the variables path is derived from the code path. Not a
      # search: whichever firmware candidate resolves, this substitution is
      # applied to it and the result is handed to QEMU as the writable half of
      # the pflash pair. A code file with no matching variables file next to it
      # passes the gate and then fails to boot.
      firmwareVarsSubstitution = {
        from = "OVMF_CODE";
        to = "OVMF_VARS";
      };
    };

    # What `resources/cowork-linux-helper` asks QEMU for. Originally read out of
    # the helper's own argv fragments rather than guessed from the feature name;
    # since 2026-08-18 also checked against a real Cowork VM booted on this
    # host, whose full argv T1.4 captured (t14/README.md). Everything below
    # appears in that capture.
    #
    # The gate checks that a `qemu-system-x86_64` exists and stops there — it
    # inspects no capability. So a QEMU that satisfies the gate and then cannot
    # create a vhost-vsock device produces a *passing* Cowork tab and a VM that
    # dies at boot. That is precisely the failure `leanQemu` could introduce by
    # trimming one option too many, which is why this list is asserted against
    # both QEMUs rather than trusted: checks.cowork-fhs-paths against the
    # trimmed build this package ships, checks.cowork-fhs-paths-full-qemu
    # against the cached one the `leanQemu = false` escape hatch selects.
    coworkQemuNeeds = {
      machines = [ "q35" ];
      accels = [ "kvm" ];
      devices = [
        "vhost-vsock-pci" # host <-> guest RPC transport
        "vhost-user-fs-pci" # the virtiofsd share
        "virtio-blk-pci" # rootdisk, smolbindisk (readonly), sessiondisk
        "virtio-net-pci"
        "virtio-rng-pci"
        "virtio-serial"
      ];
      objects = [ "memory-backend-memfd" ]; # share=on, required by vhost-user-fs
      netdevs = [ "user" ]; # guest networking; libslirp
      cpus = [ "host" ]; # -cpu host; only meaningful together with accels

      # Not a `-<kind> help` registry entry like the six lists above. `-sandbox`
      # is a bare global option with no enumerable listing at all — `-sandbox
      # help` answers "Parameter 'enable' expects 'on' or 'off'" — so the check
      # exercises it by invoking it rather than by grepping a listing.
      #
      # It is worth watching precisely because nothing here pins it. QEMU only
      # registers the option when `system/qemu-seccomp.c` was compiled in, which
      # nixpkgs gates on `seccompSupport`; `leanQemu` above turns off eighteen
      # `*Support` flags and does not touch that one, so the current pass is
      # inherited from a nixpkgs default rather than chosen. Turn it off — one
      # more line in a list that has already grown past its stated scope — and
      # QEMU exits 1 at argument parsing, before a single device is created,
      # while the gate and every other assertion here still pass.
      #
      # Verbatim from the live helper argv, where it is the first option after
      # `-name claude-cowork-vm`.
      sandbox = "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny";
    };
  }
  // lib.optionalAttrs cowork {
    # Which QEMU this variant actually carries, so a consumer (or a bisect) can
    # tell a `leanQemu` build from a `qemu_kvm` one without reading the closure.
    qemu = qemuPackage;
  };

  meta = claude-desktop.meta // {
    description =
      claude-desktop.meta.description
      + (
        if cowork then
          " (FHS sandbox with the Cowork VM toolchain)"
        else
          " (FHS sandbox for MCP server tooling)"
      );
    mainProgram = pname;
  };
}
