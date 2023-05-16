{ buildFeatures ? [ ], verifiedBootPublicKey ? "/dev/null", rustPlatform, wolftpm, pkg-config, installShellFiles }:
rustPlatform.buildRustPackage {
  pname = "tinyboot";
  version = "0.1.0";
  src = ./.;
  nativeBuildInputs = [ rustPlatform.bindgenHook pkg-config installShellFiles ];
  buildInputs = [ wolftpm ];
  cargoLock.lockFile = ./Cargo.lock;
  VERIFIED_BOOT_PUBLIC_KEY = verifiedBootPublicKey;
  inherit buildFeatures;
  postInstall = ''
    installShellCompletion \
      ./target/*/$cargoBuildType/build/tbootctl-*/out/{tbootctl.bash,tbootctl.fish,_tbootctl}
  '';
}
