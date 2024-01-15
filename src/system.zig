const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const os = std.os;
const system = std.os.system;
const linux = std.os.linux;

const MountError = error{
    Todo,
};

fn mountPseudoFs(
    path: [*:0]const u8,
    fstype: [*:0]const u8,
    flags: u32,
) MountError!void {
    const rc = linux.mount("", path, fstype, flags, 0);

    switch (linux.getErrno(rc)) {
        .SUCCESS => {},
        // TODO(jared): parse errno
        else => return MountError.Todo,
    }
}

/// Does initial system setup and mounts basic psuedo-filesystems.
pub fn setupSystem() !void {
    try fs.makeDirAbsolute("/proc");
    try mountPseudoFs("/proc", "proc", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC);

    try fs.makeDirAbsolute("/sys");
    try mountPseudoFs("/sys", "sysfs", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC | linux.MS.RELATIME);
    try mountPseudoFs("/sys/kernel/security", "securityfs", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC | linux.MS.RELATIME);

    // we use CONFIG_DEVTMPFS, so we don't need to create /dev
    try mountPseudoFs("/dev", "devtmpfs", linux.MS.SILENT | linux.MS.NOSUID | linux.MS.NOEXEC);

    try fs.makeDirAbsolute("/dev/pts");
    try mountPseudoFs("/dev/pts", "devpts", linux.MS.NOSUID | linux.MS.NOEXEC | linux.MS.RELATIME);

    try fs.makeDirAbsolute("/run");
    try mountPseudoFs("/run", "tmpfs", linux.MS.NOSUID | linux.MS.NODEV);

    try fs.makeDirAbsolute("/mnt");

    try os.symlink("/proc/self/fd/0", "/dev/stdin");
    try os.symlink("/proc/self/fd/1", "/dev/stdout");
    try os.symlink("/proc/self/fd/2", "/dev/stderr");
}

// Not defined in zig standard library
const VINTR = 0;
const VQUIT = 1;
const VERASE = 2;
const VKILL = 3;
const VMIN = 4;
const VTIME = 5;
const VEOL2 = 6;
const VSWTC = 7;
const VSWTCH = 7;
const VSTART = 8;
const VSTOP = 9;
const VSUSP = 10;
const VREPRINT = 12;
const VDISCARD = 13;
const VWERASE = 14;
const VLNEXT = 15;
const VEOF = 16;
const VEOL = 17;
const CBAUD = switch (builtin.target.cpu.arch) {
    .powerpc, .powerpc64 => 0o377,
    else => 0o10017,
};
const CBAUDEX = switch (builtin.target.cpu.arch) {
    .powerpc, .powerpc64 => 0o00020,
    else => 0o10000,
};
const CRTSCTS = 0o20000000000;

fn setBaudRate(t: *os.termios, baud: u32) void {
    // indicate that we want to set a new baud rate
    t.*.cflag &= ~@as(os.tcflag_t, CBAUD);

    // set the new baud rate
    t.*.cflag |= baud;
}

fn cfmakeraw(t: *os.termios) void {
    t.iflag &= ~(system.IGNBRK | system.BRKINT | system.PARMRK | system.ISTRIP | system.INLCR | system.IGNCR | system.ICRNL | system.IXON);
    t.oflag &= ~system.OPOST;
    t.lflag &= ~(system.ECHO | system.ECHONL | system.ICANON | system.ISIG | system.IEXTEN);
    t.cflag &= ~(system.CSIZE | system.PARENB);
    t.cflag |= system.CS8;
    t.cc[VMIN] = 1;
    t.cc[VTIME] = 0;
}

pub fn setupTty(fd: os.fd_t) !void {
    var termios = try os.tcgetattr(fd);

    termios.cc[VINTR] = 3; // C-c
    termios.cc[VQUIT] = 28; // C-\
    termios.cc[VERASE] = 127; // C-?
    termios.cc[VKILL] = 21; // C-u
    termios.cc[VEOF] = 4; // C-d
    termios.cc[VSTART] = 17; // C-q
    termios.cc[VSTOP] = 19; // C-s
    termios.cc[VSUSP] = 26; // C-z

    termios.cflag &= CBAUD | CBAUDEX | os.system.CSIZE | os.system.CSTOPB | os.system.PARENB | os.system.PARODD | CRTSCTS;

    termios.cflag |= system.CREAD | system.HUPCL | system.CLOCAL;

    // input modes
    termios.iflag = system.ICRNL | system.IXON | system.IXOFF;

    // output modes
    termios.oflag = system.OPOST | system.ONLCR;

    // local modes
    termios.lflag = system.ISIG | system.ICANON | system.ECHO | system.ECHOE | system.ECHOK | system.IEXTEN;

    setBaudRate(&termios, os.system.B115200);

    cfmakeraw(&termios);

    try os.tcsetattr(fd, os.TCSA.NOW, termios);
}
