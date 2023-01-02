{ lib, stdenv, pkgsBuildHost, pkgsStatic, crane, qemu, ... }:
let
  toEnvVar = s: lib.replaceStrings [ "-" ] [ "_" ] (lib.toUpper s);
  target = pkgsStatic.stdenv.hostPlatform.config;
  toolchain = pkgsBuildHost.rust-bin.stable.latest.default.override {
    targets = [ target ];
  };
  env = {
    "CARGO_TARGET_${toEnvVar target}_LINKER" = "${stdenv.cc.targetPrefix}cc";
    "CARGO_TARGET_${toEnvVar target}_RUNNER" = "qemu-${stdenv.hostPlatform.qemuArch}";
    CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
    CARGO_BUILD_TARGET = target;
    CARGO_PRIMARY_PACKAGE = "tinyboot";
    HOST_CC = "${stdenv.cc.nativePrefix}cc";
  };
in
(crane.lib.${stdenv.buildPlatform.system}.overrideToolchain toolchain).buildPackage ({
  src = ./.;
  cargoToml = ./tinyboot/Cargo.toml;
  depsBuildBuild = [ qemu ];
  nativeBuildInputs = [ toolchain ];
  passthru = { inherit env; };
} // env)
