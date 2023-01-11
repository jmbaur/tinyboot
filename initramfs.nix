{ makeInitrdNG, pkgsStatic, buildEnv, substituteAll, linuxPackages_latest, tinyboot, tty ? "tty0", ... }:
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
      object = substituteAll { src = ./etc/inittab; inherit tty; };
      symlink = "/etc/inittab";
    }
  ];
}
