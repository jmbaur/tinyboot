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
        measuredBoot = measuredBoot.enable;
        verifiedBoot = verifiedBoot.enable;
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
    mdev -s
    mkdir -p /home/tinyuser
    chown -R tinyuser:tinyuser /home/tinyuser
  '' + extraInit);
  inittab = writeText "inittab" (''
    ::sysinit:/etc/init.d/rcS
    ::ctrlaltdel:/bin/reboot
    ::shutdown:/bin/umount -ar -t ext4,vfat
    ::restart:/init
    ::respawn:/bin/mdev -df
    ${tty}::respawn:/bin/tbootd --log-level=${if debug then "debug" else "info"}
    ${tty}::respawn:/bin/tbootui
  '' + extraInittab);
  passwd = writeText "passwd" ''
    root:x:0:0:System administrator:/root:/bin/sh
    tinyuser:x:1000:1000:TinyUser:/home/tinyuser:/bin/sh
  '';
  group = writeText "passwd" ''
    root:x:0:
    tinyuser:x:1000:
  '';
  mdevConf = writeText "mdev.conf" ''
    ([vs]d[a-z])             root:root  660  >disk/%1/0
    ([vs]d[a-z])([0-9]+)     root:root  660  >disk/%1/%2
    nvme([0-9]+)             root:root  660  >disk/nvme/%1/0
    nvme([0-9]+)p([0-9]+)    root:root  660  >disk/nvme/%1/%2
    mmcblk([0-9]+)           root:root  660  >disk/mmc/%1/0
    mmcblk([0-9]+)p([0-9]+)  root:root  660  >disk/mmc/%1/%2
    (tun|tap)                root:root  660  >net/%1
  '';
in
makeInitrdNG {
  compressor = "xz";
  contents = [
    { object = "${initrdEnv}/bin"; symlink = "/bin"; }
    { object = "${initrdEnv}/bin"; symlink = "/sbin"; }
    { object = "${initrdEnv}/bin/init"; symlink = "/init"; }
    { object = "${group}"; symlink = "/etc/group"; }
    { object = "${inittab}"; symlink = "/etc/inittab"; }
    { object = "${mdevConf}"; symlink = "/etc/mdev.conf"; }
    { object = "${passwd}"; symlink = "/etc/passwd"; }
    { object = "${rcS}"; symlink = "/etc/init.d/rcS"; }
  ];
}
