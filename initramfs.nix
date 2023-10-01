{ prepend ? [ ], extraContents ? [ ], makeInitrdNG, ncurses, pkgsStatic }:
makeInitrdNG {
  compressor = "xz";
  inherit prepend;
  contents = [
    { object = "${pkgsStatic.mdevd}/bin/mdevd"; symlink = "/bin/mdevd"; }
    { object = "${ncurses}/share/terminfo/l/linux"; symlink = "/etc/terminfo/l/linux"; }
  ] ++ extraContents;
}
