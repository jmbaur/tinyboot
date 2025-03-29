{
  config,
  lib,
  pkgs,
  ...
}:
{
  linux = lib.mkIf config.video {
    consoles = lib.mkAfter [ "tty0" ];
    kconfig =
      with lib.kernel;
      lib.mkMerge [
        {
          BACKLIGHT_CLASS_DEVICE = yes;
          CONSOLE_TRANSLATIONS = yes;
          DRM = yes;
          DRM_FBDEV_EMULATION = yes;
          DUMMY_CONSOLE = yes;
          FONTS = yes;
          FONT_SUPPORT = yes;
          FONT_TER16x32 = yes;
          LOGO = yes;
          LOGO_LINUX_VGA16 = yes;
        }
        (lib.mkIf pkgs.stdenv.hostPlatform.isx86_64 {
          ACPI_VIDEO = yes;
          DRM_I915 = yes;
          VGA_CONSOLE = yes;
        })
        (lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 {
          DRM_SIMPLEDRM = yes;
          GOOGLE_FRAMEBUFFER_COREBOOT = yes;
        })
      ];
  };
}
