{ makeInitrdNG, pkgsStatic, buildEnv, tinyboot, ... }:
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
    { object = ./etc; symlink = "/etc"; }
  ];
}
