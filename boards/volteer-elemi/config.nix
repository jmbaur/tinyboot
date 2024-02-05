{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "volteer-elemi") {
    platforms = [ "x86_64-linux" ];
    linux.configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "volteer-elemi-kernel.config" [ generic video x86_64 tigerlake chromebook ]);
    tinyboot.consoles = lib.mkDefault [ "ttyS0" "tty1" ];
    coreboot = {
      # start=0x01800000 length=0x00800000 (upper 1/4)
      wpRange.start = "0x01800000";
      wpRange.length = "0x00800000";
      kconfig = with lib.kernel; {
        BOARD_GOOGLE_ELEMI = yes;
        FMDFILE = freeform ./layout.fmd;
        VBOOT_NO_BOARD_SUPPORT = yes; # TODO(jared): figure out why this is needed
        VENDOR_GOOGLE = yes;
      };
    };
  };
}
