{ debug, ttys, nameservers, measuredBoot, verifiedBoot, extraInit, extraInittab, lib, buildEnv, makeInitrdNG, ncurses, busybox, tinyboot, writeScript, writeText }:
let
  myBusybox = (busybox.override { enableStatic = true; }).overrideAttrs (_: { stripDebugFlags = [ "--strip-all" ]; });
  myTinyboot = tinyboot.override {
    measuredBoot = measuredBoot.enable;
    verifiedBoot = verifiedBoot.enable;
    verifiedBootPublicKey = verifiedBoot.publicKey;
  };
  bin = buildEnv { name = "tinyboot-initrd-bin"; pathsToLink = [ "/bin" ]; paths = [ myBusybox myTinyboot ]; };
  staticResolvConf = writeText "resolv.conf.static" (lib.concatLines (map (n: "nameserver ${n}") nameservers));
  rcS = writeScript "rcS" (''
    #!/bin/sh
    mkdir -p /dev/pts /sys /proc /tmp /mnt
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t tmpfs tmpfs /tmp
    mount -t devpts devpts /dev/pts
    ln -sf /proc/self/fd/0 /dev/stdin
    ln -sf /proc/self/fd/1 /dev/stdout
    ln -sf /proc/self/fd/2 /dev/stderr
    mdev -s
    mkdir -p /home/tinyuser /tmp/tinyboot
    chown -R tinyuser:tinygroup /home/tinyuser /tmp/tinyboot
    cat /etc/resolv.conf.static >/etc/resolv.conf
  '' + extraInit);
  inittab = writeText "inittab" (''
    ::sysinit:/etc/init.d/rcS
    ::ctrlaltdel:/bin/reboot
    ::shutdown:/bin/umount -ar -t ext4,vfat
    ::restart:/init
    ::respawn:/bin/mdev -df
    ::respawn:/bin/tbootd --log-level=${if debug then "debug" else "info"}
  '' + (lib.concatLines (map (tty: "${tty}::respawn:/bin/tbootui") ttys)) + extraInittab);
  passwd = writeText "passwd" ''
    root:x:0:0:System administrator:/root:/bin/sh
    tinyuser:x:1000:1000:TinyUser:/home/tinyuser:/bin/sh
  '';
  group = writeText "group" ''
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
    { object = "${bin}/bin"; symlink = "/bin"; }
    { object = "${myBusybox}/bin/busybox"; symlink = "/init"; }
    { object = "${ncurses}/share/terminfo/l/linux"; symlink = "/etc/terminfo/l/linux"; }
    { object = "${group}"; symlink = "/etc/group"; }
    { object = "${inittab}"; symlink = "/etc/inittab"; }
    { object = "${mdevConf}"; symlink = "/etc/mdev.conf"; }
    { object = "${passwd}"; symlink = "/etc/passwd"; }
    { object = "${rcS}"; symlink = "/etc/init.d/rcS"; }
    { object = "${staticResolvConf}"; symlink = "/etc/resolv.conf.static"; }
  ];
}
