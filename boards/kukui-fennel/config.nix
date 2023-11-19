{ config, pkgs, lib, ... }: {
  config = lib.mkIf (config.board == "kukui-fennel") {
    platforms = [ "aarch64-linux" ];
    linux = {
      configFile = with pkgs.tinybootKernelConfigs; lib.mkDefault (pkgs.concatText "kukui-fennel-kernel.config" [ generic video aarch64 chromebook mediatek ]);
      commandLine = [ "console=ttyS0,115200" "console=tty1" ];
      dtbPattern = "mt8183-kukui-jacuzzi-fennel*";
    };
    coreboot.kconfig = with lib.kernel; {
      ARM64_BL31_EXTERNAL_FILE = freeform "${pkgs.armTrustedFirmwareMT8183}/libexec/bl31.elf";
      BOARD_GOOGLE_FENNEL = yes;
      FMDFILE = freeform ./layout.fmd;
      VENDOR_GOOGLE = yes;
    };
  };
}
