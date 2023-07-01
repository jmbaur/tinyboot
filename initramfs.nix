{ debug ? false, imaAppraise ? false, ttys ? [ "tty0" ], nameservers ? [ ], extraInit ? "", extraInittab ? "", prepend ? [ ], extraContents ? [ ], lib, buildEnv, makeInitrdNG, ncurses, busybox, tinyboot, writeText, substituteAll }:
let
  myBusybox = (busybox.override { enableStatic = true; }).overrideAttrs (_: { stripDebugFlags = [ "--strip-all" ]; });
  bin = buildEnv { name = "tinyboot-initrd-bin"; pathsToLink = [ "/bin" ]; paths = [ myBusybox tinyboot ]; };
  staticResolvConf = writeText "resolv.conf.static" (lib.concatLines (map (n: "nameserver ${n}") nameservers));
  rcS = substituteAll {
    name = "rcS";
    src = ./etc/rcS.in;
    isExecutable = true;
    inherit extraInit;
  };
  inittab = substituteAll {
    name = "inittab";
    src = ./etc/inittab.in;
    logLevel = if debug then "debug" else "info";
    extraInittab = (lib.concatLines (map (tty: "${tty}::respawn:/bin/tbootui") ttys)) + extraInittab;
  };
  imaPolicy = substituteAll {
    name = "ima_policy.conf";
    src = ./etc/ima_policy.conf.in;
    extraPolicy = lib.optionalString imaAppraise ''
      appraise func=KEXEC_KERNEL_CHECK appraise_type=imasig|modsig
      appraise func=KEXEC_INITRAMFS_CHECK appraise_type=imasig|modsig
    '';
  };
in
makeInitrdNG {
  compressor = "xz";
  inherit prepend;
  contents = [
    { object = "${bin}/bin"; symlink = "/bin"; }
    { object = "${myBusybox}/bin/busybox"; symlink = "/init"; }
    { object = "${ncurses}/share/terminfo/l/linux"; symlink = "/etc/terminfo/l/linux"; }
    { object = inittab; symlink = "/etc/inittab"; }
    { object = rcS; symlink = "/etc/init.d/rcS"; }
    { object = staticResolvConf; symlink = "/etc/resolv.conf.static"; }
    { object = ./etc/group; symlink = "/etc/group"; }
    { object = ./etc/mdev.conf; symlink = "/etc/mdev.conf"; }
    { object = ./etc/passwd; symlink = "/etc/passwd"; }
    { object = imaPolicy; symlink = "/etc/ima/policy.conf"; }
  ] ++ extraContents;
}
