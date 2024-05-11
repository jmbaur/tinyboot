{ lib, ... }:
{
  platform.qemu = true;
  network = true;
  video = true;
  debug = true;
  linux.kconfig = with lib.kernel; {
    FB_VESA = yes;
    FB_VGA16 = yes;
    VGA_ARB = yes;
  };
  coreboot.kconfig = with lib.kernel; {
    BOARD_EMULATION_QEMU_X86_Q35 = yes;
    VENDOR_EMULATION = yes;
    FMDFILE = freeform ./layout.fmd;
  };
}
