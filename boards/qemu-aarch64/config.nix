{ pkgs, lib, ... }: {
  platforms = [ "aarch64-linux" ];
  kernel = {
    configFile = lib.mkDefault (pkgs.concatText "qemu-aarch64-kernel.config" [ ../generic-kernel.config ../aarch64-kernel.config ../qemu-kernel.config ./kernel.config ]);
    commandLine = lib.mkDefault [ "console=ttyAMA0,115200" ];
    dtb = lib.mkDefault (pkgs.buildPackages.runCommand "qemu-aarch64.dtb" { depsBuildBuild = [ pkgs.pkgsBuildBuild.qemu ]; } ''
      qemu-system-aarch64 -M virt,secure=on,dumpdtb=$out -cpu cortex-a53 -m 2G -smp 2 -nographic
    '');
  };
  coreboot.configFile = lib.mkDefault ./coreboot.config;
  tinyboot = {
    debug = lib.mkDefault true;
    tty = lib.mkDefault "ttyAMA0";
    verifiedBoot = {
      enable = lib.mkDefault true;
      publicKey = lib.mkDefault ../../test/keys/pubkey;
    };
    measuredBoot.enable = lib.mkDefault false;
  };
}
