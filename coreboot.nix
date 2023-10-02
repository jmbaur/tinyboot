{ src, lib, stdenvNoCC, pkgsBuildBuild, python3, pkg-config, openssl, ... }:
lib.makeOverridable ({ board ? null, configFile, extraConfig ? "", extraArgs ? { } }:
let
  toolchain = pkgsBuildBuild.coreboot-toolchain.${{ i386 = "i386"; x86_64 = "i386"; arm64 = "aarch64"; arm = "arm"; riscv = "riscv"; powerpc = "ppc64"; }.${stdenvNoCC.hostPlatform.linuxArch}};
  version = src.shortRev or src.dirtyShortRev; # allow for --override-input
in
stdenvNoCC.mkDerivation (rec {
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
  makeFlags = [ "XGCCPATH=${toolchain}/bin/" "KERNELVERSION=4.21-${version}" "UPDATED_SUBMODULES=1" ];
  installPhase = ''
    runHook preInstall
    mkdir -p  $out
    cp build/coreboot.rom $out/coreboot.rom
    runHook postInstall
  '';
} // extraArgs))
