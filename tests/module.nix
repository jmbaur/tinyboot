{
  config,
  pkgs,
  ...
}:

let
  tinybootKernel = pkgs.callPackage ./kernel.nix { };
in
{
  imports = [ ../nixos ];

  boot.kernelPackages = pkgs.linuxPackages_6_19;

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
  ];
}
