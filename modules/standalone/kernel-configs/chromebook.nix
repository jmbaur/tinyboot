{
  config,
  lib,
  pkgs,
  ...
}:
{
  linux.kconfig = lib.mkIf config.chromebook (
    with lib.kernel;
    {
      CHROME_PLATFORMS = yes;
      CROS_EC = yes;
      CROS_EC_I2C = yes;
      CROS_EC_LPC = lib.mkIf pkgs.stdenv.hostPlatform.isx86_64 yes;
      CROS_EC_PROTO = yes;
      CROS_EC_SPI = yes;
      GOOGLE_CBMEM = yes;
      GOOGLE_COREBOOT_TABLE = yes;
      GOOGLE_FIRMWARE = yes;
      GOOGLE_VPD = yes;
      HID_VIVALDI = yes;
      I2C_CROS_EC_TUNNEL = yes;
      KEYBOARD_CROS_EC = yes;
      TCG_TIS_I2C_CR50 = yes;
      TCG_TIS_SPI = yes;
      TCG_TIS_SPI_CR50 = yes;
      TYPEC = yes;
      USB_DWC3 = yes;
      USB_DWC3_HAPS = yes;
      USB_DWC3_PCI = lib.mkIf pkgs.stdenv.hostPlatform.isx86_64 yes;
    }
  );
}
