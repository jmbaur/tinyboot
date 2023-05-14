{ config, pkgs, lib, modulesPath, ... }: {
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];
  system.stateVersion = "23.05";
  environment.etc.tboot-pubkey.source = ./keys/pubkey;
  environment.systemPackages = [ pkgs.tinyboot ];
  specialisation.alternate.configuration.boot.kernelParams = [ "console=tty0" ]; # to provide more menu options
  boot.growPartition = true;
  boot.loader.timeout = lib.mkDefault 5;
  boot.loader.efi.canTouchEfiVariables = false;
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
  system.build.qcow2 = import (pkgs.path + "/nixos/lib/make-disk-image.nix") {
    name = "tinyboot-test-image";
    inherit pkgs lib config;
    partitionTableType = "efi";
    format = "qcow2";
  };
}
