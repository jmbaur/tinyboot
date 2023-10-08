{ stdenv, rustPlatform, pkgsBuildBuild }:
rustPlatform.buildRustPackage {
  pname = "tinyboot";
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;
  strictDeps = true;
  depsBuildBuild = [ pkgsBuildBuild.stdenv.cc ];
  env.CARGO_BUILD_TARGET = stdenv.hostPlatform.config;
}
