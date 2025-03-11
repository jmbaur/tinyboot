{ lib, pkgs, ... }:
let
  tinyboot = pkgs."tinyboot-qemu-${pkgs.stdenv.hostPlatform.qemuArch}";
in
{
  virtualisation = {
    directBoot.enable = false;
    qemu.options = [
      "-kernel ${tinyboot.linux}/kernel"
      "-initrd ${tinyboot.initrd}/tboot-loader.cpio"
    ] ++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [ "-machine q35" ];
  };
}
