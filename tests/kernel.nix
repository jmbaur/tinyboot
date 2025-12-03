{
  lib,
  linuxKernel,
  linux,
  stdenv,
  flex,
  bison,
}:

linuxKernel.manualConfig {
  inherit (linux) src version;
  configfile = stdenv.mkDerivation {
    pname = linux.pname + "-config";
    inherit (linux) version;
    inherit (linux) src;
    dontConfigure = true;
    nativeBuildInputs = [
      flex
      bison
    ];
    extraConfig =
      (builtins.readFile ../doc/required.config)
      + ''
        CONFIG_64BIT=y
        CONFIG_FW_CFG_SYSFS=y
        CONFIG_HVC_CONSOLE=y
        CONFIG_IKCONFIG=y
        CONFIG_PCI=y
        CONFIG_SCSI=y
        CONFIG_SCSI_VIRTIO=y
        CONFIG_TCG_TIS=y
        CONFIG_TCG_TPM=y
        CONFIG_VIRTIO_BLK=y
        CONFIG_VIRTIO_CONSOLE=y
        CONFIG_VIRTIO_MENU=y
        CONFIG_VIRTIO_MMIO=y
        CONFIG_VIRTIO_PCI=y
      ''
      + lib.optionalString stdenv.hostPlatform.isx86_64 ''
        CONFIG_ACPI=y
        CONFIG_CMDLINE="debug console=ttyS0,115200"
        CONFIG_CMDLINE_BOOL=y
        CONFIG_CMDLINE_OVERRIDE=y
        CONFIG_SERIAL_8250=y
        CONFIG_SERIAL_8250_CONSOLE=y
      ''
      + lib.optionalString stdenv.hostPlatform.isAarch64 ''
        CONFIG_ARM_SCMI_TRANSPORT_VIRTIO=y
        CONFIG_CMDLINE="debug console=ttyAMA0,115200"
        CONFIG_CMDLINE_FORCE=y
        CONFIG_PCI_HOST_GENERIC=y
        CONFIG_SERIAL_AMBA_PL011=y
        CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
      '';
    passAsFile = [ "extraConfig" ];
    env = {
      ARCH = stdenv.hostPlatform.linuxArch;
      CROSS_COMPILE = stdenv.cc.targetPrefix;
    };
    buildPhase = ''
      runHook preBuild
      make -j$NIX_BUILD_CORES tinyconfig
      cat $extraConfigPath >> .config
      make -j$NIX_BUILD_CORES olddefconfig
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      cp .config $out
      runHook postInstall
    '';
  };
}
