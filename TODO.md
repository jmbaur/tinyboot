- provide a way to edit kernel cmdline
- don't allow clippy::new_ret_no_self lints
- way better UI
- better bootloader interface
- make the program smarter about printing to all known outputs, not just a
  statically configured output
- don't call oneshot `mdev -s` when tinyboot is not being ran explicitly on a
  tty
- when verified boot fails, hash the boot files and ask the user explicitly for
  confirmation on booting the chosen boot option while showing the user the
  computed hashes
