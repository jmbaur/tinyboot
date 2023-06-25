{ basePackage, configFile, lib, stdenv, buildPackages }:
stdenv.mkDerivation {
  inherit (basePackage) pname version src buildInputs nativeBuildInputs depsBuildBuild;
  makeFlags = [
    "CC=${stdenv.cc}/bin/${stdenv.cc.targetPrefix}cc"
    "HOSTCC=${buildPackages.stdenv.cc}/bin/${buildPackages.stdenv.cc.targetPrefix}cc"
    "HOSTLD=${buildPackages.stdenv.cc.bintools}/bin/${buildPackages.stdenv.cc.targetPrefix}ld"
    "ARCH=${stdenv.hostPlatform.linuxArch}"
  ] ++ lib.optional (stdenv.hostPlatform != stdenv.buildPlatform)
    "CROSS_COMPILE=${stdenv.cc.targetPrefix}";
  configurePhase = ''
    runHook preConfigure
    make ARCH=${stdenv.hostPlatform.linuxArch} tinyconfig
    cat ${configFile} >> .config
    make ARCH=${stdenv.hostPlatform.linuxArch} olddefconfig
    runHook postConfigure
  '';
  preBuild = ''
    makeFlagsArray+=("-j$NIX_BUILD_CORES")
  '';
  buildFlags = [ "DTC_FLAGS=-@" "KBUILD_BUILD_VERSION=1-TinyBoot" stdenv.hostPlatform.linux-kernel.target ];
  preInstall =
    let
      installkernel = buildPackages.writeShellScriptBin "installkernel" ''
        cp -av $2 $4; cp -av $3 $4
      '';
    in
    ''
      export HOME=${installkernel}
    '';
  installFlags = [ "INSTALL_PATH=$(out)" ] ++ lib.optionals stdenv.hostPlatform.isAarch [ "dtbs_install" "INSTALL_DTBS_PATH=$(out)/dtbs" ];
  postInstall = ''
    cp .config $out/config
    cp vmlinux $out/vmlinux
  '';
}
