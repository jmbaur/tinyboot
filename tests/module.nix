{ lib, pkgs, ... }:
{
  virtualisation = {
    directBoot.enable = false;

    # The bios option wants a package with a bios.bin file in it.
    bios = pkgs.runCommand "tinyboot-bios.bin" { } ''
      install -D ${pkgs."tinyboot-qemu-${pkgs.stdenv.hostPlatform.qemuArch}"} $out/bios.bin
    '';
    qemu.options = lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [ "-machine q35" ];
  };
}
