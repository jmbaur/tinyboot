{
  firmwareDirectory ? null,

  lib,
  nukeReferences,
  stdenvNoCC,
  zig,
}:

stdenvNoCC.mkDerivation (
  finalAttrs:
  let
    deps = stdenvNoCC.mkDerivation {
      pname = finalAttrs.pname + "-deps";
      inherit (finalAttrs) src version;
      depsBuildBuild = [ zig ];
      buildCommand = ''
        export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
        runHook unpackPhase
        cd $sourceRoot
        zig build --fetch
        mv $ZIG_GLOBAL_CACHE_DIR/p $out
      '';
      outputHashAlgo = null;
      outputHashMode = "recursive";
      outputHash = "sha256-9gTF1Ir7HhgZqg1iswQEF4buU+KpLoCpHJuPneIKMBE=";
    };

    buildRunnerCache = stdenvNoCC.mkDerivation {
      pname = finalAttrs.pname + "-build-runner-cache";
      inherit (finalAttrs) version zigBuildFlags;

      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./build.zig
          ./build.zig.zon
          ./deps
          ./vendor
        ];
      };

      nativeBuildInputs = [ zig ];

      __structuredAttrs = true;
      strictDeps = true;
      dontInstall = true;
      dontFixup = true;

      buildPhase = ''
        runHook preBuild
        export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
        mkdir -p $ZIG_GLOBAL_CACHE_DIR $out
        ln -s ${deps} $ZIG_GLOBAL_CACHE_DIR/p
        # --list-steps compiles the build script without running any of the
        # steps it describes.
        zig build --list-steps ''${zigBuildFlags[@]} > /dev/null
        rm $ZIG_GLOBAL_CACHE_DIR/p
        cp -r $ZIG_GLOBAL_CACHE_DIR/. $out/
        runHook postBuild
      '';
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
      zig
    ];

    # Prevent zig (or anything else) from being in the runtime closure
    allowedReferences = [ ];

    __structuredAttrs = true;
    doCheck = true;
    strictDeps = true;
    dontInstall = true;

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
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      mkdir -p $ZIG_GLOBAL_CACHE_DIR
      cp -r ${buildRunnerCache}/. $ZIG_GLOBAL_CACHE_DIR/
      chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
      ln -s ${deps} $ZIG_GLOBAL_CACHE_DIR/p
      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      zig build -j$NIX_BUILD_CORES install --prefix $out ''${zigBuildFlags[@]}
      runHook postBuild
    '';

    checkPhase = ''
      runHook preCheck
      zig build -j$NIX_BUILD_CORES test ''${zigBuildFlags[@]}
      runHook postCheck
    '';

    postFixup = ''
      find $out -type f | while read i; do
        nuke-refs -e $out $i
      done
    '';

    passthru.initrdFile = "tboot-loader.cpio.zst";

    meta.platforms = lib.platforms.linux;
  }
)
