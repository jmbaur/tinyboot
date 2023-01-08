{ lib, makeInitrdNG, buildEnv, pkgsStatic, busybox, tinyboot, ... }:
let
  initrdEnv = buildEnv {
    name = "initrd-env";
    paths = [ pkgsStatic.busybox tinyboot ];
  };
  initrd = makeInitrdNG {
    compressor = "xz";
    contents = [
      { object = "${initrdEnv}/bin"; symlink = "/bin"; }
      { object = "${initrdEnv}/sbin"; symlink = "/sbin"; }
      { object = "${initrdEnv}/linuxrc"; symlink = "/init"; }
      { object = "${./inittab/inittab}"; symlink = "/etc/inittab"; }
      { object = "${./inittab/rcS}"; symlink = "/etc/init.d/rcS"; }
    ];
  };
in
initrd
