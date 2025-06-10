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
    version = linux.version;
    src = linux.src;
    dontConfigure = true;
    nativeBuildInputs = [
      flex
      bison
    ];
    extraConfig = 
      (builtins.readFile ../doc/required.config)
      + ''
        CONFIG_64BIT=y
        CONFIG_VIRTIO_MENU=y
        CONFIG_VIRTIO_BLK=y
        CONFIG_FW_CFG_SYSFS=y
        CONFIG_SCSI_VIRTIO=y
        CONFIG_SCSI=y
        CONFIG_PCI=y
        CONFIG_VIRTIO_PCI=y
        CONFIG_VIRTIO_CONSOLE=y
      ''
      + lib.optionalString stdenv.hostPlatform.isx86_64 ''
        CONFIG_ACPI=y
        CONFIG_CMDLINE_BOOL=y
        CONFIG_CMDLINE_OVERRIDE=y
        CONFIG_CMDLINE="debug console=ttyS0,115200"
        CONFIG_SERIAL_8250=y
        CONFIG_SERIAL_8250_CONSOLE=y
      ''
      + lib.optionalString stdenv.hostPlatform.isAarch64 ''
        ARM_SCMI_TRANSPORT_VIRTIO = yes;
        CONFIG_CMDLINE_FORCE=y
        CONFIG_CMDLINE="debug console=ttyAMA0,115200"
        SERIAL_AMBA_PL011 = yes;
        SERIAL_AMBA_PL011_CONSOLE = yes;
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
