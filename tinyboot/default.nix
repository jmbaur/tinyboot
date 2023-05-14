{ buildFeatures ? [ ], verifiedBootPublicKey ? "/dev/null", rustPlatform, wolftpm, pkg-config }:
rustPlatform.buildRustPackage {
  pname = "tinyboot";
  version = "0.1.0";
  src = ./.;
  nativeBuildInputs = [ rustPlatform.bindgenHook pkg-config ];
  buildInputs = [ wolftpm ];
  cargoLock.lockFile = ./Cargo.lock;
  VERIFIED_BOOT_PUBLIC_KEY = verifiedBootPublicKey;
  inherit buildFeatures;
}