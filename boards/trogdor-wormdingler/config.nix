{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "trogdor-wormdingler") {
    platforms = [ "aarch64-linux" ];
    linux = {
      basePackage = pkgs.linuxKernel.kernels.linux_6_4;
      configFile = lib.mkDefault (pkgs.concatText "trogdor-wormdingler-kernel.config" [ ../generic-kernel.config ../aarch64-kernel.config ../chromebook-kernel.config ../qcom-kernel.config ./kernel.config ]);
      commandLine = [ "quiet" ];
      dtbPattern = "sc7180-trogdor-wormdingler*";
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
    tinyboot.ttys = [ "ttyMSM0" ];
  };
}
