{
  builtinCmdline ? [ ],
  configFile,
  lib,
  stdenv,
  linux,
}:
stdenv.mkDerivation {
  inherit (linux)
    pname
    version
    src
    buildInputs
    nativeBuildInputs
    depsBuildBuild
    makeFlags
    preInstall
    enableParallelBuilding
    ;
  patches = [ ./tpm-probe.patch ];
  postPatch = ''
    cp ${./boots_ascii_16.ppm} drivers/video/logo/logo_linux_vga16.ppm
  '';
  extraConfig = lib.optionalString (builtinCmdline != [ ]) ''
    CONFIG_CMDLINE="${toString builtinCmdline}"
  '';
  passAsFile = [ "extraConfig" ];
  configurePhase = ''
    runHook preConfigure
    cat ${configFile} $extraConfigPath > all.config
    make ARCH=${stdenv.hostPlatform.linuxArch} KCONFIG_ALLCONFIG=1 allnoconfig
    bash ${./check_config.bash} all.config .config
    runHook postConfigure
  '';
  buildFlags = [
    "DTC_FLAGS=-@"
    "KBUILD_BUILD_VERSION=1-TinyBoot"
  ];
  installFlags =
    [ "INSTALL_PATH=$(out)" ]
    ++ lib.optionals stdenv.hostPlatform.isAarch [
      "dtbs_install"
      "INSTALL_DTBS_PATH=$(out)/dtbs"
    ];
  outputs = [
    "out"
    "dev"
  ];
  postInstall = ''
    ln -s $out/${stdenv.hostPlatform.linux-kernel.target} $out/kernel
    install -Dm0755 --target-directory=$out/bin scripts/sign-file
    install -D --target-directory=$dev .config vmlinux
  '';
  passthru = {
    inherit builtinCmdline;
  };
}
