{ lib, ... }:
{
  hostPlatform = "armv7l-linux";
  platform.qemu = true;
  network = true;
  debug = true;
  linux.kconfig = with lib.kernel; {
    ARCH_VIRT = yes;
    SERIAL_AMBA_PL011 = yes;
    SERIAL_AMBA_PL011_CONSOLE = yes;
  };
}
