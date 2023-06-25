{ clientOnly ? false, measuredBoot ? false, verifiedBoot ? false, verifiedBootPublicKey ? "/dev/null", lib, rustPlatform, pkgsBuildBuild, wolftpm, pkg-config, installShellFiles }:
rustPlatform.buildRustPackage ({
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;
  postInstall = ''
    installShellCompletion ./target/*/$cargoBuildType/build/tbootctl-*/out/{tbootctl.bash,tbootctl.fish,_tbootctl}
  '';
} // (if clientOnly then {
  pname = "tinyboot-client";
  nativeBuildInputs = [ installShellFiles ];
  cargoBuildFlags = lib.optional clientOnly [ "--package" "tbootctl" ];
  cargoTestFlags = lib.optional clientOnly [ "--package" "tbootctl" ];
} else {
  pname = "tinyboot";
  depsBuildBuild = [ pkgsBuildBuild.rustPlatform.bindgenHook ];
  nativeBuildInputs = [ pkg-config installShellFiles ];
  buildInputs = [ wolftpm ];
  buildFeatures = (lib.optional measuredBoot "measured-boot") ++ (lib.optional verifiedBoot "verified-boot");
  VERIFIED_BOOT_PUBLIC_KEY = verifiedBootPublicKey;
}))
