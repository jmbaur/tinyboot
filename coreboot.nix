{ lib, stdenv, fetchgit, pkgsBuildBuild, python3, pkg-config, flashrom, openssl, ... }:
lib.makeOverridable ({ board, configFile, extraConfig ? "", ... }@args:
let
  toolchain = pkgsBuildBuild.coreboot-toolchain.${{ x86_64 = "i386"; arm64 = "aarch64"; arm = "arm"; riscv = "riscv"; powerpc = "ppc64"; }.${stdenv.hostPlatform.linuxArch}};
in
stdenv.mkDerivation ({
  pname = "coreboot-${board}";
  inherit (toolchain) version;
  src = fetchgit {
    inherit (toolchain.src) url rev;
    leaveDotGit = false;
    fetchSubmodules = true;
    sha256 = "sha256-DPaudCeK9SKu2eN1fad6a52ICs5d/GXCUFMdqAl65BE=";
  };
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
  makeFlags = [ "XGCCPATH=${toolchain}/bin/" ];
  installPhase = ''
    runHook preInstall
    mkdir -p  $out
    cp build/coreboot.rom $out/coreboot.rom
    runHook postInstall
  '';
} // (builtins.removeAttrs args [ "board" "configfile" "extraConfig" ])))
