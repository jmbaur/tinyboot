{ extraInittab ? "", extraContents ? [ ], makeInitrdNG, ncurses, busybox, substituteAll }:
let
  myBusybox = (busybox.override { enableStatic = true; }).overrideAttrs (_: { stripDebugFlags = [ "--strip-all" ]; });
  rcS = substituteAll {
    name = "update-rcS";
    src = ./etc/rcS.in;
    isExecutable = true;
    extraInit = "";
  };
  inittab = substituteAll {
    name = "update-inittab";
    src = ./etc/inittab.in;
    inherit extraInittab;
  };
in
makeInitrdNG {
  compressor = "xz";
  contents = [
    { object = "${myBusybox}/bin"; symlink = "/bin"; }
    { object = "${myBusybox}/bin/busybox"; symlink = "/init"; }
    { object = "${ncurses}/share/terminfo/l/linux"; symlink = "/etc/terminfo/l/linux"; }
    { object = inittab; symlink = "/etc/inittab"; }
    { object = rcS; symlink = "/etc/init.d/rcS"; }
  ] ++ extraContents;
}
