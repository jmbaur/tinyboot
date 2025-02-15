{
  firmwareDirectory ? null,
  tinybootTools,
  withLoader,
  withTools,
  zigForTinyboot,

  callPackage,
  lib,
  openssl,
  pkg-config,
  stdenv,
  xz,
}:

let
  zigLibc =
    {
      "glibc" = "gnu";
      "musl" = "musl";
    }
    .${stdenv.hostPlatform.libc} or "none";
in
# Using zig-overlay (without the patches from nixpkgs) does not work well when
# doing sandboxed builds because of the following issue: https://github.com/ziglang/zig/issues/15898
assert stdenv.hostPlatform.isStatic && stdenv.hostPlatform.libc == "musl";
assert withTools != withLoader;
stdenv.mkDerivation {
  pname = "tinyboot-${if withTools then "tools" else "loader"}";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../../.;
    fileset = lib.fileset.unions [
      ../../build.zig
      ../../build.zig.zon
      ../../src
      ../../tests/keys/tboot/key.der
    ];
  };

  strictDeps = true;

  nativeBuildInputs = [
    pkg-config
    zigForTinyboot
  ] ++ lib.optional (!withTools) tinybootTools;

  buildInputs =
    lib.optional withTools openssl # tboot-sign
    ++ lib.optional (withTools || stdenv.buildPlatform.canExecute stdenv.hostPlatform) xz # tboot-initrd
  ;

  zigBuildFlags =
    [
      "--release=safe"
      "-Dcpu=baseline"
      "-Dtarget=${stdenv.hostPlatform.qemuArch}-${stdenv.hostPlatform.parsed.kernel.name}-${zigLibc}"
      "-Ddynamic-linker=${stdenv.cc.bintools.dynamicLinker}"
      "-Dloader=${lib.boolToString withLoader}"
      "-Dtools=${lib.boolToString withTools}"
    ]
    ++ lib.optionals (firmwareDirectory != null) [
      "-Dfirmware-directory=${firmwareDirectory}"
    ];

  dontInstall = true;
  doCheck = true;

  configurePhase = ''
    runHook preConfigure
    export ZIG_GLOBAL_CACHE_DIR=$TEMPDIR
    ln -s ${callPackage ../../build.zig.zon.nix { }} $ZIG_GLOBAL_CACHE_DIR/p
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    zig build install --prefix $out $zigBuildFlags
    runHook postBuild
  '';

  checkPhase = ''
    runHook preCheck
    zig build test $zigBuildFlags
    runHook postCheck
  '';

  passthru = lib.optionalAttrs withLoader { initrdPath = "tboot-loader.cpio"; };
  meta.platforms = lib.platforms.linux;
}
