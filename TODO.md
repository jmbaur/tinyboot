- provide a way to edit kernel cmdline
- better UI
- respond to SIGWINCH in tbootui
- better bootloader interface
- don't call oneshot `mdev -s` when tinyboot is not being ran explicitly on a
  tty
- when verified boot fails, hash the boot files and ask the user explicitly for
  confirmation on booting the chosen boot option while showing the user the
  computed hashes
