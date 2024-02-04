{ stdenv, fetchgit, cmocka, meson, ninja, libftdi1, libjaylink, libusb1, pciutils, pkg-config, sphinx, bash-completion, ... }:
stdenv.mkDerivation (finalAttrs: {
  pname = "flashrom-cros";
  version = "unstable-${builtins.substring 0 7 finalAttrs.src.rev}";
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/flashrom";
    branchName = "master";
    rev = "763aa467b938cb28e137a6b69b55658f07836298";
    hash = "sha256-trlkJU4qSmzZXEe33fpmVmwOd3w9H45CUlyiB/lkzDA=";
  };
  patches = [ ./power-management.patch ];
  outputs = [ "out" "lib" "dev" ];
  dontUseCmakeConfigure = true;
  nativeBuildInputs = [ meson ninja pkg-config sphinx bash-completion ];
  buildInputs = [ cmocka libftdi1 libusb1 pciutils libjaylink ];
  meta.mainProgram = "flashrom";
})
