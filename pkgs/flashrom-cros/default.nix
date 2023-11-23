{ stdenv, fetchgit, cmocka, meson, ninja, libftdi1, libjaylink, libusb1, pciutils, pkg-config, sphinx, bash-completion, ... }:
stdenv.mkDerivation (finalAttrs: {
  pname = "flashrom-cros";
  version = "unstable-${builtins.substring 0 7 finalAttrs.src.rev}";
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/flashrom";
    branchName = "master";
    rev = "a96ce7b9f3083b2cc63e8a86674e7565e718f20e";
    hash = "sha256-Z1i95pzTcQhbByLSKWHQdAwLGAEyFgr4UNJWhwin24U=";
  };
  patches = [ ./power-management.patch ];
  outputs = [ "out" "lib" "dev" ];
  dontUseCmakeConfigure = true;
  nativeBuildInputs = [ meson ninja pkg-config sphinx bash-completion ];
  buildInputs = [ cmocka libftdi1 libusb1 pciutils libjaylink ];
  meta.mainProgram = "flashrom";
})
