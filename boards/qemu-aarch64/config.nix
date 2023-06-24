{ pkgs, lib, ... }: {
  platforms = [ "aarch64-linux" ];
  kernel = {
    configFile = lib.mkDefault (pkgs.concatText "qemu-aarch64-kernel.config" [ ../generic-kernel.config ../aarch64-kernel.config ../qemu-kernel.config ./kernel.config ]);
    dtb = lib.mkDefault (pkgs.buildPackages.runCommand "qemu-aarch64.dtb" { depsBuildBuild = [ pkgs.pkgsBuildBuild.qemu ]; } ''
      qemu-system-aarch64 -M virt,secure=on,virtualization=on,dumpdtb=$out -cpu cortex-a53 -m 4G -smp 2 -nographic
    '');
  };
  coreboot.configFile = lib.mkDefault ./coreboot.config;
  tinyboot = {
    debug = lib.mkDefault true;
    ttys = lib.mkDefault [ "ttyAMA0" ];
    verifiedBoot = {
      enable = lib.mkDefault true;
      publicKey = lib.mkDefault ../../test/keys/pubkey;
    };
    measuredBoot.enable = lib.mkDefault true;
  };
}
