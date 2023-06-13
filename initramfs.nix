{ debug
, ttys
, measuredBoot
, verifiedBoot
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
  myBusybox = (busybox.override {
    useMusl = true;
    enableStatic = true;
    enableMinimal = true;
    extraConfig = lib.concatLines (map (lib.replaceStrings [ "=" ] [ " " ])
      (lib.filter (lib.hasPrefix "CONFIG") (lib.splitString "\n" (builtins.readFile ./busybox.config))));
  });
  tinyboot = pkgsStatic.tinyboot.override {
    measuredBoot = measuredBoot.enable;
    verifiedBoot = verifiedBoot.enable;
    verifiedBootPublicKey = verifiedBoot.publicKey;
  };
  rcS = writeScript "rcS" (''
    #!/bin/sh
    /bin/busybox mkdir -p /dev/pts /sys /proc /tmp /mnt
    /bin/busybox mount -t proc proc /proc
    /bin/busybox mount -t sysfs sysfs /sys
    /bin/busybox mount -t tmpfs tmpfs /tmp
    /bin/busybox mount -t devpts devpts /dev/pts
    /bin/busybox ln -sf /proc/self/fd/0 /dev/stdin
    /bin/busybox ln -sf /proc/self/fd/1 /dev/stdout
    /bin/busybox ln -sf /proc/self/fd/2 /dev/stderr
    /bin/busybox mdev -s
    /bin/busybox mkdir -p /home/tinyuser /tmp/tinyboot
    /bin/busybox chown -R tinyuser:tinygroup /home/tinyuser /tmp/tinyboot
  '' + extraInit);
  inittab = writeText "inittab" (''
    ::sysinit:/etc/init.d/rcS
    ::ctrlaltdel:/bin/busybox reboot
    ::shutdown:/bin/busybox umount -ar -t ext4,vfat
    ::restart:/init
    ::respawn:/bin/busybox mdev -df
    ::respawn:/bin/tbootd --log-level=${if debug then "debug" else "info"}
  '' + (lib.concatLines (map (tty: "${tty}::respawn:/bin/tbootui") ttys)) + extraInittab);
  passwd = writeText "passwd" ''
    root:x:0:0:System administrator:/root:/bin/sh
    tinyuser:x:1000:1000:TinyUser:/home/tinyuser:/bin/sh
  '';
  group = writeText "passwd" ''
    root:x:0:
    tinygroup:x:1000:
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
    { object = "${tinyboot}/bin/tbootui"; symlink = "/bin/tbootui"; }
    { object = "${tinyboot}/bin/tbootd"; symlink = "/bin/tbootd"; }
    { object = "${tinyboot}/bin/tbootctl"; symlink = "/bin/tbootctl"; }
    { object = "${myBusybox}/bin/busybox"; symlink = "/bin/busybox"; }
    { object = "${myBusybox}/bin/busybox"; symlink = "/bin/sh"; }
    { object = "${myBusybox}/bin/busybox"; symlink = "/init"; }
    { object = "${pkgsStatic.ncurses}/share/terminfo/l/linux"; symlink = "/etc/terminfo/l/linux"; }
    { object = "${group}"; symlink = "/etc/group"; }
    { object = "${inittab}"; symlink = "/etc/inittab"; }
    { object = "${mdevConf}"; symlink = "/etc/mdev.conf"; }
    { object = "${passwd}"; symlink = "/etc/passwd"; }
    { object = "${rcS}"; symlink = "/etc/init.d/rcS"; }
  ];
}
