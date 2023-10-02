{ prepend ? [ ], extraContents ? [ ], makeInitrdNG, ncurses, pkgsStatic }:
makeInitrdNG {
  compressor = "xz";
  inherit prepend;
  contents = [
    { object = "${pkgsStatic.mdevd}/bin/mdevd"; symlink = "/bin/mdevd"; }
    { object = "${ncurses}/share/terminfo/l/linux"; symlink = "/etc/terminfo/l/linux"; }
    { object = ./etc/mdev.conf; symlink = "/etc/mdev.conf"; }
    { object = ./etc/group; symlink = "/etc/group"; }
    { object = ./etc/passwd; symlink = "/etc/passwd"; }
  ] ++ extraContents;
}
