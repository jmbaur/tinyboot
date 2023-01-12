{ lib, makeInitrdNG, pkgsStatic, buildEnv, tinyboot, substituteAll, tinybootTTY ? "tty1", shellTTY ? "tty2", ... }:
let
  initrdEnv = buildEnv {
    name = "initrd-env";
    paths = [ pkgsStatic.busybox tinyboot ];
  };
in
makeInitrdNG {
  compressor = "xz";
  contents = [
    { object = "${initrdEnv}/bin"; symlink = "/bin"; }
    { object = "${initrdEnv}/sbin"; symlink = "/sbin"; }
    { object = "${initrdEnv}/linuxrc"; symlink = "/init"; }
    { object = ./etc/init.d/rcS; symlink = "/etc/init.d/rcS"; }
    {
      object = substituteAll { src = ./etc/inittab; inherit tinybootTTY shellTTY; };
      symlink = "/etc/inittab";
    }
  ];
}
