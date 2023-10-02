{ package ? "tbootbb", lib, stdenv, rustPlatform, pkgsBuildBuild, pkg-config, keyutils }:
rustPlatform.buildRustPackage {
  pname = "tinyboot";
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;
  strictDeps = true;
  depsBuildBuild = [ pkgsBuildBuild.stdenv.cc ];
  nativeBuildInputs = [ rustPlatform.bindgenHook pkg-config ];
  buildInputs = [ keyutils ];
  env.CARGO_BUILD_TARGET = stdenv.hostPlatform.config;
  stripDebugFlags = [ "--strip-all" ];
  cargoBuildFlags = [ "--package" package ];
  postInstall = lib.optionalString (package == "tbootbb") ''
    for exe in init tbootd tbootui; do ln -s $out/bin/tbootbb $out/bin/$exe; done
  '';
}
