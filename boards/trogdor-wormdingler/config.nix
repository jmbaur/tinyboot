{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "trogdor-wormdingler") {
    platforms = [ "aarch64-linux" ];
    linux = {
      basePackage = pkgs.linuxKernel.kernels.linux_6_5;
      configFile = with pkgs.tinybootKernelPatches; lib.mkDefault (pkgs.concatText "trogdor-wormdingler-kernel.config" [ generic aarch64 chromebook qcom ./kernel.config ]);
      # https://gitlab.freedesktop.org/drm/msm/-/issues/13
      commandLine = [ "pd_ignore_unused" "clk_ignore_unused" "quiet" ];
      dtbPattern = "sc7180-trogdor-wormdingler*";
    };
    coreboot.configFile = lib.mkDefault ./coreboot.config;
    tinyboot.ttys = [ "ttyMSM0" ];
  };
}
