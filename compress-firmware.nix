# This is adapted from https://github.com/nixos/nixpkgs/blob/5e4947a31bd21b33ccabcb9ff06d685b68d1e9c4/pkgs/build-support/kernel/compress-firmware.nix,
# but dereferences all symlinks so that the zig build system is capable of
# including all paths we want. See https://github.com/ziglang/zig/blob/53216d2f22053ca94a68f5da234038c01f73d60f/lib/std/Build/Step/WriteFile.zig#L232.

{
  runCommand,
  lib,
  zstd,
}:

firmwares:

let
  compressor = {
    ext = "xz";
    nativeBuildInputs = [ ];
    cmd = file: target: ''xz -9c -T1 -C crc32 --lzma2=dict=2MiB "${file}" > "${target}"'';
  };
in

runCommand "firmware-xz"
  {
    allowedRequisites = [ ];
    inherit (compressor) nativeBuildInputs;
  }
  (
    lib.concatLines (
      map (firmware: ''
        mkdir -p $out/lib
        (cd ${firmware} && find lib/firmware -type d -print0) |
            (cd $out && xargs -0 mkdir -v --)
        (cd ${firmware} && find lib/firmware -type f -print0) |
            (cd $out && xargs -0rtP "$NIX_BUILD_CORES" -n1 \
                sh -c '${compressor.cmd "${firmware}/$1" "$1.${compressor.ext}"}' --)
        (cd ${firmware} && find lib/firmware -type l) | while read link; do
            target="$(readlink "${firmware}/$link")"
            if [ -f "${firmware}/$link" ]; then
              cp -vL -- "''${target/^${firmware}/$out}.${compressor.ext}" "$out/$link.${compressor.ext}"
            else
              echo HI
              cp -vrL -- "''${target/^${firmware}/$out}" "$out/$link"
            fi
        done

        find $out

        echo "Checking for broken symlinks:"
        find -L $out -type l -print -execdir false -- '{}' '+'
      '') firmwares
    )
  )
