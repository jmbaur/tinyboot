{ src, lib, stdenv, cmake, cmocka, libftdi1, libjaylink, libusb1, meson, ninja, pciutils, pkg-config, sphinx, bash-completion, ... }:
stdenv.mkDerivation {
  pname = "flashrom-cros";
  version = src.shortRev;
  src = src.outPath;
  patches = [ ./patches/flashrom-cros-no-powerd.patch ];
  dontUseCmakeConfigure = true;
  nativeBuildInputs = [ cmake meson ninja pkg-config sphinx bash-completion ];
  buildInputs = [ cmocka libftdi1 libusb1 pciutils libjaylink ];
  mesonFlags = [ (lib.mesonOption "man-pages" "enabled") ];
}
