{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (pkgs.stdenv.hostPlatform) isx86_64 isAarch64;
in
{
  imports = [ ../modules/nixos ];
  tinyboot = {
    enable = true;
    platform.qemu = true;
    network = true;
    debug = true;
    linux = {
      consoles = lib.mkIf isx86_64 [ "ttyS0,115200n8" ];
      kconfig = lib.mkIf isAarch64 (
        with lib.kernel;
        {
          ARM_SCMI_TRANSPORT_VIRTIO = yes;
          GPIO_PL061 = yes;
          MEMORY_HOTPLUG = yes;
          MEMORY_HOTREMOVE = yes;
          MIGRATION = yes;
          PCI_HOST_GENERIC = yes;
          PCI_PRI = yes;
          PL330_DMA = yes;
          RTC_DRV_PL031 = yes;
          SERIAL_AMBA_PL011 = yes;
          SERIAL_AMBA_PL011_CONSOLE = yes;
        }
      );
    };
  };

  # can't use this cause this doesn't let us customize our kernel
  virtualisation.directBoot.enable = false;

  virtualisation.graphics = false;
  virtualisation.qemu.consoles = config.tinyboot.linux.consoles;
  virtualisation.qemu.options =
    [
      "-kernel ${config.tinyboot.build.linux}/${config.tinyboot.build.linux.kernelFile}"
      "-initrd ${config.tinyboot.build.initrd}/${config.tinyboot.build.initrd.initrdFile}"
    ]
    ++ lib.optionals isx86_64 [ "-machine q35" ]
    # TODO(jared): make work with -cpu max
    ++ lib.optionals isAarch64 [ "-cpu cortex-a53" ];
}
