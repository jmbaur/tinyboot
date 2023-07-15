{ extraInit ? "", extraInittab ? "", prepend ? [ ], extraContents ? [ ], makeInitrdNG, ncurses, busybox, substituteAll }:
let
  myBusybox = (busybox.override { enableStatic = true; }).overrideAttrs (_: { stripDebugFlags = [ "--strip-all" ]; });
  rcS = substituteAll {
    name = "rcS";
    src = ./etc/rcS.in;
    isExecutable = true;
    inherit extraInit;
  };
  inittab = substituteAll {
    name = "inittab";
    src = ./etc/inittab.in;
    extraInittab = extraInittab;
  };
in
makeInitrdNG {
  compressor = "xz";
  inherit prepend;
  contents = [
    { object = "${myBusybox}/bin"; symlink = "/bin"; }
    { object = "${myBusybox}/bin/busybox"; symlink = "/init"; }
    { object = "${ncurses}/share/terminfo/l/linux"; symlink = "/etc/terminfo/l/linux"; }
    { object = inittab; symlink = "/etc/inittab"; }
    { object = rcS; symlink = "/etc/init.d/rcS"; }
  ] ++ extraContents;
}
