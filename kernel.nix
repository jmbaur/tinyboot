{ configFile ? null, lib, stdenv, buildPackages, linuxKernel }:
stdenv.mkDerivation {
  inherit (linuxKernel.kernels.linux_6_1) pname version src buildInputs nativeBuildInputs depsBuildBuild;
  config = if configFile != null then (builtins.readFile configFile) else (lib.warn "building tinyconfig kernel" "");
  passAsFile = [ "config" ];
  configurePhase = ''
    runHook preConfigure
    make "''${makeFlagsArray[@]}" tinyconfig
    cat $configPath >> .config
    make "''${makeFlagsArray[@]}" olddefconfig
    runHook postConfigure
  '';
  makeFlags = [
    "CC=${stdenv.cc}/bin/${stdenv.cc.targetPrefix}cc"
    "HOSTCC=${buildPackages.stdenv.cc}/bin/${buildPackages.stdenv.cc.targetPrefix}cc"
    "HOSTLD=${buildPackages.stdenv.cc.bintools}/bin/${buildPackages.stdenv.cc.targetPrefix}ld"
    "ARCH=${stdenv.hostPlatform.linuxArch}"
  ] ++ lib.optional (stdenv.hostPlatform != stdenv.buildPlatform)
    "CROSS_COMPILE=${stdenv.cc.targetPrefix}";
  preBuild = ''
    makeFlagsArray+=("-j$NIX_BUILD_CORES")
  '';
  buildFlags = [ stdenv.hostPlatform.linux-kernel.target ];
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
}
