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
  ...
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "flashrom-cros";
  version = "unstable-${builtins.substring 0 7 finalAttrs.src.rev}";
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/flashrom";
    branchName = "release-R125-15853.B";
    rev = "90e2f5c9516d4e9bebecd10ae7aeefbb5fca7734";
    hash = "sha256-RonTIForEv2rU0nEEjisYATgat91VBC+JJ8VgsFLfuw=";
  };
  patches = [ ./power-management.patch ];
  outputs = [
    "out"
    "lib"
    "dev"
  ];
  dontUseCmakeConfigure = true;
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
