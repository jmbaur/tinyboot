{ config, lib, ... }:
{
  config = lib.mkIf (config.board == "qemu-x86_64") {
    platform.qemu = true;
    network = true;
    debug = true;
    video = false;
    linux.consoles = [ "ttyS0,115200n8" ];
    coreboot.kconfig = with lib.kernel; {
      BOARD_EMULATION_QEMU_X86_Q35 = yes;
      FMDFILE = freeform ./layout.fmd;
      GENERIC_LINEAR_FRAMEBUFFER = yes;
      VENDOR_EMULATION = yes;
    };
  };
}
