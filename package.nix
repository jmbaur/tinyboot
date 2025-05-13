{
  firmwareDirectory ? null,

  fetchzip,
  lib,
  linkFarm,
  stdenvNoCC,
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
      name = "12208ccec046f4145e785104436a61ca837b944f14d7135412f80fee38d8ceee7495";
      path = fetchzip {
        url = "https://github.com/MBED-TLS/mbedtls/archive/v3.6.3.1.tar.gz";
        hash = "sha256-koZAtExQguvfQ2Jf8xidKyLzCQoWrVIY73AYFjG0tMg=";
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
stdenvNoCC.mkDerivation {
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

  depsBuildBuild = [ zig_0_14 ];

  dontInstall = true;
  doCheck = true;

  zigBuildFlags =
    [
      "--color off"
      "-Doptimize=ReleaseSafe"
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
