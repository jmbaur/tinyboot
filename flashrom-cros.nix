{ useMeson ? true, lib, stdenv, fetchgit, cmocka, meson, ninja, libftdi1, libjaylink, libusb1, pciutils, pkg-config, sphinx, bash-completion, ... }:
stdenv.mkDerivation rec {
  pname = "flashrom-cros";
  version = builtins.substring 0 7 src.rev;
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/flashrom";
    branchName = "master";
    rev = "4564183f4f3a48dfd34b99ba576b721230224a71";
    hash = "sha256-PPLyjudiEGauvWdZvaJsDMItbo96GF1BpwFxkobEGPA=";
  };
  dontUseCmakeConfigure = useMeson;
  nativeBuildInputs = lib.optionals useMeson [ meson ninja ] ++ [ pkg-config sphinx bash-completion ];
  buildInputs = [ cmocka libftdi1 libusb1 pciutils libjaylink ];
  installFlags = lib.optional (!useMeson) "PREFIX=$(out)";
}
