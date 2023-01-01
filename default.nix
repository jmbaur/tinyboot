{ lib, stdenv, pkgsStatic, rust-bin, crane, pkgconfig, qemu, ... }:
let
  toEnvVar = str: lib.replaceStrings [ "-" ] [ "_" ] (lib.toUpper str);
  # target = stdenv.hostPlatform.config;
  target = pkgsStatic.stdenv.hostPlatform.config;
  toolchain = (rust-bin.stable.latest.default.override {
    targets = [ target ];
  });
in
(crane.lib.${stdenv.buildPlatform.system}.overrideToolchain toolchain).buildPackage
  {
    src = ./.;
    cargoToml = ./tinyboot/Cargo.toml;
    nativeBuildInputs = [ pkgconfig toolchain ];
    CARGO_BUILD_TARGET = target;
    CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
    cargoExtraArgs = "-p tinyboot";
    passthru = { inherit toolchain; };
  } // lib.optionalAttrs (stdenv.hostPlatform.system != stdenv.buildPlatform.system) {
  depsBuildBuild = [ qemu ];
  "CARGO_TARGET_${toEnvVar target}_LINKER" = "${stdenv.cc.targetPrefix}cc";
  "CARGO_TARGET_${toEnvVar target}_RUNNER" = "qemu-aarch64";
}
