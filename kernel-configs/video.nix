{ config, lib, ... }:
{
  linux.kconfig = lib.mkIf config.video (
    with lib.kernel;
    {
      BACKLIGHT_CLASS_DEVICE = yes;
      FB = yes;
      FB_SIMPLE = yes;
      FONTS = yes;
      FONT_SUPPORT = yes;
      FONT_TER16x32 = yes;
      FRAMEBUFFER_CONSOLE = yes;
      FRAMEBUFFER_CONSOLE_DETECT_PRIMARY = yes;
      GOOGLE_FRAMEBUFFER_COREBOOT = yes;
      LOGO = yes;
      LOGO_LINUX_VGA16 = yes;
    }
  );
}
