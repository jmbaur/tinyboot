{ useMeson ? true, lib, stdenv, fetchgit, cmocka, meson, ninja, libftdi1, libjaylink, libusb1, pciutils, pkg-config, sphinx, bash-completion, ... }:
stdenv.mkDerivation rec {
  pname = "flashrom-cros";
  version = builtins.substring 0 7 src.rev;
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/flashrom";
    branchName = "master";
    rev = "4e79d1e8f3259e5c91652e562464b684605661bc";
    hash = "sha256-2taTnBbnr4mWQ9HkSOksEeHdJmtEjW4k2rizsrq3/Oc=";
  };
  outputs = [ "out" ] ++ lib.optionals useMeson [ "lib" "dev" ];
  dontUseCmakeConfigure = useMeson;
  nativeBuildInputs = lib.optionals useMeson [ meson ninja ] ++ [ pkg-config sphinx bash-completion ];
  buildInputs = [ cmocka libftdi1 libusb1 pciutils libjaylink ];
  installFlags = lib.optional (!useMeson) "PREFIX=$(out)";
}
