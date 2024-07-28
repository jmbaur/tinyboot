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
    branchName = "release-R128-15964.B";
    rev = "c0d660ac2911453c21d4868e46af714f508f2c19";
    hash = "sha256-7Ew6zm1pAb608sVBKWGeTnNZ2z07nE/xWcwQrnvW5yU=";
  };
  filesToInstall = [ "build/${platform}/release/bl31/bl31.elf" ];
  extraMakeFlags = [ "DISABLE_BIN_GENERATION=1" "COREBOOT=1" ];
  dontStrip = false;
  patches = [ ./toolchain.patch ];
  postInstall = ''
    mkdir -p $out/libexec && mv $out/bl31.elf $out/libexec/bl31.elf
  '';
  extraMeta.platforms = [ "aarch64-linux" ];
}
