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
  version = "unstable-${builtins.substring 0 7 finalAttrs.src.rev}";
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/flashrom";
    branchName = "release-R129-16002.B";
    rev = "a3b1a83d2b09eb5051b183e7c9b853fd16847905";
    hash = "sha256-pA+b0XPXgtTSnyfX7Je2Sy1YlY627nvyG8Y45btAuew=";
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
