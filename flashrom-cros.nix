{ useMeson ? true, lib, stdenv, fetchgit, cmocka, meson, ninja, libftdi1, libjaylink, libusb1, pciutils, pkg-config, sphinx, bash-completion, ... }:
stdenv.mkDerivation rec {
  pname = "flashrom-cros";
  version = builtins.substring 0 7 src.rev;
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/flashrom";
    branchName = "master";
    rev = "0542969a51a834ed1dedd5a86857881c9a4aa299";
    hash = "sha256-6lqNR8HQuTIO3sSwW/B4pWEZoJcqGVUa89tnUIvX7wU=";
  };
  patches = [ ./patches/flashrom-power-management.patch ];
  outputs = [ "out" ] ++ lib.optionals useMeson [ "lib" "dev" ];
  dontUseCmakeConfigure = useMeson;
  nativeBuildInputs = lib.optionals useMeson [ meson ninja ] ++ [ pkg-config sphinx bash-completion ];
  buildInputs = [ cmocka libftdi1 libusb1 pciutils libjaylink ];
  installFlags = lib.optional (!useMeson) "PREFIX=$(out)";
}
