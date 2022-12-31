{ stdenv, pkgsStatic, rust-bin, crane, ... }:
let
  target = pkgsStatic.stdenv.hostPlatform.config;
  toolchain = (rust-bin.stable.latest.default.override {
    targets = [ target ];
  });
in
(crane.lib.${stdenv.buildPlatform.system}.overrideToolchain toolchain).buildPackage {
  src = ./.;
  cargoToml = ./tinyboot/Cargo.toml;
  CARGO_BUILD_TARGET = target;
  CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
  cargoExtraArgs = "-p tinyboot";
  postInstall = ''
    ln -s $out/bin/tinyboot $out/init
    ln -s $out/bin/tinyboot $out/linuxrc
  '';
  passthru = { inherit toolchain; };
}
