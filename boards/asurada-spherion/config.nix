{ config, pkgs, lib, kconfig, ... }: {
  config = lib.mkIf (config.board == "asurada-spherion") {
    platforms = [ "aarch64-linux" ];
    linux = {
      configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "asurada-spherion-kernel.config" [ generic video aarch64 chromebook mediatek ]);
      dtbPattern = "mt8192-asurada-spherion*";
    };
    coreboot.kconfig = with kconfig; {
      FMDFILE = freeform ./layout.fmd;
      VENDOR_GOOGLE = yes;
      BOARD_GOOGLE_SPHERION = yes;
    };
  };
}
