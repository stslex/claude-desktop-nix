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
}:

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
buildFHSEnv {
  pname = "claude-desktop-fhs";
  inherit (claude-desktop) version;

  targetPkgs = _: [
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
  ];

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
                     "$out/bin/claude-desktop-fhs"
  '';

  meta = claude-desktop.meta // {
    description = "${claude-desktop.meta.description} (FHS sandbox for MCP server tooling)";
    mainProgram = "claude-desktop-fhs";
  };
}
