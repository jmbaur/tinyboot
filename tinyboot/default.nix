{ rustPlatform, lib, stdenv, pkg-config, pkgsStatic, crane, qemu, e2fsprogs, dosfstools, ... }:
let
  toEnvVar = s: lib.replaceStrings [ "-" ] [ "_" ] (lib.toUpper s);
  isCrossBuild = stdenv.hostPlatform.system != stdenv.buildPlatform.system;
  target = pkgsStatic.stdenv.hostPlatform.config;
  toolchain = pkgsStatic.pkgsBuildHost.rust-bin.stable.latest.default.override { targets = [ target ]; };
  env = (lib.optionalAttrs isCrossBuild {
    "CARGO_TARGET_${toEnvVar target}_RUNNER" = "qemu-${stdenv.hostPlatform.qemuArch}";
  }) // {
    "CARGO_TARGET_${toEnvVar target}_LINKER" = "${pkgsStatic.stdenv.cc.targetPrefix}ld";
    CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
    CARGO_BUILD_TARGET = target;
    CARGO_PRIMARY_PACKAGE = "tinyboot";
    HOST_CC = "${pkgsStatic.stdenv.cc.nativePrefix}cc";
    PKG_CONFIG_ALL_STATIC = true;
  };
  craneLib = crane.lib.${stdenv.buildPlatform.system};
in
(craneLib.overrideToolchain toolchain).buildPackage ({
  src = ./.;
  cargoToml = ./tinyboot/Cargo.toml;
  depsBuildBuild = lib.optional isCrossBuild qemu;
  nativeBuildInputs = [ rustPlatform.bindgenHook toolchain pkg-config dosfstools e2fsprogs ];
  buildInputs = with pkgsStatic; [ wolftpm ];
  passthru = { inherit env; };
} // env)
