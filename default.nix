{ rustPlatform, keyutils, pkg-config }:
rustPlatform.buildRustPackage {
  pname = "tinyboot";
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;
  strictDeps = true;
  nativeBuildInputs = [ pkg-config rustPlatform.bindgenHook ];
  buildInputs = [ keyutils ];
  stripDebugFlags = [ "--strip-all" ];
  cargoBuildFlags = [ "--package" "tbootbb" ];
  postInstall = ''
    for exe in tbootd tbootui; do ln -s $out/bin/tbootbb $out/bin/$exe; done
  '';
}
