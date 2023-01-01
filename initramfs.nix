{ lib, buildEnv, runCommand, rsync, cpio, xz, pkgsStatic, tinyboot, compressed ? true, ... }:
runCommand "tinyboot-initramfs" { nativeBuildInputs = [ cpio rsync ] ++ (lib.optional compressed xz); } ''
  mkdir -p root/{etc,sbin,bin,mnt,dev/pts,proc,sys,tmp}
  cp ${./inittab} root/etc/inittab
  rsync -aP ${pkgsStatic.busybox}/ ${tinyboot}/ root/
  pushd root &&
    find . -print0 | cpio --null --create --format=newc >../initramfs.cpio &&
    popd
  ${if compressed then "xz --check=crc32 --lzma2=dict=512KiB <initramfs.cpio >$out" else "cp initramfs.cpio $out"}
''
