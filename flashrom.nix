{ stdenv, fetchgit, cmake, cmocka, libftdi1, libjaylink, libusb1, meson, ninja, pciutils, pkg-config, sphinx, bash-completion, ... }:
stdenv.mkDerivation rec {
  pname = "flashrom-cros";
  version = builtins.substring 0 7 src.rev;
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/flashrom";
    hash = "sha256-PPLyjudiEGauvWdZvaJsDMItbo96GF1BpwFxkobEGPA=";
  };
  patches = [ ./patches/flashrom-cros-no-powerd.patch ];
  dontUseCmakeConfigure = true;
  nativeBuildInputs = [ cmake meson ninja pkg-config sphinx bash-completion ];
  buildInputs = [ cmocka libftdi1 libusb1 pciutils libjaylink ];
}
