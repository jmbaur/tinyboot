{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "asurada-spherion") {
    platforms = [ "aarch64-linux" ];
    linux = {
      basePackage = pkgs.linuxKernel.kernels.linux_6_4;
      configFile = lib.mkDefault (pkgs.concatText "asurada-spherion-kernel.config" [ ../generic-kernel.config ../aarch64-kernel.config ../chromebook-kernel.config ../mediatek-kernel.config ]);
      commandLine = [ "quiet" ];
      dtbPattern = "mt8192-asurada-spherion*";
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
  };
}
