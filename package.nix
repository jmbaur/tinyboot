{
  firmwareDirectory ? null,
  withLoader,
  withTools,

  fetchzip,
  lib,
  linkFarm,
  openssl,
  pkg-config,
  stdenv,
  tinybootTools,
  zig_0_14,
  writeText,
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
      name = "122008a7c2435438a09afd5a05773d9029e83908e2f4c631cf3d8aa118603b1ff84a";
      path = fetchzip {
        url = "https://github.com/tukaani-project/xz/archive/v5.8.1.tar.gz";
        hash = "sha256-vGUNoX5VTM0aQ5GmBPXip97WGN9vaVrQLE9msToZyKs=";
      };
    }
  ];

  libcFile = writeText "zig-libc-file" ''
    include_dir=${lib.getDev stdenv.cc.libc}/include
    sys_include_dir=${lib.getDev stdenv.cc.libc}/include
    crt_dir=${lib.getLib stdenv.cc.libc}/lib
    msvc_lib_dir=
    kernel32_lib_dir=
    gcc_dir=
  '';
in
assert withTools != withLoader;
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
  nativeBuildInputs = [ pkg-config ] ++ lib.optional (!withTools) tinybootTools;

  buildInputs = lib.optional withTools openssl; # tboot-sign

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
      "-Dtarget=${stdenv.hostPlatform.qemuArch}-linux-${
        if stdenv.hostPlatform.isGnu then "gnu" else "musl"
      }"
      "-Ddynamic-linker=$(cat $NIX_CC/nix-support/dynamic-linker)"
    )

    ${lib.optionalString withTools ''
      zigBuildFlags+=("--libc ${libcFile}")
    ''}

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

  passthru = lib.optionalAttrs withLoader { initrdFile = "tboot-loader.cpio"; };

  meta.platforms = lib.platforms.linux;
}
