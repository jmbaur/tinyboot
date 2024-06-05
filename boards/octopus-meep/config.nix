{ config, lib, ... }:
{
  config = lib.mkIf (config.board == "octopus-meep") {
    chromebook = true;
    video = true;
    coreboot = {
      # start=0x00000000 length=0x00800000 (lower 1/2)
      wpRange.start = "0x00000000";
      wpRange.length = "0x00800000";
      kconfig = with lib.kernel; {
        BOARD_GOOGLE_MEEP = yes;
        FMDFILE = freeform ./layout.fmd;
        VBOOT_NO_BOARD_SUPPORT = yes; # TODO(jared): figure out why this is needed
        VBOOT_SLOTS_RW_A = yes;
        VBOOT_SLOTS_RW_AB = unset;
        VENDOR_GOOGLE = yes;
      };
    };
  };
}
