{
  callPackage,
  corebootSupport ? true,
  debug ? false,
  lib,
  pkgsBuildBuild,
  stdenv,
  xz,
  zigSrc,
}:
let
  zigArgs = [
    "-Doptimize=ReleaseSafe"
    "-Dtarget=${stdenv.hostPlatform.qemuArch}-linux"
    "-Dcoreboot=${lib.boolToString corebootSupport}"
    "-Dloglevel=${toString (if debug then 3 else 2)}" # https://github.com/ziglang/zig/blob/084c2cd90f79d5e7edf76b7ddd390adb95a27f0c/lib/std/log.zig#L78
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
    (pkgsBuildBuild.zig_0_12.overrideAttrs (old: {
      src = zigSrc;
    }))
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
