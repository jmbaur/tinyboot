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
stdenv.mkDerivation {
  pname = "flashrom-cros";
  version = "1.5.0-devel";
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/flashrom";
    branchName = "release-R134-16181.B";
    rev = "f9e2b906229ec01bd0bb3321e9c424c6796d5408";
    hash = "sha256-4Loiu040yyyyo+/deZGp5mmO0kljhXNZMvRbZ0c4mC0=";
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
}
