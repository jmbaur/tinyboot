{
  config,
  pkgs,
  lib,
  ...
}:
{
  config = lib.mkIf (config.board == "kukui-fennel") {
    platform.mediatek = true;
    video = true;
    chromebook = true;
    linux.dtbPattern = "mt8183-kukui-jacuzzi-fennel*";
    coreboot.kconfig = with lib.kernel; {
      ARM64_BL31_EXTERNAL_FILE = freeform "${pkgs.armTrustedFirmwareMT8183}/libexec/bl31.elf";
      BOARD_GOOGLE_FENNEL = yes;
      FMDFILE = freeform ./layout.fmd;
      VENDOR_GOOGLE = yes;
    };
  };
}
