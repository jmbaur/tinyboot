{ stdenv, cmake, cmocka, fetchgit, libftdi1, libjaylink, libusb1, meson, ninja, pciutils, pkg-config, sphinx, bash-completion, ... }:
stdenv.mkDerivation rec {
  pname = "flashrom-cros";
  version = builtins.substring 0 7 src.rev;

  src = fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/flashrom";
    rev = "af7ed034e211ce9597d1605ccf5d5b0d71f51ab4";
    sha256 = "1yxq2109gz16ajy31ijifhsimi8jnp3x53znl46k36wzg49qn7lh";
  };
  patches = [ ./0001-flashrom-cros-no-powerd.patch ];

  dontUseCmakeConfigure = true;
  nativeBuildInputs = [ cmake meson ninja pkg-config sphinx bash-completion ];
  buildInputs = [ cmocka libftdi1 libusb1 pciutils libjaylink ];
}
