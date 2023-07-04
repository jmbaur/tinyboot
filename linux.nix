{ linux, basePackage ? linux, configFile, extraConfig, lib, stdenv }:
stdenv.mkDerivation {
  inherit (basePackage) pname version src buildInputs nativeBuildInputs depsBuildBuild makeFlags preInstall enableParallelBuilding;
  inherit extraConfig;
  passAsFile = [ "extraConfig" ];
  patches = [ ./patches/linux-tpm-probe.patch ];
  configurePhase = ''
    runHook preConfigure
    make ARCH=${stdenv.hostPlatform.linuxArch} tinyconfig
    cat ${configFile} >> .config
    cat $extraConfigPath >> .config
    make ARCH=${stdenv.hostPlatform.linuxArch} olddefconfig
    runHook postConfigure
  '';
  buildFlags = [ "DTC_FLAGS=-@" "KBUILD_BUILD_VERSION=1-TinyBoot" ];
  installFlags = [ "INSTALL_PATH=$(out)" ] ++ lib.optionals stdenv.hostPlatform.isAarch [ "dtbs_install" "INSTALL_DTBS_PATH=$(out)/dtbs" ];
}
