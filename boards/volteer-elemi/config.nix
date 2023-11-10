{ config, pkgs, lib, kconfig, ... }: {
  config = lib.mkIf (config.board == "volteer-elemi") {
    platforms = [ "x86_64-linux" ];
    linux.configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "volteer-elemi-kernel.config" [ generic video x86_64 tigerlake chromebook ]);
    coreboot.kconfig = with kconfig; {
      BOARD_GOOGLE_ELEMI = yes;
      FMDFILE = freeform ./layout.fmd;
      VBOOT_NO_BOARD_SUPPORT = yes; # TODO(jared): figure out why this is needed
      VENDOR_GOOGLE = yes;
    };
  };
}
