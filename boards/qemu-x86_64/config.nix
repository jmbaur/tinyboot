{ config, lib, ... }:
{
  config = lib.mkIf (config.board == "qemu-x86_64") {
    platform.qemu = true;
    network = true;
    debug = true;
    linux.consoles = [ "ttyS0,115200n8" ];
    linux.kconfig = lib.mkIf config.video (
      with lib.kernel;
      {
        FB_VESA = yes;
        FB_VGA16 = yes;
        VGA_ARB = yes;
      }
    );
    coreboot.kconfig = with lib.kernel; {
      BOARD_EMULATION_QEMU_X86_Q35 = yes;
      VENDOR_EMULATION = yes;
      FMDFILE = freeform ./layout.fmd;
    };
  };
}
