{
  callPackage,
  corebootSupport ? true,
  fetchpatch,
  lib,
  stdenv,
  xz,
  zig_0_12,
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
    (zig_0_12.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        (fetchpatch {
          name = "Fix usage of unexpectedErrno";
          url = "https://github.com/ziglang/zig/commit/e4b86875ebdebd5279bea546b7cde143ba4ddb23.patch";
          hash = "sha256-dBdx7k8uDO8+OsvLAiF8y+jSdkV2zu/1VfQS6v3i3Tk=";
        })
      ];
    }))
    xz
  ];

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
    xz --check=crc32 --lzma2=dict=512KiB $out/tboot-loader.cpio
    runHook postInstall
  '';

  meta.platforms = lib.platforms.linux;
}
