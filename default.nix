{ lib, stdenv, pkgsBuildHost, pkgsStatic, crane, qemu, e2fsprogs, dosfstools, ... }:
let
  toEnvVar = s: lib.replaceStrings [ "-" ] [ "_" ] (lib.toUpper s);
  isCrossBuild = stdenv.hostPlatform.system != stdenv.buildPlatform.system;
  target = pkgsStatic.stdenv.hostPlatform.config;
  toolchain = pkgsBuildHost.rust-bin.stable.latest.default.override { targets = [ target ]; };
  env = (lib.optionalAttrs isCrossBuild {
    "CARGO_TARGET_${toEnvVar target}_LINKER" = "${stdenv.cc.targetPrefix}cc";
    "CARGO_TARGET_${toEnvVar target}_RUNNER" = "qemu-${stdenv.hostPlatform.qemuArch}";
  }) // {
    CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
    CARGO_BUILD_TARGET = target;
    CARGO_PRIMARY_PACKAGE = "tinyboot";
    HOST_CC = "${stdenv.cc.nativePrefix}cc";
  };
  craneLib = crane.lib.${stdenv.buildPlatform.system};
  sourceFilter = src:
    let
      notSrc = path: _type: builtins.match "src" path == null;
      notSrcOrCargo = path: type:
        (notSrc path type) || (craneLib.filterCargoSources path type);
    in
    lib.cleanSourceWith {
      src = lib.cleanSource src;
      filter = notSrcOrCargo;
    };
in
(craneLib.overrideToolchain toolchain).buildPackage ({
  src = sourceFilter ./.;
  cargoToml = ./tinyboot/Cargo.toml;
  depsBuildBuild = lib.optional isCrossBuild qemu;
  nativeBuildInputs = [
    toolchain
    dosfstools
    e2fsprogs
  ];
  passthru = { inherit env; };
} // env)
