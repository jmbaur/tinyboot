{ builtinCmdline ? [ ], linux, fetchpatch, configFile, lib, stdenv }:
let
  extraConfig = lib.optionalString (builtinCmdline != [ ]) ''
    CONFIG_CMDLINE=${toString builtinCmdline}
  '';
in
stdenv.mkDerivation {
  inherit (linux) pname version src buildInputs nativeBuildInputs depsBuildBuild makeFlags preInstall enableParallelBuilding;
  patches = [
    (fetchpatch {
      url = "https://lore.kernel.org/lkml/20230921064506.3420402-1-ovt@google.com/raw";
      hash = "sha256-YM4AOV4BdfWQ2GGGeVV1yJg6BoucoiK7l7ozrVmrtMM=";
    })
    ./patches/linux-tpm-probe.patch
  ];
  inherit extraConfig;
  passAsFile = [ "extraConfig" ];
  configurePhase = ''
    runHook preConfigure
    cat ${configFile} $extraConfigPath > all.config
    make ARCH=${stdenv.hostPlatform.linuxArch} KCONFIG_ALLCONFIG=1 allnoconfig
    runHook postConfigure
  '';
  buildFlags = [ "DTC_FLAGS=-@" "KBUILD_BUILD_VERSION=1-TinyBoot" ];
  installFlags = [ "INSTALL_PATH=$(out)" ] ++ lib.optionals stdenv.hostPlatform.isAarch [ "dtbs_install" "INSTALL_DTBS_PATH=$(out)/dtbs" ];
  outputs = [ "out" "dev" ];
  postInstall = ''
    mkdir -p $dev
    cp .config $dev/config
    cp vmlinux $dev/vmlinux
  '';
}
