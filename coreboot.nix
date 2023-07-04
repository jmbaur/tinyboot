{ lib, stdenv, fetchgit, pkgsBuildBuild, python3, pkg-config, flashrom, openssl, ... }:
lib.makeOverridable ({ board ? null, configFile, extraConfig ? "", extraArgs ? { } }:
let
  toolchain = pkgsBuildBuild.coreboot-toolchain.${{ x86_64 = "i386"; arm64 = "aarch64"; arm = "arm"; riscv = "riscv"; powerpc = "ppc64"; }.${stdenv.hostPlatform.linuxArch}};
in
stdenv.mkDerivation ({
  pname = "coreboot-${if (board) != null then board else "unknown"}";
  inherit (toolchain) version;
  src = fetchgit {
    inherit (toolchain.src) url rev;
    fetchSubmodules = true;
    hash = "sha256-DPaudCeK9SKu2eN1fad6a52ICs5d/GXCUFMdqAl65BE=";
  };
  patches = [ ./patches/coreboot-fitimage-memlayout.patch ./patches/coreboot-atf-loglevel.patch ];
  depsBuildBuild = [ pkgsBuildBuild.stdenv.cc ];
  nativeBuildInputs = [ python3 pkg-config ];
  buildInputs = [ flashrom openssl ];
  postPatch = ''
    patchShebangs util 3rdparty/chromeec/util
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
  makeFlags = [ "XGCCPATH=${toolchain}/bin/" ];
  installPhase = ''
    runHook preInstall
    mkdir -p  $out
    cp build/coreboot.rom $out/coreboot.rom
    runHook postInstall
  '';
} // extraArgs))
