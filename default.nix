{ pkgsStatic, lib, ... }:
let
  cargoTOML = lib.importTOML ./tinyboot/Cargo.toml;
in
pkgsStatic.rustPlatform.buildRustPackage {
  pname = cargoTOML.package.name;
  version = cargoTOML.package.version;
  src = ./.;
  buildAndTestSubdir = "tinyboot";
  cargoLock.lockFile = ./Cargo.lock;
  postInstall = ''
    ln -s $out/bin/tinyboot $out/init
  '';
}
