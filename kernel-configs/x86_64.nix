{ pkgs, lib, ... }:
{
  linux.kconfig = lib.mkIf pkgs.stdenv.hostPlatform.isx86_64 (
    with lib.kernel;
    {
      ACPI = yes;
      ACPI_BUTTON = yes;
      ACPI_PROCESSOR = yes;
      ACPI_THERMAL = yes;
      ACPI_VIDEO = yes;
      ACPI_WMI = yes;
      ATA_ACPI = yes;
      CMDLINE_BOOL = yes;
      CPU_MITIGATIONS = yes;
      CRYPTO_SHA256_SSSE3 = yes;
      CRYPTO_SHA512_SSSE3 = yes;
      DW_DMAC = yes;
      GPIO_ACPI = yes;
      IRQ_REMAP = yes;
      KERNEL_BZIP2 = unset;
      KERNEL_GZIP = unset;
      KERNEL_LZ4 = unset;
      KERNEL_LZMA = unset;
      KERNEL_LZO = unset;
      KERNEL_XZ = yes;
      MFD_INTEL_LPSS_ACPI = yes;
      MFD_INTEL_LPSS_PCI = yes;
      MTRR = yes;
      PCI_MSI = yes;
      PNP = yes;
      PREEMPT_VOLUNTARY = yes;
      RETPOLINE = yes;
      RTC_DRV_CMOS = yes;
      SERIAL_8250 = yes;
      SERIAL_8250_CONSOLE = yes;
      SERIAL_8250_DMA = yes;
      SERIAL_8250_DW = yes;
      SERIAL_8250_EXAR = yes;
      SERIAL_8250_EXTENDED = yes;
      SERIAL_8250_LPSS = yes;
      SERIAL_8250_MID = yes;
      SERIAL_8250_PCI = yes;
      SERIAL_8250_PCILIB = yes;
      SERIAL_8250_PERICOM = yes;
      SERIAL_8250_PNP = yes;
      SERIAL_8250_SHARE_IRQ = yes;
      SPI_DESIGNWARE = yes;
      SPI_INTEL_PCI = yes;
      SPI_MEM = yes;
      SPI_PXA2XX = yes;
      SPI_PXA2XX_PCI = yes;
      SYSFB_SIMPLEFB = yes;
      UNIX98_PTYS = yes;
      UNWINDER_FRAME_POINTER = unset;
      UNWINDER_GUESS = yes;
      VGA_CONSOLE = yes;
      WMI_BMOF = yes;
      X86 = yes;
      X86_64 = yes;
      X86_INTEL_LPSS = yes;
      X86_IOPL_IOPERM = yes;
      X86_PAT = yes;
      X86_PLATFORM_DEVICES = yes;
      X86_REROUTE_FOR_BROKEN_BOOT_IRQS = yes;
      X86_X2APIC = yes;
    }
  );
}
