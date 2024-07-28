{
  kconfig ? "",
  lib,
  linux,
  stdenv,
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
  inherit kconfig;
  passAsFile = [ "kconfig" ];
  postConfigure = ''
    cat $kconfigPath $extraConfigPath > all.config
    make -j$NIX_BUILD_CORES ARCH=${stdenv.hostPlatform.linuxArch} KCONFIG_ALLCONFIG=1 allnoconfig
    bash ${./check_config.bash} all.config .config
  '';
  buildFlags = [
    "DTC_FLAGS=-@"
    "KBUILD_BUILD_VERSION=1-tinyboot"
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
    install -Dt $dev .config vmlinux
  '';
}
