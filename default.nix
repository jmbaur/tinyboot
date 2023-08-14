{ rustPlatform, installShellFiles }:
rustPlatform.buildRustPackage {
  pname = "tinyboot";
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;
  strictDeps = true;
  nativeBuildInputs = [ installShellFiles ];
  stripDebugFlags = [ "--strip-all" ];
  cargoBuildFlags = [ "--package" "tbootbb" ];
  postInstall = ''
    installShellCompletion ./target/release/$cargoBuildType/build/tbootctl-*/out/{tbootctl.bash,tbootctl.fish,_tbootctl}
    for exe in tbootd tbootctl tbootui; do ln -s $out/bin/tbootbb $out/bin/$exe; done
  '';
}
