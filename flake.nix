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
      # The packaging revision this flake was evaluated from, for the dev
      # channel's version string. `shortRev` is absent on a dirty tree, which
      # is exactly when saying so is useful.
      channelRev = self.shortRev or self.dirtyShortRev or "dirty";
    in
    {
      overlays.default = final: _prev: {
        claude-desktop = final.callPackage ./pkgs/claude-desktop.nix { };
        # claude-desktop is taken from `final`, so an override of the base
        # package (e.g. a different passwordStore) flows into the FHS variant.
        claude-desktop-fhs = final.callPackage ./pkgs/claude-desktop-fhs.nix { };

        # The dev channel: the same upstream .deb, built from this branch's
        # packaging. Same binary, same desktop entry, different pname and a
        # version that sorts below stable — so it can be installed and tested
        # without a consumer rewriting its wrappers, and without a stable
        # consumer ever resolving to it by accident.
        claude-desktop-dev = final.callPackage ./pkgs/claude-desktop.nix {
          channel = "dev";
          inherit channelRev;
        };
        claude-desktop-dev-fhs = final.callPackage ./pkgs/claude-desktop-fhs.nix {
          claude-desktop = final.claude-desktop-dev;
        };

        # Cowork-enabled variant. Same application and same FHS sandbox as
        # claude-desktop-fhs, plus QEMU, OVMF and virtiofsd at the paths the
        # app's Linux virtualization probe searches.
        #
        # A separate output rather than a change to claude-desktop-fhs because
        # the VM toolchain roughly doubles that variant's marginal closure, and
        # the two audiences do not overlap: wanting `npx` to resolve says
        # nothing about wanting a hypervisor. Nothing here alters
        # claude-desktop or claude-desktop-fhs, which build to the same store
        # paths they did before this existed.
        claude-desktop-cowork = final.callPackage ./pkgs/claude-desktop-fhs.nix {
          cowork = true;
          ovmf-fhs = final.callPackage ./pkgs/ovmf-fhs.nix { };

          # The trimmed QEMU is the default here, not an opt-in. It halves the
          # marginal closure, and everything the helper's argv names survives
          # the trim — asserted by checks.cowork-fhs-paths against this build,
          # and exercised end to end by a booted guest (see t14/). The cost is
          # a source build no cache carries; the untrimmed one is one override
          # away:
          #
          #     claude-desktop-cowork.override { leanQemu = false; }
          leanQemu = true;
        };
      };

      packages = forAllSystems (
        system:
        let
          pkgs = (pkgsFor system).extend self.overlays.default;
        in
        {
          inherit (pkgs)
            claude-desktop
            claude-desktop-fhs
            claude-desktop-cowork
            claude-desktop-dev
            claude-desktop-dev-fhs
            ;
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

          # Static regression guard for the dlopen'd libraries: resolve,
          # reference and novelty assertions against a fresh scan of the
          # shipped ELFs. The rationale, and the limits of a string scan, are
          # documented at the top of the file itself.
          dlopen-runpath = pkgs.callPackage ./pkgs/dlopen-runpath.nix {
            inherit claude-desktop;
          };

          # Both Cowork variants. The default is now the trimmed QEMU — the
          # build with a real reason to fail these assertions — so the base
          # check covers the risk rather than the safe case. The second leg
          # overrides back to the cached `qemu_kvm`: it is the supported
          # escape hatch, and an escape hatch nothing evaluates is one that
          # breaks unnoticed and is discovered by whoever reaches for it.
          cowork-fhs-paths = pkgs.callPackage ./pkgs/cowork-fhs-paths.nix {
            claude-desktop-cowork = self.packages.${system}.claude-desktop-cowork;
          };
          cowork-fhs-paths-full-qemu = pkgs.callPackage ./pkgs/cowork-fhs-paths.nix {
            claude-desktop-cowork = self.packages.${system}.claude-desktop-cowork.override {
              leanQemu = false;
            };
          };
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
