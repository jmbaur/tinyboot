{ src, lib, stdenvNoCC, pkgsBuildBuild, python3, pkg-config, openssl, ... }:
{ board ? null, configFile, extraConfig ? "" }:
let
  architectures = { i386 = "i386"; x86_64 = "i386"; arm64 = "aarch64"; arm = "arm"; riscv = "riscv"; powerpc = "ppc64"; };
  toolchain = pkgsBuildBuild.coreboot-toolchain.${architectures.${stdenvNoCC.hostPlatform.linuxArch}}.override {
    withAda = stdenvNoCC.hostPlatform.isx86_64;
  };
  version = src.shortRev or src.dirtyShortRev; # allow for --override-input
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "coreboot-${if (board) != null then board else "unknown"}";
  inherit src version;
  patches = [ ./patches/coreboot-fitimage-memlayout.patch ];
  depsBuildBuild = [ pkgsBuildBuild.stdenv.cc pkg-config openssl ];
  nativeBuildInputs = [ python3 ];
  buildInputs = [ ];
  postPatch = ''
    patchShebangs util 3rdparty/vboot/scripts
  '';
  inherit extraConfig;
  passAsFile = [ "extraConfig" ];
  configurePhase = ''
    runHook preConfigure
    cat ${configFile} > .config
    cat $extraConfigPath >> .config
    make oldconfig
    runHook postConfigure
  '';
  makeFlags = [ "XGCCPATH=${toolchain}/bin/" "KERNELVERSION=4.21-tinyboot-${version}" "UPDATED_SUBMODULES=1" ];
  installPhase = ''
    runHook preInstall
    install -D --target-directory=$out build/coreboot.rom
    runHook postInstall
  '';
})
