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
      name = "clap-0.10.0-oBajB434AQBDh-Ei3YtoKIRxZacVPF1iSwp3IX_ZB8f0";
      path = fetchzip {
        url = "https://github.com/Hejsil/zig-clap/archive/e47028deaefc2fb396d3d9e9f7bd776ae0b2a43a.tar.gz";
        hash = "sha256-leXnA97ITdvmBhD2YESLBZAKjBg+G4R/+PPPRslz/ec=";
      };
    }
    {
      name = "N-V-__8AADE9jALWhPS2ykOLbf8gUmr9r-SBwyzzpccbtBAv";
      path = fetchzip {
        url = "https://github.com/MBED-TLS/mbedtls/archive/v3.6.4.tar.gz";
        hash = "sha256-lSIdoqfIeBYJPQDBuKvXpPADZEqEuuFaJxM9LPhlgZ4=";
      };
    }
    {
      name = "N-V-__8AAPZ7fwBg4JoCzM_0o2A8wxH2hsUUeiU1iuZv53L5";
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

  zigBuildFlags = [
    "--color off"
    "-Doptimize=ReleaseSmall"
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
