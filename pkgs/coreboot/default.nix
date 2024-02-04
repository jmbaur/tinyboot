{ board, configFile, fetchgit, stdenvNoCC, pkgsBuildBuild, python3, pkg-config, openssl }:
let
  architectures = { i386 = "i386"; x86_64 = "i386"; arm64 = "aarch64"; arm = "arm"; riscv = "riscv"; powerpc = "ppc64"; };
  toolchain = pkgsBuildBuild.coreboot-toolchain.${architectures.${stdenvNoCC.hostPlatform.linuxArch}}.override {
    withAda = stdenvNoCC.hostPlatform.isx86_64;
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "coreboot-${board}";
  version = "4.21";
  src = fetchgit {
    url = "https://review.coreboot.org/coreboot";
    rev = finalAttrs.version;
    hash = "sha256-bQVD1CglaONcQlivXfTZd963ADCd7cSJzQ0zmKdT2jY=";
    fetchSubmodules = true;
  };
  patches = [
    ./0001-Add-Kconfig-VBOOT_SIGN-option.patch
    ./0002-Fix-build-for-brya.patch
    ./0003-Allow-for-fitImage-use-on-mt8183-and-mt8192.patch
  ];
  depsBuildBuild = [ pkgsBuildBuild.stdenv.cc pkg-config openssl ];
  nativeBuildInputs = [ python3 ];
  buildInputs = [ ];
  enableParallelBuilding = true;
  postPatch = ''
    patchShebangs util 3rdparty/vboot/scripts
  '';
  inherit configFile;
  passAsFile = [ "configFile" ];
  configurePhase = ''
    runHook preConfigure
    cat $configFilePath > .config
    make olddefconfig
    runHook postConfigure
  '';
  makeFlags = [ "XGCCPATH=${toolchain}/bin/" "KERNELVERSION=${finalAttrs.version}" "UPDATED_SUBMODULES=1" ];
  outputs = [ "out" "dev" ];
  installPhase = ''
    runHook preInstall
    install -D --target-directory=$out build/coreboot.rom
    install -D --target-directory=$dev .config
    runHook postInstall
  '';
})
