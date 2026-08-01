{
  description = "Claude Desktop for Linux, repackaged from Anthropic's official .deb";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      # TODO(arm64): upstream also publishes aarch64 .debs (see the note in
      # pkgs/claude-desktop.nix meta). Add "aarch64-linux" here once
      # sources.json carries that entry.
      systems = [ "x86_64-linux" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      # The package is unfree, so a bare `nix build .#default` against
      # nixpkgs.legacyPackages would refuse to evaluate. Instantiate our own
      # nixpkgs with allowUnfree set for *this flake's* outputs only — consumers
      # who apply overlays.default keep whatever config they already have.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
    in
    {
      overlays.default = final: _prev: {
        claude-desktop = final.callPackage ./pkgs/claude-desktop.nix { };
        # claude-desktop is taken from `final`, so an override of the base
        # package (e.g. a different passwordStore) flows into the FHS variant.
        claude-desktop-fhs = final.callPackage ./pkgs/claude-desktop-fhs.nix { };
      };

      packages = forAllSystems (
        system:
        let
          pkgs = (pkgsFor system).extend self.overlays.default;
        in
        {
          inherit (pkgs) claude-desktop claude-desktop-fhs;
          default = pkgs.claude-desktop;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          claude-desktop = self.packages.${system}.claude-desktop;
        in
        {
          # Guards the two invariants that are easy to regress silently and
          # impossible to notice from a green build: the wrapper must carry the
          # Ozone + password-store flags, and must never acquire --no-sandbox.
          wrapper-flags =
            pkgs.runCommand "claude-desktop-wrapper-flags"
              {
                nativeBuildInputs = [ pkgs.desktop-file-utils ];
              }
              ''
                wrapper=${claude-desktop}/bin/claude-desktop
                test -x "$wrapper" || { echo "wrapper missing or not executable"; exit 1; }

                grep -q -- '--ozone-platform-hint=auto' "$wrapper" \
                  || { echo "FAIL: --ozone-platform-hint=auto not in wrapper"; exit 1; }
                grep -q -- '--password-store=' "$wrapper" \
                  || { echo "FAIL: --password-store= not in wrapper"; exit 1; }

                if grep -q -- '--no-sandbox' "$wrapper"; then
                  echo "FAIL: wrapper passes --no-sandbox; the namespace sandbox must be used instead"
                  exit 1
                fi

                # chrome-sandbox must still be present (Chromium stats it on
                # systems where the namespace sandbox is unavailable).
                test -f ${claude-desktop}/lib/claude-desktop/chrome-sandbox \
                  || { echo "FAIL: chrome-sandbox missing from output"; exit 1; }

                desktop-file-validate \
                  ${claude-desktop}/share/applications/com.anthropic.Claude.desktop

                # Every Exec= must be an absolute store path after the rewrite.
                if grep -E '^Exec=' \
                     ${claude-desktop}/share/applications/com.anthropic.Claude.desktop \
                   | grep -qv '^Exec=/nix/store/'; then
                  echo "FAIL: a .desktop Exec= line was not rewritten to a store path"
                  exit 1
                fi

                touch $out
              '';

          # Static regression guard for the dlopen'd libraries.
          #
          # Why this exists: `nix build` stays green when a dlopen'd soname
          # stops resolving, because dlopen failure is a runtime event, not a
          # link error. The specific regression it guards is silent and
          # security-relevant — if libsecret-1.so.0 drops out of the RUNPATH
          # (an Electron bump changing layout, someone editing runtimeLibs,
          # appendRunpaths breaking), os_crypt falls back from a
          # keyring-derived v11 key to the hardcoded-password v10 path and
          # the session token quietly stops being protected.
          #
          # Deliberately static: it resolves each soname against the RUNPATH
          # entries of the ELF that dlopen()s them, rather than launching the
          # app. An Xvfb launch check would be strictly worse here — it needs
          # a display, a D-Bus session and a live Secret Service provider to
          # tell v10 from v11, none of which exist in the build sandbox, and
          # it would be slow and flaky in exchange for testing the same
          # property this resolves directly.
          dlopen-runpath =
            pkgs.runCommand "claude-desktop-dlopen-runpath"
              {
                nativeBuildInputs = [ pkgs.patchelf ];
                sonames = claude-desktop.dlopenSonames;
              }
              ''
                elf=${claude-desktop}/lib/claude-desktop/claude-desktop
                test -f "$elf" || { echo "FAIL: main executable missing"; exit 1; }

                runpath=$(patchelf --print-rpath "$elf")
                echo "RUNPATH has $(printf '%s' "$runpath" | tr ':' '\n' | grep -c .) entries"

                IFS=: read -ra dirs <<< "$runpath"

                # An empty RUNPATH element means $ORIGIN-relative "current
                # directory" at load time — the same class of bug as an empty
                # LD_LIBRARY_PATH element. Never acceptable.
                for d in "''${dirs[@]}"; do
                  if [ -z "$d" ]; then
                    echo "FAIL: RUNPATH contains an empty element (resolves to cwd)"
                    exit 1
                  fi
                done

                rc=0
                for soname in $sonames; do
                  hit=""
                  for d in "''${dirs[@]}"; do
                    if [ -e "$d/$soname" ]; then hit="$d"; break; fi
                  done
                  if [ -n "$hit" ]; then
                    printf '  ok      %-24s -> %s\n' "$soname" "$hit"
                  else
                    printf '  FAIL    %-24s unresolvable from RUNPATH\n' "$soname"
                    rc=1
                  fi
                done

                if [ $rc -ne 0 ]; then
                  echo
                  echo "One or more dlopen'd sonames no longer resolve. This does NOT"
                  echo "break the build at runtime with an error — the corresponding"
                  echo "feature silently switches off. For libsecret-1.so.0 that means"
                  echo "the session token drops from v11 to v10 obfuscation."
                  exit 1
                fi

                touch $out
              '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              curl
              jq
              dpkg
              nix-prefetch
              nixfmt
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
