{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "qemu-aarch64") {
    platforms = [ "aarch64-linux" ];
    linux = {
      configFile = with pkgs.tinybootKernelPatches; lib.mkDefault (pkgs.concatText "qemu-aarch64-kernel.config" [ generic aarch64 qemu ./kernel.config ]);
      dtb = lib.mkDefault (pkgs.buildPackages.runCommand "qemu-aarch64.dtb" { depsBuildBuild = [ pkgs.pkgsBuildBuild.qemu ]; } ''
        qemu-system-aarch64 -M virt,secure=on,virtualization=on,dumpdtb=$out -cpu cortex-a53 -m 2G -smp 2 -nographic
      '');
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
    loglevel = lib.mkDefault "info";
    tinyboot.tty = lib.mkDefault "ttyAMA0";
  };
}
