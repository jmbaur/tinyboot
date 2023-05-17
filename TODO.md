- make the program smarter about printing to all known outputs, not just a
  statically configured output
- allow for picking of boot device (currently just choosing the first device)
- don't call oneshot `mdev -s` when tinyboot is not being ran explicitly on a
  tty
- don't fail to boot when verified boot fails, but make it very clear that the
  system may have been attempted to be compromised (maybe reset the TPM PCRs?)
