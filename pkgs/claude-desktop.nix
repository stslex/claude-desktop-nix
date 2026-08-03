{
  lib,
  stdenv,
  fetchurl,

  # nativeBuildInputs
  dpkg,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,

  # buildInputs — every entry below is justified by a "not found" soname in the
  # `ldd` sweep of the .deb payload (see README "Dependency provenance").
  # Nothing here is copied from another package's dependency list.
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  glib,
  gtk3,
  libcap_ng,
  libdrm,
  libgbm,
  libseccomp,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  nspr,
  nss,
  pango,
  systemdLibs,

  # Runtime-only (dlopen'd; invisible to autoPatchelfHook — see runtimeLibs).
  gdk-pixbuf,
  krb5,
  libdbusmenu,
  libglvnd,
  libnotify,
  libpulseaudio,
  libsecret,
  libva,
  libxcursor,
  libxtst,
  pciutils,
  speechd,
  util-linux,
  vulkan-loader,

  addDriverRunpath,

  sources ? lib.importJSON ../sources.json,

  # Chromium's os_crypt backend. Justification:
  #
  # The bundled binary supports exactly two real backends — libsecret
  # (dlopen of `libsecret-1.so.0`, key_storage_libsecret.cc) and KWallet
  # (pure D-Bus, kwallet_dbus.cc) — plus `basic`, which is *plaintext* in
  # ~/.config/Claude. We default to `gnome-libsecret` rather than `detect`
  # because `detect` keys off XDG_CURRENT_DESKTOP: on GNOME and KDE it picks
  # the right thing, but on wlroots compositors (sway, Hyprland, river) it
  # matches no known desktop and silently degrades to `basic` — i.e. your
  # session token lands on disk in the clear, with no error.
  #
  # `gnome-libsecret` instead talks to whatever implements the freedesktop
  # Secret Service API — gnome-keyring, KeePassXC, or KWallet's secret-service
  # bridge — so it works on wlroots sessions too. When no Secret Service is
  # running at all, Chromium falls back to `basic` on its own, which is the
  # same place `detect` would have landed. So this default is never worse and
  # is frequently better.
  #
  # KDE users who run kwalletd *without* the secret-service bridge should
  # override: `claude-desktop.override { passwordStore = "kwallet6"; }`.
  passwordStore ? "gnome-libsecret",

  # Extra flags appended to the wrapper, e.g. [ "--enable-features=..." ].
  commandLineArgs ? [ ],

  # Build a variant that uses the system SUID sandbox helper instead of the
  # namespace sandbox. Off by default; the default output is unchanged.
  #
  # Only useful on a host that cannot use the namespace sandbox (hardened
  # kernel, `security.allowUserNamespaces = false`, or an AppArmor userns
  # restriction). There the default output aborts with
  #
  #   FATAL: The SUID sandbox helper binary was found, but is not configured
  #   correctly ... owned by root and has mode 4755
  #
  # because Nix strips setuid bits from store paths. Pair this with
  # `security.chromiumSuidSandbox.enable = true;`, which provides a setuid
  # helper at /run/wrappers/bin/chrome-sandbox.
  #
  # Both halves are required and neither works alone. Measured directly
  # (setuid_sandbox_host.cc line 166 vs 156): Chromium reads
  # CHROME_DEVEL_SANDBOX *only* when no chrome-sandbox sits next to the
  # executable. Setting the variable while the bundled helper is still
  # present is silently ignored — so this option must also delete it.
  suidSandbox ? false,
}:

let
  source =
    sources.systems.${stdenv.hostPlatform.system} or (throw ''
      claude-desktop: no upstream .deb recorded for ${stdenv.hostPlatform.system}.
      Only x86_64-linux is packaged today; see the arm64 TODO in flake.nix.
    '');

  # Libraries the app dlopen()s at runtime. autoPatchelfHook cannot discover
  # these on its own — they appear nowhere in DT_NEEDED, only as string
  # literals in the binary — so they are appended to the RUNPATH explicitly
  # (see runtimeRpath) or the corresponding feature silently no-ops. Each is a
  # soname string-scanned out of the shipped executable.
  runtimeLibs = [
    libsecret # libsecret-1.so.0   — safeStorage / os_crypt keyring
    libnotify # libnotify.so.4     — desktop notifications
    gdk-pixbuf # libgdk_pixbuf-2.0.so.0
    libpulseaudio # libpulse.so.0      — audio out
    libglvnd # libGL.so.1, libEGL.so.1, libGLESv2.so.2
    vulkan-loader # libvulkan.so.1
    libva # libva.so, libva-drm.so — VA-API video decode
    pciutils # libpci.so.3        — GPU enumeration
    krb5 # libgssapi_krb5.so.2 — SPNEGO/Negotiate auth
    libdbusmenu # libdbusmenu-glib.so.4 — tray menus
    speechd # libspeechd.so.2    — accessibility TTS
    util-linux # libuuid.so.1       — listed in the .deb's Depends
    libxtst # libXtst.so.6       — listed in the .deb's Depends
    libxcursor # libXcursor.so.1
    libx11 # libX11-xcb.so.1
    libxcb # libxcb-{dri3,glx,present,sync}
  ];

  # The same set, plus the GPU driver link, as a RUNPATH fragment. This is
  # appended to every bundled ELF instead of being exported as
  # LD_LIBRARY_PATH from the wrapper.
  #
  # Why RUNPATH and not LD_LIBRARY_PATH: dlopen() resolves against the
  # calling object's own DT_RUNPATH, so the app still finds these — but
  # RUNPATH is a property of the ELF file, not of the environment, so it is
  # NOT inherited by child processes. The app spawns MCP servers, an
  # integrated terminal and cowork-linux-helper; with LD_LIBRARY_PATH those
  # children searched our krb5 / util-linux / libx11 ahead of their own
  # DT_RUNPATH (LD_LIBRARY_PATH outranks DT_RUNPATH), which can load a
  # different soname version than the child was linked against. Moving to
  # RUNPATH removes that shadowing by construction rather than narrowing it.
  runtimeRpath = (map (p: "${lib.getLib p}/lib") runtimeLibs) ++ [
    "${addDriverRunpath.driverLink}/lib"
  ];
in
stdenv.mkDerivation (finalAttrs: {
  pname = "claude-desktop";
  version = sources.version;

  src = fetchurl { inherit (source) url hash; };

  # The .deb is `ar` + data.tar.xz; the payload keeps its ./usr prefix.
  #
  # `dpkg-deb -x` cannot be used directly: it extracts with tar -p, and the
  # archive carries chrome-sandbox as 4755 root:root. The Nix build user is
  # unprivileged, so the setuid chmod fails and aborts the whole extraction.
  # Piping the payload tarball out and extracting it ourselves with
  # --no-same-permissions applies the umask instead, which drops exactly the
  # setuid bit and leaves every other mode intact. (Nix would strip that bit
  # from the store path regardless — see the chrome-sandbox note below.)
  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --fsys-tarfile "$src" \
      | tar -x --no-same-owner --no-same-permissions
    runHook postUnpack
  '';
  sourceRoot = ".";

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
    # Electron still needs GSettings schemas and the gdk-pixbuf loader cache
    # for GTK file chooser / theming paths. We do the final wrap ourselves, so
    # this hook only collects the env args (see dontWrapGApps).
    wrapGAppsHook3
  ];

  buildInputs = [
    # --- from `ldd claude-desktop` -----------------------------------------
    glib # libglib-2.0.so.0, libgobject-2.0.so.0, libgio-2.0.so.0
    nspr # libnspr4.so
    nss # libnss3.so, libnssutil3.so, libsmime3.so
    atk # libatk-1.0.so.0
    at-spi2-atk # libatk-bridge-2.0.so.0
    at-spi2-core # libatspi.so.0
    cups # libcups.so.2
    dbus # libdbus-1.so.3
    cairo # libcairo.so.2
    gtk3 # libgtk-3.so.0
    pango # libpango-1.0.so.0
    libx11 # libX11.so.6
    libxcomposite # libXcomposite.so.1
    libxdamage # libXdamage.so.1
    libxext # libXext.so.6
    libxfixes # libXfixes.so.3
    libxrandr # libXrandr.so.2
    libgbm # libgbm.so.1
    expat # libexpat.so.1
    libxcb # libxcb.so.1
    libxkbcommon # libxkbcommon.so.0
    systemdLibs # libudev.so.1
    alsa-lib # libasound.so.2

    # --- from `ldd` of the other shipped ELFs -------------------------------
    (lib.getLib stdenv.cc.cc) # libstdc++.so.6 <- node-pty's pty.node
    libseccomp # libseccomp.so.2 <- resources/virtiofsd
    libcap_ng # libcap-ng.so.0  <- resources/virtiofsd

    # libgbm pulls libdrm in, but the .deb Depends on it explicitly and the
    # GPU process resolves it directly; keep it named rather than incidental.
    libdrm
  ];

  # A 217 MB Electron binary plus prebuilt .node modules: stripping buys
  # nothing and has historically corrupted V8 snapshots.
  dontStrip = true;
  dontConfigure = true;
  dontBuild = true;

  # Collect gappsWrapperArgs but let us own the single makeWrapper call.
  dontWrapGApps = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/bin $out/share
    cp -r usr/lib/claude-desktop $out/lib/claude-desktop
    cp -r usr/share/applications $out/share/applications
    cp -r usr/share/icons $out/share/icons
    install -Dm644 usr/share/doc/claude-desktop/copyright \
      $out/share/doc/${finalAttrs.pname}/copyright

    # chrome-sandbox ships 4755 root:root in the .deb. Nix strips setuid bits
    # from store paths unconditionally, so it lands here as a plain 0755
    # binary — that is fine and is *not* a broken sandbox:
    #
    # Chromium only consults the SUID helper when the namespace sandbox is
    # unavailable (ZygoteHostImpl::Init computes `using_suid_sandbox` as
    # "SUID path is non-empty AND namespace sandbox unsupported"). NixOS
    # permits unprivileged user namespaces and ships no AppArmor userns
    # restriction, so the namespace sandbox is always taken and the helper's
    # mode is never even examined. Upstream's own postinst calls the SUID
    # helper a "belt-and-suspenders" fallback for Ubuntu 24.04+ / AppArmor 3.x.
    #
    # Hence: no --no-sandbox, and no setuid wrapper. If you have deliberately
    # set `user.max_user_namespaces = 0`, restore it — do not disable the
    # sandbox.
    chmod 0755 $out/lib/claude-desktop/chrome-sandbox
    ${lib.optionalString suidSandbox ''

      # suidSandbox: remove the bundled helper so Chromium falls through to
      # CHROME_DEVEL_SANDBOX (set in the wrapper below). See the option's
      # comment for why deleting it is mandatory rather than cosmetic.
      rm $out/lib/claude-desktop/chrome-sandbox
    ''}

    # Upstream ships `Exec=claude-desktop %U`, which only resolves if the
    # binary is on PATH. Pin all three Exec lines (main entry + the NewChat
    # and NewCode desktop actions) to the store path so the entry works when
    # the .desktop is linked into a profile the binary is not in.
    substituteInPlace $out/share/applications/com.anthropic.Claude.desktop \
      --replace-fail 'Exec=claude-desktop ' "Exec=$out/bin/claude-desktop "

    runHook postInstall
  '';

  # Appended to the RUNPATH of every ELF autoPatchelfHook patches. This is the
  # hook's own mechanism — doing it by hand in postFixup does not work, because
  # autoPatchelfHook registers itself in postFixupHooks and therefore runs
  # *after* postFixup, calling --set-rpath and discarding anything added there.
  appendRunpaths = runtimeRpath;

  # Built as one escaped list rather than interpolated shell lines: an
  # optional fragment that expands to "" would otherwise leave a blank line
  # after a trailing backslash, silently ending the makeWrapper command.
  postFixup =
    let
      wrapperArgs = [
        "--add-flags"
        "--ozone-platform-hint=auto"
        "--add-flags"
        "--password-store=${passwordStore}"
      ]
      ++ lib.optionals suidSandbox [
        "--set"
        "CHROME_DEVEL_SANDBOX"
        "/run/wrappers/bin/chrome-sandbox"
      ]
      ++ lib.concatMap (a: [
        "--add-flags"
        a
      ]) commandLineArgs;
    in
    ''
      makeWrapper $out/lib/claude-desktop/claude-desktop $out/bin/claude-desktop \
        "''${gappsWrapperArgs[@]}" \
        ${lib.escapeShellArgs wrapperArgs}
    '';

  passthru = {
    inherit (source) url;
    updateScript = ./update.sh;

    # ---- consumed by checks.dlopen-runpath ------------------------------
    #
    # The guard rescans the shipped ELFs for soname-shaped strings on every
    # run and reconciles the scan against these three lists, so a list that
    # stops describing the binary fails instead of quietly passing. Between
    # them they must account for every soname the payload names that is not
    # already covered by DT_NEEDED (autoPatchelfHook's job) or bundled with
    # the app.
    #
    # Sonames this package is responsible for providing: named by a shipped
    # ELF, covered by no DT_NEEDED entry, and required to resolve from the
    # RUNPATH of the object that opens them.
    #
    # libsecret-1.so.0 is the one that motivated the guard: lose it and
    # os_crypt falls back from a keyring-derived v11 key to the
    # hardcoded-password v10 path, i.e. the session token silently stops being
    # protected while everything still appears to work. Most of the others
    # fail the same way — dlopen returns NULL and a feature switches itself
    # off — which is exactly the class a green build cannot catch.
    dlopenSonames = [
      "libsecret-1.so.0" # os_crypt keyring -> v11 vs v10
      "libnotify.so.4" # desktop notifications
      "libgdk_pixbuf-2.0.so.0" # image loading
      "libgdk-3.so.0" # GTK loader, alongside DT_NEEDED libgtk-3.so.0
      "libpulse.so.0" # audio output
      "libGL.so.1" # GPU compositing
      "libEGL.so.1"
      "libGLESv2.so.2"
      "libvulkan.so.1" # Vulkan backend
      "libva.so.2" # VA-API hardware video decode
      "libva-drm.so.2"
      "libpci.so.3" # GPU enumeration
      "libgssapi_krb5.so.2" # SPNEGO / Negotiate auth
      "libdbusmenu-glib.so.4" # tray menus
      "libspeechd.so.2" # accessibility TTS
      "libnssckbi.so" # NSS builtin trust roots
      "libXcursor.so.1"
      "libX11-xcb.so.1"
      "libxcb-dri3.so.0"
      "libxcb-glx.so.0"
      "libxcb-present.so.0"
      "libxcb-sync.so.1"
    ];

    # Held to the resolve assertion but exempt from the reference assertion:
    # upstream's `Depends` lists them, so runtimeLibs keeps providing them,
    # but no string in any shipped ELF names them (rechecked at 1.24012.9).
    # Keeping them here asserts they stay reachable without claiming a
    # reference the scan cannot show.
    dlopenSonamesDependsOnly = [
      "libuuid.so.1"
      "libXtst.so.6"
    ];

    # Named by the payload and deliberately NOT provided. Every entry is a
    # conscious "no" with a reason; anything named by the payload and absent
    # from all three lists fails the guard, so an upstream bump that starts
    # dlopen()ing something new cannot pass unnoticed.
    dlopenSonamesUnprovided = [
      # Probe alternates: the binary tries several sonames for one feature and
      # uses whichever it finds. The one we do provide is in dlopenSonames.
      "libnotify.so.1" # provided: libnotify.so.4
      "libnotify.so.5"
      "libgssapi.so.1" # Heimdal; provided: MIT libgssapi_krb5.so.2
      "libgssapi.so.2"
      "libgssapi.so.4"
      "libgtk-4.so.1" # GTK4; the payload links GTK3 (DT_NEEDED)
      "libunity.so.4" # Ubuntu Unity launcher API; no such desktop
      "libunity.so.6"
      "libunity.so.9"

      # Supplied by the impure driver link (addDriverRunpath, last RUNPATH
      # entry) at runtime, never by the closure — nothing to assert in a
      # sandboxed build.
      "libGLX_nvidia.so.0"
      "libvulkan_intel.so"
      "libvulkan_radeon.so"
      "libvulkan_freedreno.so"

      # glibc's own name-service modules; they ship with libc, not with us.
      "libnss_compat.so.2"
      "libnss_files.so.2"

      # Optional Google components upstream fetches at runtime; nixpkgs
      # packages none of them, and absent they are simply unavailable.
      "libsoda.so" # on-device speech
      "libLiteRtGpuAccelerator.so"
      "libLiteRtVulkanAccelerator.so"
      "libLiteRtWebGpuAccelerator.so"

      # Crash-upload transport, named only by chrome_crashpad_handler. No
      # crash server is configured, so the transport is never constructed.
      "libcurl.so.4"
      "libcurl-gnutls.so.4"
      "libcurl-nss.so.4"

      # Injected by hand when someone is debugging a GPU capture.
      "librenderdoc.so"

      # Named only by the bundled SwiftShader (software Vulkan) for its own
      # window-system integration, not by the app.
      "libwayland-client.so.0"
      "libxcb-shm.so.0"
    ];
  };

  meta = {
    description = "Desktop application for Claude.ai";
    longDescription = ''
      Anthropic's first-party Claude Desktop build for Linux, repackaged from
      the official .deb published at downloads.claude.ai. This is a native
      Linux binary — nothing is patched, spoofed, or emulated; the derivation
      only relocates the payload into the store and resolves its shared
      libraries.
    '';
    homepage = "https://claude.ai/download";
    downloadPage = "https://claude.ai/download";
    changelog = null;
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "claude-desktop";
    maintainers = [ ];
    # TODO(arm64): upstream publishes claude-desktop_<v>_arm64.deb in the same
    # pool (dists/stable/main/binary-arm64/Packages, currently at parity with
    # amd64). Adding it needs a second sources.json entry plus an updater that
    # only bumps when *both* arches carry the same version. Deliberately not
    # implemented in v1.
    platforms = [ "x86_64-linux" ];
  };
})
