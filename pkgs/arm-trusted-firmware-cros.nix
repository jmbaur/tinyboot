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
    branchName = "release-R122-15753.B";
    rev = "02091541d70e6438c04d6f7b5b323c62f792ab43";
    hash = "sha256-PtVVLzN1k6xdCSBa1pAF+DyfIuyjlelxpPhqHzzYKwk=";
  };
  filesToInstall = [ "build/${platform}/release/bl31/bl31.elf" ];
  extraMakeFlags = [ "COREBOOT=1" ];
  dontStrip = false;
  postInstall = ''
    mkdir -p $out/libexec && mv $out/bl31.elf $out/libexec/bl31.elf
  '';
  extraMeta.platforms = [ "aarch64-linux" ];
}
