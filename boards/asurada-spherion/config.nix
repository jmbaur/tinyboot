{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "asurada-spherion") {
    platforms = [ "aarch64-linux" ];
    linux = {
      configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "asurada-spherion-kernel.config" [ generic video aarch64 chromebook mediatek ]);
      dtbPattern = "mt8192-asurada-spherion*";
    };
    tinyboot.consoles = lib.mkDefault [ "tty1" "ttyS0" ];
    coreboot.kconfig = with lib.kernel; {
      ARM64_BL31_EXTERNAL_FILE = freeform "${pkgs.armTrustedFirmwareMT8192}/libexec/bl31.elf";
      BOARD_GOOGLE_SPHERION = yes;
      FMDFILE = freeform ./layout.fmd;
      VENDOR_GOOGLE = yes;
    };
  };
}
