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
          CONSOLE_TRANSLATIONS = yes;
          DUMMY_CONSOLE = yes;
          FB = yes;
          FONTS = yes;
          FONT_SUPPORT = yes;
          FONT_TER16x32 = yes;
          FRAMEBUFFER_CONSOLE = yes;
          FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER = yes;
          FRAMEBUFFER_CONSOLE_DETECT_PRIMARY = yes;
          LOGO = yes;
          LOGO_LINUX_VGA16 = yes;
          VT = yes;
          VT_CONSOLE = yes;
        }
        (lib.mkIf pkgs.stdenv.hostPlatform.isx86_64 {
          # TODO(jared): make this work with GOP so we can turn off i915
          # depends on coreboot linux_trampoline
          EFI = yes;
          FB_EFI = yes;

          ACPI_VIDEO = yes;
          BACKLIGHT_CLASS_DEVICE = yes;
          DRM = yes;
          DRM_FBDEV_EMULATION = yes;
          DRM_I915 = yes;
          VGA_CONSOLE = yes;
        })
        (lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 { GOOGLE_FRAMEBUFFER_COREBOOT = yes; })
      ];
  };
}
