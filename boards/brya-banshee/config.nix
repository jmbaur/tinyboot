{ config, pkgs, lib, kconfig, ... }: {
  config = lib.mkIf (config.board == "brya-banshee") {
    platforms = [ "x86_64-linux" ];
    linux.configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "brya-banshee-kernel.config" [ generic x86_64 chromebook ./kernel.config ]);
    coreboot.kconfig = with kconfig; {
      BOARD_GOOGLE_BANSHEE = yes;
      FMDFILE = freeform ./layout.fmd;
      VBOOT_NO_BOARD_SUPPORT = yes; # TODO(jared): figure out why this is needed
      VENDOR_GOOGLE = yes;
    };
  };
}
