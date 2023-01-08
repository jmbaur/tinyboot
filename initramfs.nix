{ makeInitrdNG, buildEnv, pkgsStatic, tinyboot, ... }:
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
    { object = "${./inittab/inittab}"; symlink = "/etc/inittab"; }
    { object = "${./inittab/rcS}"; symlink = "/etc/init.d/rcS"; }
  ];
}
