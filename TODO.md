- make the program smarter about printing to all known outputs, not just a
  statically configured output
- don't rerun tinyboot on error, just show error to user and show option to
  reboot or poweroff
- unmount all mounted drives upon program exit
- allow for picking of boot device (currently just choosing the first device)
