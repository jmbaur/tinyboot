{ platform, buildArmTrustedFirmware, fetchgit }:
buildArmTrustedFirmware {
  inherit platform;
  version = "2.9.0";
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/arm-trusted-firmware";
    branchName = "release-R120-15662.B";
    rev = "f8363a8e2c1ac8aa7340030f199daa72dcc9126b";
    hash = "sha256-EF1eCVKihtZ0LDwJbQVHIy/DQn91kGYAlG4QRZMVt2c=";
  };
  filesToInstall = [ "build/${platform}/release/bl31/bl31.elf" ];
  extraMakeFlags = [ "COREBOOT=1" ];
  dontStrip = false;
  postInstall = ''
    mkdir -p $out/libexec && mv $out/bl31.elf $out/libexec/bl31.elf
  '';
  extraMeta.platforms = [ "aarch64-linux" ];
}
