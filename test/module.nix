{ config, pkgs, lib, modulesPath, ... }: {
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];
  tinyboot.enable = true;
  tinyboot.board = "qemu-${pkgs.stdenv.hostPlatform.qemuArch}";
  boot.kernelParams = [ "console=${{ x86_64 = "ttyS0"; arm64 = "ttyAMA0"; }.${config.nixpkgs.hostPlatform.linuxArch}},115200" ];
  system.stateVersion = "23.11";
  specialisation.alternate.configuration.boot.kernelParams = [ "console=tty1" ]; # to provide more menu options
  boot.growPartition = true;
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
  # TODO(jared): make-disk-image.nix is incapable of cross-compilation. Use disko instead?
  system.build.qcow2 = import (pkgs.path + "/nixos/lib/make-disk-image.nix") {
    name = "tinyboot-test-image";
    inherit pkgs lib config;
    partitionTableType = "efi";
    format = "qcow2";
  };
}
