{
  lib,
  runCommand,
  OVMF,
}:

# UEFI firmware, restated under the filenames Claude Desktop's Cowork probe
# actually searches for.
#
# The probe does not look up firmware on PATH, from an environment variable, or
# relative to the app directory. It walks a hardcoded list of absolute paths and
# takes the first one `access(R_OK)` succeeds on:
#
#   Csn = ["/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_CODE.fd"]
#   async function Ast(e) {
#     for (const t of e)
#       try { return (await W.access(t, Y.constants.R_OK), t); } catch {}
#     return null;
#   }
#
# nixpkgs ships that same firmware as `$out/FV/OVMF_{CODE,VARS}.fd`, which
# matches neither entry. This derivation re-presents it as `share/OVMF/...`, so
# that a `buildFHSEnv` carrying it exposes `/usr/share/OVMF/OVMF_CODE_4M.fd`
# inside the sandbox. Nothing is rebuilt or rewritten — these are symlinks to
# the exact bytes `pkgs.OVMF.fd` produced.
#
# Why `_4M` rather than the plain spelling, when nixpkgs' file is unsuffixed:
#
#   1. It is the first entry, so it is what the app finds. Shipping only the
#      plain name works too, but relies on the second probe rather than the
#      first for no benefit.
#   2. It is true. The app derives the variables path from the code path by
#      string substitution —
#
#        function Usn(e) {
#          return e.replace("OVMF_CODE", "OVMF_VARS").replace("AAVMF_CODE", "AAVMF_VARS");
#        }
#
#      — and hands both to QEMU as the two halves of one `if=pflash` device, so
#      they have to be a matched pair from a single build. nixpkgs' CODE + VARS
#      sum to exactly 4 MiB, which is precisely what `_4M` denotes on the Debian
#      layout the app was written against. Naming them `_4M` is a statement
#      about the flash geometry, and the assertion below fails the build rather
#      than let that statement go stale: an OVMF bump to some other flash size
#      would otherwise keep building and hand QEMU a mislabelled pair.
runCommand "ovmf-fhs-${OVMF.version}"
  {
    inherit (OVMF) firmware variables;

    meta = {
      description = "OVMF firmware under the /usr/share/OVMF filenames Claude Desktop's Cowork probe searches";
      inherit (OVMF.meta) license platforms;
      maintainers = [ ];
    };
  }
  ''
    code=$(stat -Lc %s "$firmware")
    vars=$(stat -Lc %s "$variables")
    total=$((code + vars))

    if [ "$total" -ne 4194304 ]; then
      echo "ovmf-fhs: OVMF ${OVMF.version} is not a 4 MB flash build." >&2
      echo "  OVMF_CODE.fd  $code bytes" >&2
      echo "  OVMF_VARS.fd  $vars bytes" >&2
      echo "  total         $total bytes (expected 4194304)" >&2
      echo "" >&2
      echo "The _4M filenames below are a claim about flash geometry, and the app" >&2
      echo "hands both files to QEMU as one if=pflash device. Rename the pair to" >&2
      echo "match the new size, or pin an OVMF that is still a 4 MB build." >&2
      exit 1
    fi

    mkdir -p $out/share/OVMF
    ln -s "$firmware"  $out/share/OVMF/OVMF_CODE_4M.fd
    ln -s "$variables" $out/share/OVMF/OVMF_VARS_4M.fd
  ''
