{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (pkgs.stdenv.hostPlatform) isAarch64;

  tinybootKernel = pkgs.callPackage ./kernel.nix { };
in
{
  imports = [ ../nixos ];

  boot.kernelPackages = pkgs.linuxPackages_6_18;

  system.switch.enable = true;

  boot.loader.tinyboot.enable = true;

  # can't use this cause this doesn't let us customize our kernel
  virtualisation.directBoot.enable = false;

  system.build = { inherit tinybootKernel; };
  virtualisation.graphics = false;
  virtualisation.tpm.enable = true;
  virtualisation.qemu.options = [
    "-kernel ${tinybootKernel}/${config.system.boot.loader.kernelFile}"
    "-initrd ${pkgs.tinyboot}/${pkgs.tinyboot.initrdFile}"
  ]
  # TODO(jared): make work with -cpu max
  ++ lib.optionals isAarch64 [ "-cpu cortex-a53" ];
}
