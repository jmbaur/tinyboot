{ config, pkgs, lib, modulesPath, ... }: {
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];
  tinyboot.enable = true;
  tinyboot.board = "qemu-${pkgs.stdenv.hostPlatform.qemuArch}";
  boot.kernelParams = [ "console=${{ x86_64 = "ttyS0"; arm64 = "ttyAMA0"; }.${config.nixpkgs.hostPlatform.linuxArch}},115200" ];
  system.stateVersion = "23.05";
  environment.etc."keys/x509_ima.der".source = ./keys/x509_ima.der;
  specialisation.alternate.configuration.boot.kernelParams = [ "console=tty1" ]; # to provide more menu options
  boot.growPartition = true;
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.systemd-boot.enable = true;
  users.users.root.password = "";
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };
  # NOTE: make-disk-image.nix is incapable of cross-compilation
  system.build.qcow2 = import (pkgs.path + "/nixos/lib/make-disk-image.nix") {
    name = "tinyboot-test-image";
    inherit pkgs lib config;
    partitionTableType = "efi";
    format = "qcow2";
  };
}
