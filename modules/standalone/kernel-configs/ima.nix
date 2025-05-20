{ lib, pkgs, ... }:
{
  # As of 2025-03-12, the linux kernel only allows for
  # kexec_file_load and ima/kexec integration on 64-bit
  # platforms.
  linux.kconfig = lib.mkIf (pkgs.stdenv.hostPlatform.is64bit) (
    with lib.kernel;
    {
      IMA = yes;
      IMA_APPRAISE = yes;
      IMA_APPRAISE_MODSIG = yes;
      IMA_DEFAULT_HASH_SHA256 = yes;
      IMA_KEXEC = yes;
      IMA_MEASURE_ASYMMETRIC_KEYS = yes;
      KEXEC_FILE = yes;
      MODULE_SIG_FORMAT = yes;
      INTEGRITY = yes;
      INTEGRITY_ASYMMETRIC_KEYS = yes;
      INTEGRITY_SIGNATURE = yes;
      INTEGRITY_TRUSTED_KEYRING = unset;
    }
  );
}
