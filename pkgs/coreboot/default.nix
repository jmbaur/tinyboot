{
  board,
  fetchgit,
  kconfig ? "",
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
  version = "24.12";
  src =
    (fetchgit {
      url = "https://github.com/coreboot/coreboot";
      rev = finalAttrs.version;
      hash = "sha256-mdxYxE3JiHFDaftNVckeQTVOlF8sWccm74MrpgWtXb4=";
      fetchSubmodules = true;
    }).overrideAttrs
      (_: {
        # Fetch the remaining submodules not fetched by the initial submodule
        # fetch, since coreboot has `update = none` set on some submodules.
        # See https://github.com/nixos/nixpkgs/blob/4c62505847d88f16df11eff3c81bf9a453a4979e/pkgs/build-support/fetchgit/nix-prefetch-git#L328
        NIX_PREFETCH_GIT_CHECKOUT_HOOK = ''clean_git -C "$dir" submodule update --init --recursive --checkout -j ''${NIX_BUILD_CORES:-1} --progress'';
      });
  patches = [
    ./0001-Add-Kconfig-VBOOT_SIGN-option.patch
    ./0002-Fix-build-for-brya.patch
    ./0003-Allow-for-fitImage-use-on-mt8183-and-mt8192.patch
  ];
  strictDeps = true;
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
    make -j$NIX_BUILD_CORES olddefconfig
    runHook postConfigure
  '';
  makeFlags = [
    "BUILD_TIMELESS=1"
    "KERNELVERSION=${finalAttrs.version}"
    "UPDATED_SUBMODULES=1"
    "XGCCPATH=${toolchain}/bin/"
  ];
  installPhase = ''
    runHook preInstall
    install -Dm0644 --target-directory=$out build/coreboot.rom .config
    runHook postInstall
  '';
})
