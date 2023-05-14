{ debug
, measuredBoot
, verifiedBoot
, tty
, extraInit
, extraInittab
, lib
, makeInitrdNG
, busybox
, buildEnv
, pkgsStatic
, writeScript
, writeText
}:
let
  initrdEnv = buildEnv {
    name = "initrd-env";
    paths = [
      (busybox.override { useMusl = true; enableStatic = true; })
      (pkgsStatic.callPackage ./tinyboot {
        buildFeatures = (lib.optional measuredBoot.enable "measured-boot") ++ (lib.optional verifiedBoot.enable "verified-boot");
        verifiedBootPublicKey = verifiedBoot.publicKey;
      })
    ];
  };
  rcS = writeScript "rcS" (''
    #!/bin/sh
    mkdir -p /dev/pts /sys /proc /tmp /mnt
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t tmpfs tmpfs /tmp
    mount -t devpts devpts /dev/pts
    echo /bin/mdev > /sys/kernel/uevent_helper
    mkdir -p /home/tinyuser
    chown -R tinyuser:tinyuser /home/tinyuser
  '' + extraInit + ''
    mdev -s
  '');
  inittab = writeText "inittab" (''
    ::sysinit:/etc/init.d/rcS
    ::ctrlaltdel:/bin/reboot
    ::shutdown:/bin/umount -ar -t ext4,vfat
    ::restart:/init
    ${tty}::once:/bin/tbootd --log-level=${if debug then "debug" else "info"}
  '' + extraInittab);
  passwd = writeText "passwd" ''
    root:x:0:0:System administrator:/root:/bin/sh
    tinyuser:x:1000:1000:TinyUser:/home/tinyuser:/bin/sh
  '';
  group = writeText "passwd" ''
    root:x:0:
    tinyuser:x:1000:
  '';
in
makeInitrdNG {
  compressor = "xz";
  contents = [
    { object = "${initrdEnv}/bin"; symlink = "/bin"; }
    { object = "${initrdEnv}/bin"; symlink = "/sbin"; }
    { object = "${initrdEnv}/bin/init"; symlink = "/init"; }
    { object = "${rcS}"; symlink = "/etc/init.d/rcS"; }
    { object = "${inittab}"; symlink = "/etc/inittab"; }
    { object = "${passwd}"; symlink = "/etc/passwd"; }
    { object = "${group}"; symlink = "/etc/group"; }
  ];
}
