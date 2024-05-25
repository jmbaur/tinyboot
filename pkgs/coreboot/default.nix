{ corebootSrc, version }:
{
  board,
  fetchgit,
  kconfig ? "",
  lib,
  nss,
  openssl,
  pkg-config,
  pkgsBuildBuild,
  python3,
  stdenvNoCC,
}:
let
  toolchain =
    pkgsBuildBuild.coreboot-toolchain.${
      {
        i386 = "i386";
        x86_64 = "i386";
        arm64 = "aarch64";
        arm = "arm";
        riscv = "riscv";
        powerpc = "ppc64";
      }
      .${stdenvNoCC.hostPlatform.linuxArch}
    }.override
      { withAda = stdenvNoCC.hostPlatform.isx86_64; };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "coreboot-${board}";
  inherit version;
  src = corebootSrc;
  patches = [
    ./0001-Add-Kconfig-VBOOT_SIGN-option.patch
    ./0002-Fix-build-for-brya.patch
    ./0003-Allow-for-fitImage-use-on-mt8183-and-mt8192.patch
  ];
  depsBuildBuild = [
    pkgsBuildBuild.stdenv.cc
    pkg-config
    openssl
    nss
    python3
  ];
  enableParallelBuilding = true;
  inherit kconfig;
  passAsFile = [ "kconfig" ];
  postPatch = ''
    patchShebangs util 3rdparty/vboot/scripts
  '';
  configurePhase = ''
    runHook preConfigure
    cat $kconfigPath > .config
    make olddefconfig
    runHook postConfigure
  '';
  makeFlags = [
    "XGCCPATH=${toolchain}/bin/"
    "KERNELVERSION=${finalAttrs.version}"
    "UPDATED_SUBMODULES=1"
  ];
  installPhase = ''
    runHook preInstall
    install -Dm0644 --target-directory=$out build/coreboot.rom .config
    runHook postInstall
  '';
})
