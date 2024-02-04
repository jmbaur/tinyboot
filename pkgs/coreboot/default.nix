{ board, configFile, lib, fetchgit, stdenvNoCC, pkgsBuildBuild, python3, pkg-config, openssl }:
let
  architectures = { i386 = "i386"; x86_64 = "i386"; arm64 = "aarch64"; arm = "arm"; riscv = "riscv"; powerpc = "ppc64"; };
  toolchain = pkgsBuildBuild.coreboot-toolchain.${architectures.${stdenvNoCC.hostPlatform.linuxArch}}.override {
    withAda = stdenvNoCC.hostPlatform.isx86_64;
  };
  importJsonSource = source: { inherit (lib.importJSON source) url rev hash fetchLFS fetchSubmodules deepClone leaveDotGit; };
  installSubmodule = source: dest: ''rm -r ${dest} && ln -sf ${fetchgit (importJsonSource source)} ${dest}'';
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "coreboot-${board}";
  version = "4.22.01";
  src = fetchgit {
    url = "https://review.coreboot.org/coreboot";
    rev = finalAttrs.version;
    fetchSubmodules = true;
    hash = "sha256-wgLkcq7Iexo9GcRrgkdc9kD8oW5xC4to1jXrmNx1f1g=";
  };
  patches = [
    ./0001-Add-Kconfig-VBOOT_SIGN-option.patch
    ./0002-Fix-build-for-brya.patch
    ./0003-Allow-for-fitImage-use-on-mt8183-and-mt8192.patch
  ];
  depsBuildBuild = [ pkgsBuildBuild.stdenv.cc ];
  nativeBuildInputs = [ python3 pkg-config openssl ];
  buildInputs = [ ];
  enableParallelBuilding = true;
  # nixpkgs fetchgit fetcher does not fetch a submodule if the repo sets
  # "update=none" on the submodule, so we must fetch them ourselves
  postPatch = ''
    patchShebangs util 3rdparty/vboot/scripts
    ${installSubmodule ./amd_blobs.json "3rdparty/amd_blobs"}
    ${installSubmodule ./blobs.json "3rdparty/blobs"}
    ${installSubmodule ./cmocka.json "3rdparty/cmocka"}
    ${installSubmodule ./fsp.json "3rdparty/fsp"}
    ${installSubmodule ./intel_microcode.json "3rdparty/intel-microcode"}
    ${installSubmodule ./qc_blobs.json "3rdparty/qc_blobs"}
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
  installPhase = ''
    runHook preInstall
    install -Dm0644 --target-directory=$out build/coreboot.rom .config
    runHook postInstall
  '';
})
