{ lib, ... }:
{
  platform.tigerlake = true;
  chromebook = true;
  video = true;
  linux.consoles = [ "ttyS0,115200n8" ];
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
}
