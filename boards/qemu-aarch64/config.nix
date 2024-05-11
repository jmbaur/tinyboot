# TODO(jared): vboot not tested on this platform
{ pkgs, lib, ... }:
{
  platform.qemu = true;
  network = true;
  debug = true;
  linux = {
    kconfig = with lib.kernel; {
      GPIOLIB = yes;
      GPIO_PL061 = yes;
      MEMORY_HOTPLUG = yes;
      MEMORY_HOTREMOVE = yes;
      MIGRATION = yes;
      PCI_HOST_GENERIC = yes;
      PCI_PRI = yes;
      PL330_DMA = yes;
      RTC_DRV_PL031 = yes;
      SERIAL_AMBA_PL011 = yes;
      SERIAL_AMBA_PL011_CONSOLE = yes;
    };
    dtb = lib.mkDefault (
      pkgs.buildPackages.runCommand "qemu-aarch64.dtb" { depsBuildBuild = [ pkgs.pkgsBuildBuild.qemu ]; }
        ''
          qemu-system-aarch64 -M virt,secure=on,virtualization=on,dumpdtb=$out -cpu cortex-a53 -m 2G -smp 2 -nographic
        ''
    );
  };
  coreboot.kconfig = with lib.kernel; {
    BOARD_EMULATION = yes;
    BOARD_EMULATION_QEMU_AARCH64 = yes;
    FMDFILE = freeform ./layout.fmd;
  };
}
