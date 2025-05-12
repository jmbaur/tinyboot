{
  firmwareDirectory ? null,
  withLoader,
  withTools,

  fetchzip,
  lib,
  linkFarm,
  stdenv,
  tinybootTools,
  zig_0_14,
}:

let
  deps = linkFarm "tinyboot-deps" [
    {
      name = "12204387e122dd8b6828847165a7153c5d624b0a77217fd907c7f4f718ecce36e217";
      path = fetchzip {
        url = "https://github.com/Hejsil/zig-clap/archive/e47028deaefc2fb396d3d9e9f7bd776ae0b2a43a.tar.gz";
        hash = "sha256-leXnA97ITdvmBhD2YESLBZAKjBg+G4R/+PPPRslz/ec=";
      };
    }
    {
      name = "1220a6a30e67f7002fc1a2b4b832a9307a9ee6157898bd73347b485d1cd17b60a6d4";
      path = fetchzip {
        url = "https://github.com/wolfssl/wolfssl/archive/v5.8.0-stable.tar.gz";
        hash = "sha256-Rws9LN7hNDLc8rr1tyjzSQ8GJl8bEH4CjGuWpI3shSo";
      };
    }
    {
      name = "122060e09a02cccff4a3603cc311f686c5147a25358ae66fe772f9587c0be5971418";
      path = fetchzip {
        url = "https://github.com/facebook/zstd/archive/v1.5.7.tar.gz";
        hash = "sha256-tNFWIT9ydfozB8dWcmTMuZLCQmQudTFJIkSr0aG7S44=";
      };
    }
  ];
in
assert withTools != withLoader;
assert withTools -> firmwareDirectory == null;
stdenv.mkDerivation {
  pname = "tinyboot-${if withTools then "tools" else "loader"}";
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

  depsBuildBuild = [ zig_0_14 ];
  nativeBuildInputs = lib.optional (!withTools) tinybootTools;

  dontInstall = true;
  doCheck = true;

  configurePhase = ''
    runHook preConfigure

    export ZIG_GLOBAL_CACHE_DIR=$TEMPDIR

    ln -s ${deps} $ZIG_GLOBAL_CACHE_DIR/p

    zigBuildFlags=(
      "-Dloader=${lib.boolToString withLoader}"
      "-Dtools=${lib.boolToString withTools}"
      "-Doptimize=ReleaseSafe"
      "-Dtarget=${stdenv.hostPlatform.qemuArch}-linux"
    )

    ${lib.optionalString (firmwareDirectory != null) ''
      zigBuildFlags+=("-Dfirmware-directory=${firmwareDirectory}")
    ''}

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

  passthru = lib.optionalAttrs withLoader { initrdFile = "tboot-loader.cpio.zst"; };

  meta.platforms = lib.platforms.linux;
}
