{ lib, stdenv, fetchgit, pkgsBuildBuild, python3, pkg-config, flashrom, openssl, ... }:
lib.makeOverridable ({ board ? null, configFile, extraConfig ? "", extraArgs ? { } }:
let
  toolchain = pkgsBuildBuild.coreboot-toolchain.${{ i386 = "i386"; x86_64 = "i386"; arm64 = "aarch64"; arm = "arm"; riscv = "riscv"; powerpc = "ppc64"; }.${stdenv.hostPlatform.linuxArch}};
in
stdenv.mkDerivation ({
  pname = "coreboot-${if (board) != null then board else "unknown"}";
  inherit (toolchain) version;
  src = fetchgit {
    inherit (toolchain.src) url rev;
    hash = "sha256-q8V+rKm2imf9uEFq0+sTzW7zLn49PaOVQUs5q3Wj9F0=";
  };
  patches = [ ./patches/coreboot-fitimage-memlayout.patch ./patches/coreboot-atf-loglevel.patch ];
  depsBuildBuild = [ pkgsBuildBuild.stdenv.cc ];
  nativeBuildInputs = [ python3 pkg-config ];
  buildInputs = [ flashrom openssl ];
  postPatch = ''
    patchShebangs util
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
  makeFlags = [ "XGCCPATH=${toolchain}/bin/" "BUILD_TIMELESS=1" "UPDATED_SUBMODULES=1" ];
  installPhase = ''
    runHook preInstall
    mkdir -p  $out
    cp build/coreboot.rom $out/coreboot.rom
    runHook postInstall
  '';
} // extraArgs))
