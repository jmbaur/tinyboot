{ src, lib, stdenvNoCC, pkgsBuildBuild, python3, pkg-config, openssl, ... }:
{ board ? null, configFile }:
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
  inherit configFile;
  passAsFile = [ "configFile" ];
  configurePhase = ''
    runHook preConfigure
    cat $configFilePath > .config
    make olddefconfig
    runHook postConfigure
  '';
  makeFlags = [ "XGCCPATH=${toolchain}/bin/" "KERNELVERSION=4.21-tinyboot-${version}" "UPDATED_SUBMODULES=1" ];
  outputs = [ "out" "dev" ];
  installPhase = ''
    runHook preInstall
    install -D --target-directory=$out build/coreboot.rom
    install -D --target-directory=$dev .config
    runHook postInstall
  '';
})
