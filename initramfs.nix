{ tinybootLog ? "trace"
, tinybootTTY ? "tty1"
, shellTTY ? "tty2"
, extraInittab ? ""
, extraInit ? ""
, makeInitrdNG
, pkgsStatic
, buildEnv
, tinyboot
, writeScript
, writeText
, ...
}:
let
  initrdEnv = buildEnv { name = "initrd-env"; paths = [ pkgsStatic.busybox tinyboot ]; };
  rcS = writeScript "rcS" ''
    #!/bin/sh
    mkdir -p /dev/pts /sys /proc /tmp /mnt
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t tmpfs tmpfs /tmp
    mount -t devpts devpts /dev/pts
    ${extraInit}
    mdev -s
  '';
  inittab = writeText "inittab" ''
    ::sysinit:/etc/init.d/rcS
    ::ctrlaltdel:/sbin/reboot
    ::shutdown:/bin/umount -a -r
    ::restart:/init
    ${tinybootTTY}::respawn:/bin/tinyboot tinyboot.log=${tinybootLog}
    ${shellTTY}::askfirst:/bin/sh
    ${extraInittab}
  '';
in
makeInitrdNG {
  compressor = "xz";
  contents = [
    { object = "${initrdEnv}/bin"; symlink = "/bin"; }
    { object = "${initrdEnv}/sbin"; symlink = "/sbin"; }
    { object = "${initrdEnv}/linuxrc"; symlink = "/init"; }
    { object = "${rcS}"; symlink = "/etc/init.d/rcS"; }
    { object = "${inittab}"; symlink = "/etc/inittab"; }
  ];
}
