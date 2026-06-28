{
  firmwareDirectory ? null,

  breakpointHook,
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
      outputHash = "sha256-+i28+Eq7Abl3txiL2Up5EAT3fS9WIDImKNsVoXEjGmI=";
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
      breakpointHook
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
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR
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

    postFixup = ''
      find $out/bin -type f | while read i; do
        nuke-refs -e $out $i
      done
    '';

    passthru.initrdFile = "tboot-loader.cpio.zst";

    meta.platforms = lib.platforms.linux;
  }
)
