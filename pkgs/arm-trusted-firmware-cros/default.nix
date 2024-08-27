{
  platform,
  buildArmTrustedFirmware,
  fetchgit,
}:
buildArmTrustedFirmware {
  inherit platform;
  version = "2.10.0";
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/arm-trusted-firmware";
    branchName = "release-R129-16002.B";
    rev = "9877b6ef1ee1cb8ab72a6611c37ffa589ce50f18";
    hash = "sha256-t17BGsAyUeGLWHpNkCxSUYdahWRZNP2m42TpLYOdRfo=";
  };
  filesToInstall = [ "build/${platform}/release/bl31/bl31.elf" ];
  extraMakeFlags = [
    "DISABLE_BIN_GENERATION=1"
    "COREBOOT=1"
  ];
  dontStrip = false;
  patches = [ ./toolchain.patch ];
  postInstall = ''
    mkdir -p $out/libexec && mv $out/bl31.elf $out/libexec/bl31.elf
  '';
  extraMeta.platforms = [ "aarch64-linux" ];
}
