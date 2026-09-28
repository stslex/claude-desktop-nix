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
          # Guards the invariants that are easy to regress silently and
          # impossible to notice from a green build: the wrapper must carry the
          # password-store flag, every flag it passes must be one the shipped
          # Chromium still knows, and it must never acquire --no-sandbox.
          wrapper-flags =
            pkgs.runCommand "claude-desktop-wrapper-flags"
              {
                nativeBuildInputs = [
                  pkgs.binutils # strings
                  pkgs.desktop-file-utils
                ];
              }
              ''
                wrapper=${claude-desktop}/bin/claude-desktop
                test -x "$wrapper" || { echo "wrapper missing or not executable"; exit 1; }

                grep -q -- '--password-store=' "$wrapper" \
                  || { echo "FAIL: --password-store= not in wrapper"; exit 1; }

                # Chromium ignores a switch it does not know, silently. The
                # wrapper carried --ozone-platform-hint=auto for several upstream
                # releases after Chromium had dropped it, and the assertion
                # that it was present passed the whole time. So each flag the
                # wrapper adds has to be named by the executable it runs.
                #
                # A substring match on purpose: switch names are
                # tail-merged into longer strings often enough that an
                # exact-line match would fail on a live flag. That leans
                # towards passing, which is acceptable here. The failure this
                # catches is a switch gone from the binary altogether.
                exe=${claude-desktop}/lib/claude-desktop/claude-desktop
                strings -a "$exe" > exe-strings
                flags=0
                while IFS= read -r flag; do
                  name=''${flag#--}
                  name=''${name%%=*}
                  flags=$((flags + 1))
                  grep -qF -- "$name" exe-strings \
                    || { echo "FAIL: wrapper passes $flag, but the executable does not name '$name'"; exit 1; }
                done < <(strings -a "$wrapper" | grep -E '^--[a-z][a-z0-9-]*(=|$)')
                test "$flags" -gt 0 \
                  || { echo "FAIL: found no flags in the wrapper; the extraction above is broken"; exit 1; }

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

          # The places where the payload assumes a Debian filesystem and the
          # packaging can do something about it, each asserted by behaviour
          # rather than by grepping for the fix. The ones packaging cannot
          # reach — absolute paths inside app.asar — are in the README under
          # "NixOS host requirements".
          nixos-host-paths =
            let
              withSearchProvider = claude-desktop.override { gnomeSearchProvider = true; };
            in
            pkgs.runCommand "claude-desktop-nixos-host-paths" { } ''
              app=${claude-desktop}

              # 1. The $BROWSER shim Code sessions get runs clean where
              #    /usr/bin/true does not exist — which includes this build
              #    sandbox. Run it for real, against a stand-in xdg-open that
              #    records what it was asked to open. Before the fix this
              #    printed "//usr/bin/true: No such file or directory" three
              #    times per call.
              mkdir fake
              printf '#!%s\nprintf "%%s\\n" "$1" > %s/opened\n' \
                ${pkgs.runtimeShell} "$PWD" > fake/xdg-open
              chmod +x fake/xdg-open
              env -i PATH=${pkgs.coreutils}/bin:$PWD/fake HOME=$PWD \
                $app/lib/claude-desktop/resources/claude-browser-shim.js \
                https://example.com/opened-by-shim 2> shim-stderr \
                || { echo "FAIL: the browser shim exited non-zero"; cat shim-stderr; exit 1; }
              if [ -s shim-stderr ]; then
                echo "FAIL: the browser shim wrote to stderr:"
                cat shim-stderr
                exit 1
              fi
              grep -qx 'https://example.com/opened-by-shim' opened \
                || { echo "FAIL: the browser shim did not hand the URL to xdg-open"; exit 1; }

              # 2. Every command the app runs by bare name, or by an absolute
              #    path only envfs can resolve, is reachable from the PATH the
              #    wrapper appends — and the wrapper really appends it.
              grep -qF -- '${claude-desktop.wrapperPath}' $app/bin/claude-desktop \
                || { echo "FAIL: the wrapper does not carry passthru.wrapperPath"; exit 1; }
              IFS=: read -ra dirs <<< '${claude-desktop.wrapperPath}'
              for tool in gio openssl secret-tool ps; do
                found=""
                for d in "''${dirs[@]}"; do
                  if [ -x "$d/$tool" ]; then found=$d/$tool; break; fi
                done
                test -n "$found" \
                  || { echo "FAIL: $tool is not on the wrapper's appended PATH"; exit 1; }
                echo "ok      $tool -> $found"
              done

              # 3. The GNOME search provider: off by default, and when on,
              #    installed where GNOME Shell and the session bus look, with
              #    both /usr paths pointed into the store and its desktop id
              #    naming the entry this package installs.
              test ! -e $app/share/dbus-1 \
                || { echo "FAIL: the default package installs the search provider"; exit 1; }
              sp=${withSearchProvider}
              ini=$sp/share/gnome-shell/search-providers/com.anthropic.Claude.search-provider.ini
              svc=$sp/share/dbus-1/services/com.anthropic.Claude.SearchProvider.service
              test -f "$ini" && test -f "$svc" \
                || { echo "FAIL: search provider files missing"; exit 1; }
              id=$(sed -n 's/^DesktopId=//p' "$ini")
              test -f "$sp/share/applications/$id" \
                || { echo "FAIL: search provider names desktop id '$id', which is not installed"; exit 1; }
              read -r gjsBin flag script <<< "$(sed -n 's/^Exec=//p' "$svc")"
              test -x "$gjsBin" && test "$flag" = -m && test -f "$script" \
                || { echo "FAIL: search provider Exec does not resolve: $gjsBin $flag $script"; exit 1; }
              case "$gjsBin $script" in
                /nix/store/*' '/nix/store/*) ;;
                *) echo "FAIL: search provider Exec is not a store path: $gjsBin $script"; exit 1 ;;
              esac

              touch $out
            '';

          # Static regression guard for the dlopen'd libraries: resolve,
          # reference and novelty assertions against a fresh scan of the
          # shipped ELFs. The rationale, and the limits of a string scan, are
          # documented at the top of the file itself.
          dlopen-runpath = pkgs.callPackage ./pkgs/dlopen-runpath.nix {
            inherit claude-desktop;
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
