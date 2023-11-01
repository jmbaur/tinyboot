{ config, pkgs, lib, kconfig, ... }: {
  config = lib.mkIf (config.board == "trogdor-wormdingler") {
    platforms = [ "aarch64-linux" ];
    linux = {
      configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "trogdor-wormdingler-kernel.config" [ generic video aarch64 chromebook qcom ./kernel.config ]);
      # https://gitlab.freedesktop.org/drm/msm/-/issues/13
      commandLine = [ "pd_ignore_unused" "clk_ignore_unused" ];
      dtbPattern = "sc7180-trogdor-wormdingler*";
    };
    tinyboot.tty = "ttyMSM0";
    coreboot.kconfig = with kconfig; {
      USE_QC_BLOBS = yes;
      VENDOR_GOOGLE = yes;
      BOARD_GOOGLE_WORMDINGLER = yes;
      FMDFILE = freeform ./layout.fmd;
    };
  };
}
