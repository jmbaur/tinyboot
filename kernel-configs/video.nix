{
  config,
  lib,
  pkgs,
  ...
}:
{
  linux.kconfig = lib.mkIf config.video (
    with lib.kernel;
    {
      BACKLIGHT_CLASS_DEVICE = yes;
      DRM = yes;
      DRM_SIMPLEDRM = yes;
      FB = yes;
      # TODO(jared): FB_SIMPLE = yes;
      FONTS = yes;
      FONT_SUPPORT = yes;
      FONT_TER16x32 = yes;
      FRAMEBUFFER_CONSOLE = yes;
      ACPI_VIDEO = lib.mkIf pkgs.stdenv.hostPlatform.isx86_64 yes;
      FRAMEBUFFER_CONSOLE_DETECT_PRIMARY = yes;
      GOOGLE_FRAMEBUFFER_COREBOOT = yes;
      LOGO = yes;
      LOGO_LINUX_VGA16 = yes;
    }
  );
}
