{
  config,
  lib,
  pkgs,
  ...
}:
{
  linux = lib.mkIf config.video {
    consoles = [ "tty0" ];
    kconfig = with lib.kernel; {
      # TODO(jared): FB_SIMPLE = yes;
      ACPI_VIDEO = lib.mkIf pkgs.stdenv.hostPlatform.isx86_64 yes;
      BACKLIGHT_CLASS_DEVICE = yes;
      CONSOLE_TRANSLATIONS = yes;
      DRM = yes;
      DRM_SIMPLEDRM = yes;
      FB = yes;
      FONTS = yes;
      FONT_SUPPORT = yes;
      FONT_TER16x32 = yes;
      FRAMEBUFFER_CONSOLE = yes;
      FRAMEBUFFER_CONSOLE_DETECT_PRIMARY = yes;
      GOOGLE_FRAMEBUFFER_COREBOOT = yes;
      LOGO = yes;
      LOGO_LINUX_VGA16 = yes;
      VGA_CONSOLE = lib.mkIf pkgs.stdenv.hostPlatform.isx86_64 yes;
      VT = yes;
      VT_CONSOLE = yes;
    };
  };
}
