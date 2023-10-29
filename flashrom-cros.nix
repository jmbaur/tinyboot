{ useMeson ? true, lib, stdenv, fetchgit, cmocka, meson, ninja, libftdi1, libjaylink, libusb1, pciutils, pkg-config, sphinx, bash-completion, ... }:
stdenv.mkDerivation (finalAttrs: {
  pname = "flashrom-cros";
  version = "unstable-${builtins.substring 0 7 finalAttrs.src.rev}";
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/flashrom";
    branchName = "master";
    rev = "d811062a2e351dcc78eaa901033d6119a8d2ddec";
    hash = "sha256-RxYh47SlHbUzyblIP4RKEi51Lt8Ntxe6wHpRHUNyxOw=";
  };
  patches = [ ./patches/flashrom-power-management.patch ];
  outputs = [ "out" ] ++ lib.optionals useMeson [ "lib" "dev" ];
  dontUseCmakeConfigure = useMeson;
  nativeBuildInputs = lib.optionals useMeson [ meson ninja ] ++ [ pkg-config sphinx bash-completion ];
  buildInputs = [ cmocka libftdi1 libusb1 pciutils libjaylink ];
  installFlags = lib.optional (!useMeson) "PREFIX=$(out)";
  meta.mainProgram = "flashrom";
})
