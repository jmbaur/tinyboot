{ pkgs, ... }: {
  platforms = [ "aarch64-linux" ];
  kernel = {
    configFile = pkgs.concatText "qemu-aarch64-kernel.config" [ ../generic-kernel.config ../aarch64-kernel.config ../qemu-kernel.config ./kernel.config ];
    commandLine = [ "console=ttyAMA0,115200" ];
    dtb = pkgs.buildPackages.runCommand "qemu-aarch64.dtb" { depsBuildBuild = [ pkgs.pkgsBuildBuild.qemu ]; } ''
      qemu-system-aarch64 -M virt,secure=on,dumpdtb=$out -cpu cortex-a53 -m 2G -smp 2 -nographic
    '';
  };
  coreboot.configFile = ./coreboot.config;
}
