{ clientOnly ? false, lib, rustPlatform, installShellFiles }:
rustPlatform.buildRustPackage ({
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;
  strictDeps = true;
  stripDebugFlags = [ "--strip-all" ];
  postInstall = ''
    installShellCompletion ./target/release/$cargoBuildType/build/tbootctl-*/out/{tbootctl.bash,tbootctl.fish,_tbootctl}
  '';
} // (if clientOnly then {
  pname = "tinyboot-client";
  nativeBuildInputs = [ installShellFiles ];
  cargoBuildFlags = lib.optional clientOnly [ "--package" "tbootctl" ];
  cargoTestFlags = lib.optional clientOnly [ "--package" "tbootctl" ];
} else {
  pname = "tinyboot";
  nativeBuildInputs = [ installShellFiles ];
}))
