{
  stdenv,
  fetchgit,
  cmocka,
  meson,
  ninja,
  libftdi1,
  libjaylink,
  libusb1,
  pciutils,
  pkg-config,
  sphinx,
  bash-completion,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "flashrom-cros";
  version = "1.5.0-devel";
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/flashrom";
    branchName = "release-R130-16033.B";
    rev = "c1ab7468d28d164a30d598eb3e42a5febaf73bbc";
    hash = "sha256-0bUEsFOhwWahjkk+m+PmjOVD2dOk1S2dZTfpENRwgzg=";
  };
  patches = [ ./power-management.patch ];
  outputs = [
    "out"
    "lib"
    "dev"
  ];
  dontUseCmakeConfigure = true;
  strictDeps = true;
  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    sphinx
    bash-completion
  ];
  buildInputs = [
    cmocka
    libftdi1
    libusb1
    pciutils
    libjaylink
  ];
  meta.mainProgram = "flashrom";
})
