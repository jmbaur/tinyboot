const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const os = std.os;
const posix = std.posix;
const system = std.posix.system;
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

    switch (posix.errno(rc)) {
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
    try mountPseudoFs("/sys/kernel/debug", "debugfs", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC | linux.MS.RELATIME);

    // we use CONFIG_DEVTMPFS, so we don't need to create /dev
    try mountPseudoFs("/dev", "devtmpfs", linux.MS.SILENT | linux.MS.NOSUID | linux.MS.NOEXEC);

    try fs.makeDirAbsolute("/run");
    try mountPseudoFs("/run", "tmpfs", linux.MS.NOSUID | linux.MS.NODEV);

    try fs.makeDirAbsolute("/mnt");

    try fs.symLinkAbsolute("/proc/self/fd/0", "/dev/stdin", .{});
    try fs.symLinkAbsolute("/proc/self/fd/1", "/dev/stdout", .{});
    try fs.symLinkAbsolute("/proc/self/fd/2", "/dev/stderr", .{});
}

const TCFLSH = linux_headers.TCFLSH;
const TCIOFLUSH = linux_headers.TCIOFLUSH;
const TCOON = linux_headers.TCOON;
const TCXONC = linux_headers.TCXONC;
const VEOF = linux_headers.VEOF;
const VERASE = linux_headers.VERASE;
const VINTR = linux_headers.VINTR;
const VKILL = linux_headers.VKILL;
const VMIN = linux_headers.VMIN;
const VQUIT = linux_headers.VQUIT;
const VSTART = linux_headers.VSTART;
const VSTOP = linux_headers.VSTOP;
const VSUSP = linux_headers.VSUSP;
const VTIME = linux_headers.VTIME;

fn setBaudRate(t: *posix.termios, speed: posix.speed_t) void {
    // indicate that we want to set a new baud rate
    t.*.ispeed = speed;
    t.*.ospeed = speed;
}

fn cfmakeraw(t: *posix.termios) void {
    t.iflag.IGNBRK = false;
    t.iflag.BRKINT = false;
    t.iflag.PARMRK = false;
    t.iflag.INLCR = false;
    t.iflag.IGNCR = false;
    t.iflag.IXON = false;

    t.lflag.ECHO = false;
    t.lflag.ECHONL = false;
    t.lflag.ICANON = false;
    t.lflag.ISIG = false;
    t.lflag.IEXTEN = false;

    t.cflag.CSIZE = .CS8;
    t.cflag.PARENB = false;
    t.cc[VMIN] = 1;
    t.cc[VTIME] = 0;
}

pub const TtyMode = enum {
    user_input,
    file_transfer_recv,
    file_transfer_send,
};

pub fn setupTty(fd: posix.fd_t, mode: TtyMode) !void {
    var termios = try posix.tcgetattr(fd);

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

            termios.cflag.CSIZE = .CS8;
            termios.cflag.CSTOPB = true;
            termios.cflag.PARENB = true;
            termios.cflag.PARODD = true;
            termios.cflag.CREAD = true;
            termios.cflag.HUPCL = true;
            termios.cflag.CLOCAL = true;

            // input modes
            termios.iflag.ICRNL = true;
            termios.iflag.IXON = true;
            termios.iflag.IXOFF = true;

            // output modes
            termios.oflag.OPOST = true;
            termios.oflag.ONLCR = true;

            // local modes
            termios.lflag.ISIG = true;
            termios.lflag.ICANON = true;
            termios.lflag.ECHO = true;
            termios.lflag.ECHOE = true;
            termios.lflag.ECHOK = true;
            termios.lflag.IEXTEN = true;

            cfmakeraw(&termios);

            setBaudRate(&termios, posix.speed_t.B115200);
        },
        .file_transfer_recv, .file_transfer_send => {
            termios.iflag = .{
                .IGNBRK = true,
                .IXOFF = true,
            };

            termios.lflag.ECHO = false;
            termios.lflag.ICANON = false;
            termios.lflag.ISIG = false;
            termios.lflag.IEXTEN = false;

            termios.oflag = .{};

            termios.cflag.PARENB = false;
            termios.cflag.CSIZE = .CS8;
            termios.cflag.CREAD = true;
            termios.cflag.CLOCAL = true;
            termios.cc[VMIN] = if (mode == .file_transfer_recv) 0 else 1;
            termios.cc[VTIME] = 50;

            setBaudRate(&termios, posix.speed_t.B3000000);
        },
    }

    // wait until everything is sent
    _ = system.tcdrain(fd);

    // flush input queue
    _ = system.ioctl(fd, TCFLSH, TCIOFLUSH);

    try posix.tcsetattr(fd, posix.TCSA.DRAIN, termios);

    // restart output
    _ = system.ioctl(fd, TCXONC, TCOON);
}

// These aren't defined in the UAPI linux headers for some odd reason.
const SYSLOG_ACTION_READ_ALL = 3;
const SYSLOG_ACTION_UNREAD = 9;

/// Read kernel logs (AKA syslog/dmesg). Caller is responsible for returned
/// slice.
pub fn kernelLogs(allocator: std.mem.Allocator, filter: u8) ![]const u8 {
    const bytes_available = linux.syscall3(linux.SYS.syslog, SYSLOG_ACTION_UNREAD, 0, 0);
    const buf = try allocator.alloc(u8, bytes_available);
    defer allocator.free(buf);

    switch (posix.errno(linux.syscall3(
        linux.SYS.syslog,
        SYSLOG_ACTION_READ_ALL,
        @intFromPtr(buf.ptr),
        buf.len,
    ))) {
        .SUCCESS => {},
        .PERM => return error.PermissionDenied,
        // We don't need to capture the bytes read since we only request for the
        // exact number of bytes available.
        else => |err| return posix.unexpectedErrno(err),
    }

    var logs = std.ArrayList(u8).init(allocator);
    var split = std.mem.splitScalar(u8, buf, '\n');
    while (split.next()) |line| {
        if (line.len <= 2) {
            break;
        }

        const log_level = try std.fmt.parseInt(u8, line[1..2], 10);
        if (log_level <= filter) {
            try logs.appendSlice(line[3..]);
            try logs.append('\n');
        }
    }

    return logs.toOwnedSlice();
}
