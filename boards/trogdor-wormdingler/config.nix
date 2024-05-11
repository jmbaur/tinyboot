# TODO(jared): https://gitlab.freedesktop.org/drm/msm/-/issues/13
{ lib, ... }:
{
  platform.qualcomm = true;
  chromebook = true;
  video = true;
  linux = {
    kconfig = with lib.kernel; {
      HID_GOOGLE_HAMMER = yes;
      I2C_CROS_EC_TUNNEL = yes;
      I2C_HID_OF = yes;
      KEYBOARD_CROS_EC = yes;
      LEDS_CLASS = yes;
      NEW_LEDS = yes;
    };
    dtbPattern = "sc7180-trogdor-wormdingler*";
  };
  coreboot.kconfig = with lib.kernel; {
    ARM64_BL31_EXTERNAL_FILE = freeform "${pkgs.armTrustedFirmwareSC7180}/libexec/bl31.elf";
    BOARD_GOOGLE_WORMDINGLER = yes;
    FMDFILE = freeform ./layout.fmd;
    USE_QC_BLOBS = yes;
    VENDOR_GOOGLE = yes;
  };
}
