// This program considers all inputs and outputs to be connected to the same
// seat. That is, a virtual terminal connected to a physical display and a
// serial console connected to some client share the same output. Inputs are
// echoed locally, but program are sent to all outputs.
//
//               |--------------|       |----------------|
//               |serial console|       |virtual terminal|
//               | (/dev/ttyS0) |       |  (/dev/tty1)   |
//               |--------------|       |----------------|
//                      |                        |
//                      |   |----------------|   |
//                      |---|seat event loop |---|
//                          |----------------|
//                                  |
//                                  |
//                           |--------------|
//                           |  socketpair  |
//                           |--------------|
//                                  |
//                          |-------|--------|
//                          |       |        |
//                       |-----| |------| |------|
//                       |stdin| |stdout| |stderr|
//                       |-----| |------| |------|

const std = @import("std");
const builtin = @import("builtin");
const os = std.os;

const system = @import("./system.zig");
const Config = @import("./config.zig").Config;
const ClientMsg = @import("./message.zig").ClientMsg;
const ServerMsg = @import("./message.zig").ServerMsg;

const PtsError = error{
    GetName,
    Unlock,
};

const Pts = struct {
    const TIOCGPTN = 0x80045430;
    const TIOCSPTLCK = 0x40045431;

    master: os.fd_t,
    slave: os.fd_t,

    pub fn init() !@This() {
        const master = try os.open("/dev/ptmx", os.O.RDWR | os.O.NOCTTY, 0);

        var slave_num: u32 = 0;
        const get_slave_num_rc = os.linux.ioctl(master, TIOCGPTN, @intFromPtr(&slave_num));
        switch (os.linux.getErrno(get_slave_num_rc)) {
            .SUCCESS => {},
            else => return PtsError.GetName,
        }

        var unlock: u32 = 0;
        const unlock_rc = os.linux.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlock));
        switch (os.linux.getErrno(unlock_rc)) {
            .SUCCESS => {},
            else => return PtsError.Unlock,
        }

        var buf = [_]u8{0} ** 20;
        const slave_path = try std.fmt.bufPrint(&buf, "/dev/pts/{}", .{slave_num});

        const slave = try os.open(slave_path, os.O.RDWR | os.O.NOCTTY, 0);

        system.setupTty(slave) catch |err| switch (err) {
            error.NotATerminal => {},
            else => return err,
        };

        return @This(){ .master = master, .slave = slave };
    }

    pub fn deinit(self: *@This()) void {
        os.close(self.slave);
        os.close(self.master);
    }
};

pub const Console = struct {
    // TODO(jared): use pid_fd to wait for pid to quit
    pid: os.pid_t,
    pid_fd: os.fd_t,
    comm_fd: os.fd_t,
};

pub const Seat = struct {
    /// Used for polling on user input and for writing output from commands.
    consoles: []Console,

    /// Initialize the seat on a set of console file descriptors. Ownership of the
    /// file descriptors is handed to the seat.
    pub fn init(consoles: []Console) @This() {
        return @This(){ .consoles = consoles };
    }

    pub fn register(self: *@This(), epoll_fd: os.fd_t) !void {
        // watch for input data from the communication fd
        for (self.consoles) |console| {
            var event = os.linux.epoll_event{
                .events = os.linux.EPOLL.IN,
                .data = .{ .fd = console.comm_fd },
            };
            try os.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, console.comm_fd, &event);
        }
    }

    pub fn force_shell(self: *@This()) void {
        for (self.consoles) |console| {
            var msg: ServerMsg = .ForceShell;
            _ = os.write(console.comm_fd, std.mem.asBytes(&msg)) catch return;
        }
    }

    pub fn handle_new_event(self: *@This(), event: os.linux.epoll_event) !?os.RebootCommand {
        for (self.consoles) |console| {
            if (console.comm_fd == event.data.fd) {
                var msg: ClientMsg = .None;
                _ = try os.read(console.comm_fd, std.mem.asBytes(&msg));

                switch (msg) {
                    .Reboot => return os.RebootCommand.RESTART,
                    .Poweroff => return os.RebootCommand.POWER_OFF,
                    .None => {},
                }
            }
        }

        return null;
    }

    pub fn deinit(self: *@This()) void {
        for (self.consoles) |console| {
            std.os.close(console.comm_fd);

            _ = os.linux.pidfd_send_signal(console.pid_fd, os.SIG.USR1, null, 0);
            _ = os.waitpid(console.pid, 0);
            os.close(console.pid_fd);
        }
    }
};

// TODO(jared): test that printing to consoles works
test "smoke test" {
    // requires epoll
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    if (true) {
        return error.SkipZigTest;
    }

    var console1 = [2]os.fd_t{ 0, 0 };
    try std.testing.expectEqual(@as(usize, 0), os.linux.socketpair(os.linux.PF.LOCAL, os.SOCK.STREAM, 0, &console1));
    defer os.close(console1[1]);

    var console2 = [2]os.fd_t{ 0, 0 };
    try std.testing.expectEqual(@as(usize, 0), os.linux.socketpair(os.linux.PF.LOCAL, os.SOCK.STREAM, 0, &console2));
    defer os.close(console2[1]);

    var input_pipe = try os.pipe();
    defer {
        os.close(input_pipe[0]);
        os.close(input_pipe[1]);
    }
    var output_pipe = try os.pipe();
    defer {
        os.close(output_pipe[0]);
        os.close(output_pipe[1]);
    }

    var seat = try Seat.init(&[_]os.fd_t{ console1[0], console2[0] }, .{
        .stdin_fd = input_pipe[0],
        .stdout_fd = output_pipe[1],
        .stderr_fd = output_pipe[1],
    });
    defer seat.deinit();

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *Seat) !void {
            s.run() catch |err| {
                std.debug.panic("seat run failed: {any}\n", .{err});
            };
        }
    }.run, .{&seat});
    thread.detach();

    {
        // send data on console1
        const buf_input = "hello\n";
        const n_written = try os.write(console1[1], buf_input);
        var buf = try std.testing.allocator.alloc(u8, n_written);
        defer std.testing.allocator.free(buf);
        const n_read = try os.read(seat.stdin_fd, buf);
        try std.testing.expectEqual(n_written, n_read);
        try std.testing.expectEqualSlices(u8, buf_input[0..n_written], buf[0..n_read]);

        // check that input data on console1 was echoed to console2
        var echo_buf = try std.testing.allocator.alloc(u8, n_written);
        defer std.testing.allocator.free(echo_buf);
        const n_echo = try os.read(console2[1], echo_buf);
        try std.testing.expectEqualSlices(u8, buf_input[0..n_written], echo_buf[0..n_echo]);
    }

    {
        // send data on console2
        const buf_input = "hello again\n";
        const n_written = try os.write(console2[1], buf_input);
        var buf = try std.testing.allocator.alloc(u8, n_written);
        defer std.testing.allocator.free(buf);
        const n_read = try os.read(seat.stdin_fd, buf);
        try std.testing.expectEqual(n_written, n_read);
        try std.testing.expectEqualSlices(u8, buf_input[0..n_written], buf[0..n_read]);

        // check that input data on console2 was echoed to console1
        var echo_buf = try std.testing.allocator.alloc(u8, n_written);
        defer std.testing.allocator.free(echo_buf);
        const n_echo = try os.read(console1[1], echo_buf);
        try std.testing.expectEqualSlices(u8, buf_input[0..n_written], echo_buf[0..n_echo]);
    }
}

test "pts smoke test" {
    var pts = try Pts.init();
    defer pts.deinit();

    const slave_ping_write_n = try os.write(pts.slave, "ping\n");
    try std.testing.expectEqual(@as(usize, 5), slave_ping_write_n);
    var ping_buf = [_]u8{0} ** 6;
    const master_ping_read_n = try os.read(pts.master, &ping_buf);
    try std.testing.expectEqual(@as(usize, 6), master_ping_read_n);
    try std.testing.expectEqualSlices(u8, &.{ 'p', 'i', 'n', 'g', '\r', '\n' }, &ping_buf);

    const master_pong_write_n = try os.write(pts.master, "pong\n");
    try std.testing.expectEqual(@as(usize, 5), master_pong_write_n);

    var pong_buf = [_]u8{0} ** 5;
    const slave_pong_read_n = try os.read(pts.slave, &pong_buf);
    try std.testing.expectEqual(@as(usize, 5), slave_pong_read_n);
    try std.testing.expectEqualSlices(u8, &.{ 'p', 'o', 'n', 'g', '\n' }, &pong_buf);
}
