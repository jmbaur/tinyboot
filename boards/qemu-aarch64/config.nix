{ pkgs, ... }: {
  platforms = [ "aarch64-linux" ];
  kernel = {
    configFile = pkgs.concatText "qemu-aarch64-kernel.config" [ ../generic-kernel.config ../qemu-kernel.config ../aarch64-kernel.config ];
    commandLine = [ "console=ttyAMA0" ];
    dtb = pkgs.buildPackages.runCommand "qemu-aarch64.dtb" { depsBuildBuild = [ pkgs.pkgsBuildBuild.qemu ]; } ''
      qemu-system-aarch64 \
        -M virt,secure=on,virtualization=on,dumpdtb=$out \
        -cpu cortex-a53 -m 4096M -nographic
    '';
  };
  coreboot.configFile = ./coreboot.config;
}
