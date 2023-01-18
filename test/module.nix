{ config, pkgs, lib, modulesPath, ... }: {
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];
  system.stateVersion = "23.05";
  specialisation.alternate.configuration.boot.kernelParams = [ "console=tty0" ]; # to provide more menu options
  boot.growPartition = true;
  boot.loader.timeout = 5;
  users.users.root.password = "";
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
      autoResize = true;
    };
  };
  system.build.qcow2 = import (pkgs.path + "/nixos/lib/make-disk-image.nix") {
    name = "tinyboot-test-image";
    inherit pkgs lib config;
    partitionTableType = "legacy+gpt"; # TODO(jared): use efi?
    format = "qcow2";
  };
}
