{
  firmwareDirectory ? null,

  lib,
  nukeReferences,
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
        ./vendor
      ];
    };

    nativeBuildInputs = [
      nukeReferences
      zig_0_15
    ];

    # Prevent zig (or anything else) from being in the runtime closure
    allowedReferences = [ ];

    __structuredAttrs = true;
    doCheck = true;
    strictDeps = true;

    zigBuildFlags = [
      "-Dtarget=${stdenvNoCC.hostPlatform.qemuArch}-${stdenvNoCC.hostPlatform.parsed.kernel.name}"
    ]
    ++ lib.optionals (firmwareDirectory != null) [
      "-Dfirmware-directory=${firmwareDirectory}"
    ];

    postConfigure = ''
      ln -s ${deps} $ZIG_GLOBAL_CACHE_DIR/p
    '';

    postFixup = ''
      find $out/bin -type f | while read i; do
        nuke-refs -e $out $i
      done
    '';

    passthru.initrdFile = "tboot-loader.cpio.zst";

    meta.platforms = lib.platforms.linux;
  }
)
