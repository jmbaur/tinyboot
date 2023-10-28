{ prepend ? [ ], extraContents ? [ ], writeText, makeInitrdNG, ncurses, pkgsStatic, tinyboot }:
let
  # these files are only needed by mdevd
  etcPasswd = writeText "tboot-etc-passwd.txt" ''
    root:x:0:0:root:/root:/bin/nologin
  '';
  etcGroup = writeText "tboot-etc-group.txt" ''
    root:x:0:
  '';
in
makeInitrdNG {
  compressor = "xz";
  inherit prepend;
  contents = [
    { object = "${pkgsStatic.mdevd}/bin/mdevd"; symlink = "/bin/mdevd"; }
    { object = "${ncurses}/share/terminfo/l/linux"; symlink = "/etc/terminfo/l/linux"; }
    { object = etcPasswd; symlink = "/etc/passwd"; }
    { object = etcGroup; symlink = "/etc/group"; }
    { object = "${tinyboot}/bin/nologin"; symlink = "/bin/nologin"; }
  ] ++ extraContents;
}

