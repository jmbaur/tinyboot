{ fetchurl }:
let
  vbt = fetchurl {
    url = "https://github.com/intel/FSP/raw/d85493d0605921f46afab3445be01da90f0a8062/TigerLakeFspBinPkg/Client/SampleCode/Vbt/Vbt.bin";
    sha256 = "sha256-IDp05CcwaTOucvXF8MmsTg1qyYKXU3E5xw2ZUisUXt4=";
  };
in
''
  CONFIG_INTEL_GMA_VBT_FILE="${vbt}"
''
