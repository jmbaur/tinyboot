- Figure out why building a test disk image requires both tinyboot and
  tinyboot-client
- Fix race conditions between tinyboot's netlink events and mdevd's netlink
  events
  - we must wait for mdev to be done handling new events
- Provide a way to edit kernel cmdline
- Don't allow clippy::new_ret_no_self lints
- better bootloader interface
- make the program smarter about printing to all known outputs, not just a
  statically configured output
- don't call oneshot `mdev -s` when tinyboot is not being ran explicitly on a
  tty
- when verified boot fails, hash the boot files and ask the user explicitly for
  confirmation on booting the chosen boot option
