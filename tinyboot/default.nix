{ clientOnly ? false, measuredBoot ? false, verifiedBoot ? false, verifiedBootPublicKey ? "/dev/null", lib, rustPlatform, wolftpm, pkg-config, installShellFiles }:
rustPlatform.buildRustPackage {
  pname = "tinyboot${lib.optionalString clientOnly "-client"}";
  version = "0.1.0";
  src = ./.;
  nativeBuildInputs = [ rustPlatform.bindgenHook pkg-config installShellFiles ];
  buildInputs = [ wolftpm ];
  cargoLock.lockFile = ./Cargo.lock;
  cargoBuildFlags = lib.optional clientOnly [ "--package" "tbootctl" ];
  cargoTestFlags = lib.optional clientOnly [ "--package" "tbootctl" ];
  buildFeatures = (lib.optional measuredBoot "measured-boot") ++ (lib.optional verifiedBoot "verified-boot");
  VERIFIED_BOOT_PUBLIC_KEY = verifiedBootPublicKey;
  postInstall = ''
    installShellCompletion ./target/*/$cargoBuildType/build/tbootctl-*/out/{tbootctl.bash,tbootctl.fish,_tbootctl}
  '';
}
