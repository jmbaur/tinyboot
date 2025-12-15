{
  firmwareDirectory ? null,

  lib,
  stdenvNoCC,
  zig_0_15,
}:

stdenvNoCC.mkDerivation (
  finalAttrs:
  let
    deps = stdenvNoCC.mkDerivation {
      pname = finalAttrs.pname + "-deps";
      inherit (finalAttrs) src version;
      depsBuildBuild = [ zig_0_15 ];
      buildCommand = ''
        export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
        runHook unpackPhase
        cd $sourceRoot
        zig build --fetch
        mv $ZIG_GLOBAL_CACHE_DIR/p $out
      '';
      outputHashAlgo = null;
      outputHashMode = "recursive";
      outputHash = "sha256-GGlddHaG+3KzNmWvJuvbId7VTqLvTq/hvquZh86+alc=";
    };
  in
  {
    pname = "tinyboot";
    version = "0.1.0";

    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./build.zig
        ./build.zig.zon
        ./deps
        ./src
      ];
    };

    strictDeps = true;

    depsBuildBuild = [ zig_0_15 ];

    dontInstall = true;
    doCheck = true;
    dontStrip = true;

    zigBuildFlags = [
      "--color off"
      "--release=safe"
      "-Dtarget=${stdenvNoCC.hostPlatform.qemuArch}-${stdenvNoCC.hostPlatform.parsed.kernel.name}"
    ]
    ++ lib.optionals (firmwareDirectory != null) [
      "-Dfirmware-directory=${firmwareDirectory}"
    ];

    configurePhase = ''
      runHook preConfigure

      export ZIG_GLOBAL_CACHE_DIR=$TEMPDIR

      ln -s ${deps} $ZIG_GLOBAL_CACHE_DIR/p

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      zig build install --prefix $out ''${zigBuildFlags[@]}
      runHook postBuild
    '';

    checkPhase = ''
      runHook preCheck
      zig build test ''${zigBuildFlags[@]}
      runHook postCheck
    '';

    passthru.initrdFile = "tboot-loader.cpio.zst";

    meta.platforms = lib.platforms.linux;
  }
)
