{ lib, ... }:
{
  chromebook = true;
  video = true;
  coreboot.kconfig = with lib.kernel; {
    BOARD_GOOGLE_ATLAS = yes;
    FMDFILE = freeform ./layout.fmd;
    VENDOR_GOOGLE = yes;
  };
}
