{
  firmwareDirectory ? null,
  withLoader,
  withTools,

  callPackage,
  lib,
  openssl,
  pkg-config,
  stdenv,
  tinybootTools,
  xz,
  zig_0_14,
}:

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

  depsBuildBuild = [ zig_0_14 ];
  nativeBuildInputs = [ pkg-config ] ++ lib.optional (!withTools) tinybootTools;

  buildInputs =
    lib.optional withTools openssl # tboot-sign
    ++ lib.optional (withTools || stdenv.buildPlatform.canExecute stdenv.hostPlatform) xz # tboot-initrd
  ;

  dontInstall = true;
  doCheck = true;

  configurePhase = ''
    runHook preConfigure
    export ZIG_GLOBAL_CACHE_DIR=$TEMPDIR
    ln -s ${callPackage ../../build.zig.zon.nix { }} $ZIG_GLOBAL_CACHE_DIR/p
    zigBuildFlags=("-Dloader=${lib.boolToString withLoader}" "-Dtools=${lib.boolToString withTools}" "--release=safe" "-Dtarget=${stdenv.hostPlatform.qemuArch}-${stdenv.hostPlatform.parsed.kernel.name}")
    zigBuildFlags+=("-Ddynamic-linker=$(echo ${stdenv.cc.bintools.dynamicLinker})") # can contain a glob
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

  passthru = lib.optionalAttrs withLoader { initrdPath = "tboot-loader.cpio"; };
  meta.platforms = lib.platforms.linux;
}
