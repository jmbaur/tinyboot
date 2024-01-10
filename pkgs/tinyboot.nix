{ lib, stdenv, pkgsBuildBuild, corebootSupport ? true }:
let
  zigArgs = [
    "-Dcpu=baseline"
    "-Doptimize=ReleaseSafe"
    "-Dtarget=${stdenv.hostPlatform.qemuArch}-linux"
    "-Dcoreboot=${lib.boolToString corebootSupport}"
    "--verbose"
  ];
in
stdenv.mkDerivation {
  pname = "tinyboot";
  version = "0.1.0";

  src = ../.;

  depsBuildBuild = [ pkgsBuildBuild.zig_0_11 ];

  doCheck = true;

  configurePhase = ''
    runHook preConfigure
    export ZIG_GLOBAL_CACHE_DIR=/tmp
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    zig build ${toString zigArgs}
    runHook postBuild
  '';

  checkPhase = ''
    runHook preCheck
    zig build test ${toString zigArgs}
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    zig build install --prefix $out ${toString zigArgs}
    runHook postInstall
  '';

  meta.platforms = lib.platforms.linux;
}
