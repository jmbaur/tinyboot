{ pkgs, lib, ... }:
{
  platforms = [ "aarch64-linux" ];
  linux = {
    configFile =
      with pkgs.tinybootKernelConfigs;
      lib.mkDefault (
        pkgs.concatText "trogdor-wormdingler-kernel.config" [
          generic
          video
          aarch64
          chromebook
          qcom
          sc7180
          ./kernel.config
        ]
      );
    # https://gitlab.freedesktop.org/drm/msm/-/issues/13
    commandLine = [
      "pd_ignore_unused"
      "clk_ignore_unused"
    ];
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
