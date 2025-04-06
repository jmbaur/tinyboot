{ lib, ... }:
{
  hostPlatform = "aarch64-linux";
  platform.qualcomm = true;
  chromebook = true;
  linux.kconfig = with lib.kernel; {
    HID_GOOGLE_HAMMER = yes;
    I2C_CROS_EC_TUNNEL = yes;
    I2C_HID_OF = yes;
    KEYBOARD_CROS_EC = yes;
    LEDS_CLASS = yes;
    NEW_LEDS = yes;
  };
}
