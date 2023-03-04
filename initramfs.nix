{ tinybootLog ? "info"
, tinybootTTY ? "tty0" # default to the current foreground virtual terminal
, extraInit ? ""
, extraInittab ? ""
, kernel
, makeInitrdNG
, busybox
, buildEnv
, tinyboot
, writeScript
, writeText
, ...
}:
let
  initrdEnv = buildEnv {
    name = "initrd-env";
    paths = [
      (busybox.override { enableStatic = true; useMusl = true; })
      tinyboot
    ];
  };
  rcS = writeScript "rcS" (''
    #!/bin/sh
    mkdir -p /dev/pts /sys /proc /tmp /mnt
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t tmpfs tmpfs /tmp
    mount -t devpts devpts /dev/pts
  '' + extraInit + ''
    mdev -s
  '');
  inittab = writeText "inittab" (''
    ::sysinit:/etc/init.d/rcS
    ::ctrlaltdel:/bin/reboot
    ::shutdown:/bin/umount -ar -t ext4,vfat
    ::restart:/init
    ${tinybootTTY}::once:/bin/tinyboot --log-level=${tinybootLog}
  '' + extraInittab);
in
makeInitrdNG {
  compressor = "xz";
  contents = [
    { object = "${initrdEnv}/bin"; symlink = "/bin"; }
    { object = "${initrdEnv}/sbin"; symlink = "/sbin"; }
    { object = "${initrdEnv}/bin/busybox"; symlink = "/init"; }
    { object = "${rcS}"; symlink = "/etc/init.d/rcS"; }
    { object = "${inittab}"; symlink = "/etc/inittab"; }
  ];
}
