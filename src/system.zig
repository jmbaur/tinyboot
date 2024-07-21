const std = @import("std");
const posix = std.posix;
const system = std.posix.system;

const linux_headers = @import("linux_headers");

fn mountPseudoFs(
    path: [*:0]const u8,
    fstype: [*:0]const u8,
    flags: u32,
) !void {
    const rc = system.mount("", path, fstype, flags, 0);

    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
}

/// Mounts basic psuedo-filesystems (/dev, /proc, /sys, etc.).
pub fn mountPseudoFilesystems() !void {
    try std.fs.cwd().makePath("/proc");
    try mountPseudoFs("/proc", "proc", system.MS.NOSUID | system.MS.NODEV | system.MS.NOEXEC);

    try std.fs.cwd().makePath("/sys");
    try mountPseudoFs("/sys", "sysfs", system.MS.NOSUID | system.MS.NODEV | system.MS.NOEXEC | system.MS.RELATIME);
    try mountPseudoFs("/sys/kernel/security", "securityfs", system.MS.NOSUID | system.MS.NODEV | system.MS.NOEXEC | system.MS.RELATIME);
    try mountPseudoFs("/sys/kernel/debug", "debugfs", system.MS.NOSUID | system.MS.NODEV | system.MS.NOEXEC | system.MS.RELATIME);

    try std.fs.cwd().makePath("/dev");
    try mountPseudoFs("/dev", "devtmpfs", system.MS.SILENT | system.MS.NOSUID | system.MS.NOEXEC);

    try std.fs.cwd().makePath("/run");
    try mountPseudoFs("/run", "tmpfs", system.MS.NOSUID | system.MS.NODEV);

    try std.fs.cwd().makePath("/mnt");
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

pub const Tty = struct {
    fd: posix.fd_t,
    original: posix.termios,

    pub const Mode = enum {
        no_echo,
        user_input,
        file_transfer,
    };

    pub const ReadError = error{Timeout} || posix.ReadError;
    pub const Reader = std.io.GenericReader(*@This(), ReadError, read);

    pub fn read(self: *@This(), buffer: []u8) ReadError!usize {
        const n_read = try posix.read(self.fd, buffer);

        if (n_read == 0) {
            return ReadError.Timeout;
        }

        return n_read;
    }

    pub fn reader(self: *@This()) Reader {
        return .{ .context = self };
    }

    pub const WriteError = posix.WriteError;
    pub const Writer = std.io.GenericWriter(*@This(), WriteError, write);

    pub fn write(self: *@This(), bytes: []const u8) WriteError!usize {
        return try posix.write(self.fd, bytes);
    }

    pub fn writer(self: *@This()) Writer {
        return .{ .context = self };
    }

    pub fn reset(self: *@This()) void {
        // wait until everything is sent
        _ = system.tcdrain(self.fd);

        // flush input queue
        _ = system.ioctl(self.fd, TCFLSH, TCIOFLUSH);

        posix.tcsetattr(self.fd, posix.TCSA.DRAIN, self.original) catch {};

        // restart output
        _ = system.ioctl(self.fd, TCXONC, TCOON);
    }
};

pub fn setupTty(fd: posix.fd_t, mode: Tty.Mode) !Tty {
    const orig = Tty{
        .fd = fd,
        .original = try posix.tcgetattr(fd),
    };

    var termios = orig.original;

    switch (mode) {
        .no_echo => {
            termios.lflag.ECHO = false;
        },
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
        .file_transfer => {
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

            // https://www.unixwiz.net/techtips/termios-vmin-vtime.html
            termios.cc[VMIN] = 0; // allow timeout with zero bytes obtained
            termios.cc[VTIME] = 50; // 5-second timeout

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

    return orig;
}

// These aren't defined in the UAPI linux headers for some odd reason.
const SYSLOG_ACTION_READ_ALL = 3;
const SYSLOG_ACTION_CONSOLE_OFF = 6;
const SYSLOG_ACTION_CONSOLE_ON = 7;
const SYSLOG_ACTION_UNREAD = 9;

/// Read kernel logs (AKA syslog/dmesg). Caller is responsible for returned
/// slice.
pub fn printKernelLogs(
    allocator: std.mem.Allocator,
    filter: u3,
    writer: std.io.AnyWriter,
) !void {
    const bytes_available = system.syscall3(system.SYS.syslog, SYSLOG_ACTION_UNREAD, 0, 0);
    const buf = try allocator.alloc(u8, bytes_available);
    defer allocator.free(buf);

    switch (posix.errno(system.syscall3(
        system.SYS.syslog,
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

    var split = std.mem.splitScalar(u8, buf, '\n');
    while (split.next()) |line| {
        if (line.len <= 2 or line[0] != '<') {
            break;
        }

        if (std.mem.indexOf(u8, line[0..5], ">")) |right_chevron_index| {
            const syslog_prefix = try std.fmt.parseInt(u32, line[1..right_chevron_index], 10);
            const log_level = 0x7 & syslog_prefix; // lower 3 bits
            if (log_level <= filter) {
                try writer.print("{s}\n", .{line[right_chevron_index + 1 ..]});
            }
        }
    }
}

pub fn toggleConsole(toggle: enum { on, off }) !void {
    switch (posix.errno(system.syscall3(
        system.SYS.syslog,
        switch (toggle) {
            .on => SYSLOG_ACTION_CONSOLE_ON,
            .off => SYSLOG_ACTION_CONSOLE_OFF,
        },
        0, // ignored
        0, // ignored
    ))) {
        .SUCCESS => {},
        .PERM => return error.PermissionDenied,
        else => |err| return posix.unexpectedErrno(err),
    }
}
