{ lib, stdenv, pkgsBuildHost, pkgsStatic, crane, qemu, ... }:
let
  toEnvVar = s: lib.replaceStrings [ "-" ] [ "_" ] (lib.toUpper s);
  target = pkgsStatic.stdenv.hostPlatform.config;
  toolchain = pkgsBuildHost.rust-bin.stable.latest.default.override {
    targets = [ target ];
  };
  env = {
    CARGO_BUILD_TARGET = target;
    CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
    "CARGO_TARGET_${toEnvVar target}_LINKER" = "${stdenv.cc.targetPrefix}cc";
    "CARGO_TARGET_${toEnvVar target}_RUNNER" = "qemu-aarch64";
  };
in
(crane.lib.${stdenv.buildPlatform.system}.overrideToolchain
  toolchain
).buildPackage ({
  src = ./.;
  cargoToml = ./tinyboot/Cargo.toml;
  depsBuildBuild = [ qemu ];
  nativeBuildInputs = [ toolchain ];
  HOST_CC = "${stdenv.cc.nativePrefix}cc";
  cargoExtraArgs = "-p tinyboot";
  passthru = { inherit env; };
} // env)
