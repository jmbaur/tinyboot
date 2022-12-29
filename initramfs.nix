{ lib, buildEnv, runCommand, cpio, xz, pkgsStatic, tinyboot, compressed ? true, ... }:
let
  paths = [ /*tinyboot*/ pkgsStatic.busybox ];
in
runCommand "tinyboot-initramfs"
{ nativeBuildInputs = [ cpio ] ++ (lib.optional compressed xz); } ''
  mkdir -p root; ${lib.concatMapStringsSep "; " (p: "cp -r ${p}/. root") paths}
  pushd root &&
    find . -print0 | cpio --null --create --format=newc >../initramfs.cpio &&
    popd
  ${if compressed then ''
  xz --check=crc32 --lzma2=dict=512KiB <initramfs.cpio >$out
  '' else ''
  cp initramfs.cpio $out
  ''}
''
