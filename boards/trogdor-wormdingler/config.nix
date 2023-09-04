{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "trogdor-wormdingler") {
    platforms = [ "aarch64-linux" ];
    linux = {
      basePackage = pkgs.linuxKernel.kernels.linux_6_4;
      configFile = lib.mkDefault (pkgs.concatText "trogdor-wormdingler-kernel.config" [ ../generic-kernel.config ../aarch64-kernel.config ../chromebook-kernel.config ../qcom-kernel.config ./kernel.config ]);
      # https://gitlab.freedesktop.org/drm/msm/-/issues/13
      commandLine = [ "pd_ignore_unused" "clk_ignore_unused" "quiet" ];
      dtbPattern = "sc7180-trogdor-wormdingler*";
      firmware = pkgs.runCommand "wormdingler-firmware" { } ''
        mkdir -p $out/qcom; cp -r ${pkgs.linux-firmware}/lib/firmware/qcom/venus-5.4 $out/qcom/venus-5.4
      '';
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
    tinyboot.ttys = [ "ttyMSM0" ];
  };
}
