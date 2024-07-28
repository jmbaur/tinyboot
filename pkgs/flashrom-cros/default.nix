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
    branchName = "release-R128-15964.B";
    rev = "f102ba8191fcc77328189067a5b9f537849df070";
    hash = "sha256-3UDy6ocgQ93dTPP2EF4HYnhh0JUmZRv+DbLI6in00PM=";
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
