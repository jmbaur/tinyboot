{
  firmwareDirectory ? null,

  fetchzip,
  lib,
  linkFarm,
  stdenvNoCC,
  zig_0_15,
}:

let
  deps = linkFarm "tinyboot-deps" [
    {
      name = "clap-0.11.0-oBajB-3nAQAWHQx0oqlPOm4KLcvO4xEEvxg31WMlFh_Q";
      path = fetchzip {
        url = "https://github.com/jmbaur/zig-clap/archive/76f87a072e1be64834829ccba625aef0f0bd4fdd.tar.gz";
        hash = "sha256-scA/YZ0ttRn6jaI2HliBQFyufP0T5mOdu1Ega1yTV2A=";
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

  depsBuildBuild = [ zig_0_15 ];

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
