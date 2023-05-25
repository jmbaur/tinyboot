- Don't allow clippy::new_ret_no_self lints
- better bootloader interface
- populate `chosen` env var:
  https://www.gnu.org/software/grub/manual/grub/html_node/menuentry.html
- make the program smarter about printing to all known outputs, not just a
  statically configured output
- don't call oneshot `mdev -s` when tinyboot is not being ran explicitly on a
  tty
- don't fail to boot when verified boot fails, but make it very clear that the
  system may have been attempted to be compromised (maybe reset the TPM PCRs?)
