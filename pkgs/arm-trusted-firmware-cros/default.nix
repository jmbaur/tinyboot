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
    branchName = "release-R125-15853.B";
    rev = "17bef2248d4547242463e27cfe48ec96029626b4";
    hash = "sha256-4Y50B+Xa8fRTa/0R8nm5KQhv1gU9MtAxyh6l5RO5LBM=";
  };
  filesToInstall = [ "build/${platform}/release/bl31/bl31.elf" ];
  extraMakeFlags = [ "COREBOOT=1" ];
  dontStrip = false;
  postInstall = ''
    mkdir -p $out/libexec && mv $out/bl31.elf $out/libexec/bl31.elf
  '';
  extraMeta.platforms = [ "aarch64-linux" ];
}
