{
  lib,
  linuxKernel,
  linux_7_2,
  stdenv,
}:

linuxKernel.manualConfig {
  inherit (linux_7_2) src version;
  configfile = stdenv.mkDerivation {
    pname = linux_7_2.pname + "-config";
    inherit (linux_7_2)
      src
      version
      depsBuildBuild
      nativeBuildInputs
      ;
    dontConfigure = true;
    extraConfig =
      (builtins.readFile ../doc/required.config)
      + lib.optionalString stdenv.hostPlatform.is64bit (builtins.readFile ../doc/required-64bit.config)
      + ''
        CONFIG_FW_CFG_SYSFS=y
        CONFIG_HVC_CONSOLE=y
        CONFIG_IKCONFIG=y
        CONFIG_DYNAMIC_DEBUG=y
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
        CONFIG_CMDLINE="kho=on liveupdate=on debug console=ttyS0,115200"
        CONFIG_CMDLINE_BOOL=y
        CONFIG_CMDLINE_OVERRIDE=y
        CONFIG_SERIAL_8250=y
        CONFIG_SERIAL_8250_CONSOLE=y
      ''
      + lib.optionalString stdenv.hostPlatform.isAarch64 ''
        CONFIG_ARM_SCMI_TRANSPORT_VIRTIO=y
        CONFIG_CMDLINE="kho=on liveupdate=on debug"
        CONFIG_CMDLINE_FORCE=y
        CONFIG_PCI_HOST_GENERIC=y
        CONFIG_SERIAL_AMBA_PL011=y
        CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
      ''
      + lib.optionalString stdenv.hostPlatform.isArmv7 ''
        CONFIG_MMU=y
        CONFIG_ARCH_VIRT=y
        CONFIG_ARCH_MULTI_V7=y
        CONFIG_CMDLINE="debug"
        CONFIG_CMDLINE_FORCE=y
        CONFIG_SERIAL_AMBA_PL011=y
        CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
        CONFIG_VFP=y
        CONFIG_VFPv3=y
        CONFIG_NEON=y
        CONFIG_KERNEL_MODE_NEON=y
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
