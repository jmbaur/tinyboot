{ config, lib, ... }:
{
  config = lib.mkIf (config.board == "brya-banshee") {
    platform.alderlake = true;
    video = true;
    chromebook = true;
    coreboot = {
      # start=0x01800000 length=0x00800000 (upper 1/4)
      wpRange.start = "0x01800000";
      wpRange.length = "0x00800000";
      kconfig = with lib.kernel; {
        BOARD_GOOGLE_BANSHEE = yes;
        FMDFILE = freeform ./layout.fmd;
        VBOOT_NO_BOARD_SUPPORT = yes; # TODO(jared): figure out why this is needed
        VENDOR_GOOGLE = yes;
      };
    };
  };
}
