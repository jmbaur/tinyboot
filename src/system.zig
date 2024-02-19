const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const os = std.os;
const system = std.os.system;
const linux = std.os.linux;

const linux_headers = @import("linux_headers");

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

const CBAUD = linux_headers.CBAUD;
const CBAUDEX = linux_headers.CBAUDEX;
const CRTSCTS = linux_headers.CRTSCTS;
const TCFLSH = linux_headers.TCFLSH;
const TCIOFLUSH = linux_headers.TCIOFLUSH;
const TCOON = linux_headers.TCOON;
const VDISCARD = linux_headers.VDISCARD;
const VEOF = linux_headers.VEOF;
const VEOL = linux_headers.VEOL;
const VEOL2 = linux_headers.VEOL2;
const VERASE = linux_headers.VERASE;
const VINTR = linux_headers.VINTR;
const VKILL = linux_headers.VKILL;
const VLNEXT = linux_headers.VLNEXT;
const VMIN = linux_headers.VMIN;
const VQUIT = linux_headers.VQUIT;
const VREPRINT = linux_headers.VREPRINT;
const VSTART = linux_headers.VSTART;
const VSTOP = linux_headers.VSTOP;
const VSUSP = linux_headers.VSUSP;
const VSWTC = linux_headers.VSWTC;
const VSWTCH = linux_headers.VSWTCH;
const VTIME = linux_headers.VTIME;
const VWERASE = linux_headers.VWERASE;

fn setBaudRate(t: *os.termios, baud: u32) void {
    // indicate that we want to set a new baud rate
    t.*.cflag &= ~@as(os.tcflag_t, CBAUD);

    // set the new baud rate
    t.*.cflag |= baud;
}

fn cfmakeraw(t: *os.termios) void {
    t.iflag &= ~(system.IGNBRK | system.BRKINT | system.PARMRK | system.ISTRIP | system.INLCR | system.IGNCR | system.ICRNL | system.IXON);
    t.lflag &= ~(system.ECHO | system.ECHONL | system.ICANON | system.ISIG | system.IEXTEN);
    t.cflag &= ~(system.CSIZE | system.PARENB);
    t.cflag |= system.CS8;
    t.cc[VMIN] = 1;
    t.cc[VTIME] = 0;
}

pub const TtyMode = enum {
    user_input,
    file_transfer_recv,
    file_transfer_send,
};

pub fn setupTty(fd: os.fd_t, mode: TtyMode) !void {
    var termios = try os.tcgetattr(fd);

    switch (mode) {
        .user_input => {
            termios.cc[VINTR] = 3; // C-c
            termios.cc[VQUIT] = 28; // C-\
            termios.cc[VERASE] = 127; // C-?
            termios.cc[VKILL] = 21; // C-u
            termios.cc[VEOF] = 4; // C-d
            termios.cc[VSTART] = 17; // C-q
            termios.cc[VSTOP] = 19; // C-s
            termios.cc[VSUSP] = 26; // C-z

            termios.cflag &= CBAUD | CBAUDEX | system.CSIZE | system.CSTOPB | system.PARENB | system.PARODD;

            termios.cflag |= system.CREAD | system.HUPCL | system.CLOCAL;

            // input modes
            termios.iflag = system.ICRNL | system.IXON | system.IXOFF;

            // output modes
            termios.oflag = system.OPOST | system.ONLCR;

            // local modes
            termios.lflag = system.ISIG | system.ICANON | system.ECHO | system.ECHOE | system.ECHOK | system.IEXTEN;

            cfmakeraw(&termios);

            setBaudRate(&termios, system.B115200);
        },
        .file_transfer_recv, .file_transfer_send => {
            termios.iflag = system.IGNBRK | system.IXOFF;
            termios.lflag &= ~(system.ECHO | system.ICANON | system.ISIG | system.IEXTEN);
            termios.oflag = 0;
            termios.cflag &= ~system.PARENB;
            termios.cflag &= ~system.CSIZE;
            termios.cflag |= system.CS8;
            termios.cflag |= CRTSCTS;
            termios.cflag |= system.CREAD | system.CLOCAL;
            termios.cc[VMIN] = if (mode == .file_transfer_recv) 0 else 1;
            termios.cc[VTIME] = 50;

            setBaudRate(&termios, system.B3000000);
        },
    }

    _ = system.ioctl(fd, TCFLSH, TCIOFLUSH);
    try os.tcsetattr(fd, os.TCSA.NOW, termios);
}

// These aren't defined in the UAPI linux headers for some odd reason.
const SYSLOG_ACTION_READ_ALL = 3;
const SYSLOG_ACTION_UNREAD = 9;

/// Read kernel logs (AKA syslog/dmesg). Caller is responsible for returned
/// slice.
pub fn kernelLogs(allocator: std.mem.Allocator) ![]const u8 {
    const bytes_available = linux.syscall3(linux.SYS.syslog, SYSLOG_ACTION_UNREAD, 0, 0);
    const buf = try allocator.alloc(u8, bytes_available);
    switch (linux.getErrno(linux.syscall3(linux.SYS.syslog, SYSLOG_ACTION_READ_ALL, @intFromPtr(buf.ptr), buf.len))) {
        linux.E.INVAL => unreachable, // we provided bad parameters
        // TODO(jared): make use of these possible outcomes
        linux.E.NOSYS => {},
        linux.E.PERM => {},
        else => {
            // We don't need to capture the bytes read since we only request
            // for the exact number of bytes available.
        },
    }

    return buf;
}
