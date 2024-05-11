{ pkgs, lib, ... }:
{
  platform.mediatek = true;
  video = true;
  chromebook = true;
  linux.dtbPattern = "mt8192-asurada-spherion*";
  coreboot.kconfig = with lib.kernel; {
    ARM64_BL31_EXTERNAL_FILE = freeform "${pkgs.armTrustedFirmwareMT8192}/libexec/bl31.elf";
    BOARD_GOOGLE_SPHERION = yes;
    FMDFILE = freeform ./layout.fmd;
    VENDOR_GOOGLE = yes;
  };
}
