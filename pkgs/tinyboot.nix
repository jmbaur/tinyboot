{
  callPackage,
  corebootSupport ? true,
  lib,
  stdenv,
  xz,
  zig,
}:
let
  zigArgs = [
    "-Doptimize=ReleaseSafe"
    "-Dtarget=${stdenv.hostPlatform.qemuArch}-linux"
    "-Dcoreboot=${lib.boolToString corebootSupport}"
  ];
in
stdenv.mkDerivation {
  pname = "tinyboot";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
    ];
  };

  nativeBuildInputs = [
    zig
    xz
  ];

  doCheck = true;

  configurePhase = ''
    runHook preConfigure
    export ZIG_GLOBAL_CACHE_DIR=/tmp
    ln -s ${callPackage ../deps.nix { }} $ZIG_GLOBAL_CACHE_DIR/p
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
    xz --check=crc32 --lzma2=dict=512KiB $out/tboot-loader.cpio
    runHook postInstall
  '';

  meta.platforms = lib.platforms.linux;
}
