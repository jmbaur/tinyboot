{ config, pkgs, lib, kconfig, ... }: {
  config = lib.mkIf (config.board == "poppy-atlas") {
    platforms = [ "x86_64-linux" ];
    linux.configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "poppy-atlas-kernel.config" [ generic x86_64 chromebook ./kernel.config ]);
    coreboot.kconfig = with kconfig; {
      VENDOR_GOOGLE = yes;
      BOARD_GOOGLE_ATLAS = yes;
      FMDFILE = freeform ./layout.fmd;
    };
  };
}
