- move client connection to outside of disk boot phase (a client can be
  connected to the server regardless of where we are trying to boot from, e.g.
  the network)
- respond to kobject uevent Add and Remove events, don't just assume it is
  always add
- better bootloader interface
- don't call oneshot `mdev -s` when tinyboot is not being ran explicitly on a
  tty
- when verified boot fails, hash the boot files and ask the user explicitly for
  confirmation on booting the chosen boot option while showing the user the
  computed hashes
- use IMA policy for TPM measurements and kexec'ing?
