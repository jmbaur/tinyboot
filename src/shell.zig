const std = @import("std");
const os = std.os;
const process = std.process;

const ClientMsg = @import("./message.zig").ClientMsg;
const Config = @import("./config.zig").Config;
const Seat = @import("./seat.zig").Seat;
const ServerMsg = @import("./message.zig").ServerMsg;
const system = @import("./system.zig");

pub const Shell = struct {
    comm_fd: os.fd_t,
    arena: std.heap.ArenaAllocator,
    buffer: ?[]u8,
    user_presence: bool = false,
    log_buffer: []align(std.mem.page_size) u8,
    old_log_offset: usize = 0,

    pub fn init(comm_fd: os.fd_t, log_buffer: []align(std.mem.page_size) u8) @This() {
        return @This(){
            .comm_fd = comm_fd,
            .log_buffer = log_buffer,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .buffer = null,
        };
    }

    fn prompt(self: *@This()) !void {
        _ = self;
        try std.io.getStdOut().writeAll(">> ");
    }

    pub fn run(self: *@This()) !void {
        const epoll_fd = try os.epoll_create1(0);
        defer os.close(epoll_fd);

        var set: os.sigset_t = undefined;
        os.sigprocmask(os.SIG.BLOCK, &os.linux.all_mask, &set);

        const signal_fd = try os.signalfd(-1, &os.linux.all_mask, 0);

        var stdin_event = os.linux.epoll_event{
            .data = .{ .fd = os.STDIN_FILENO },
            .events = os.linux.EPOLL.IN,
        };
        try os.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, os.STDIN_FILENO, &stdin_event);

        var comm_event = os.linux.epoll_event{
            .data = .{ .fd = self.comm_fd },
            .events = os.linux.EPOLL.IN,
        };
        try os.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, self.comm_fd, &comm_event);

        var signal_event = os.linux.epoll_event{
            .data = .{ .fd = signal_fd },
            .events = os.linux.EPOLL.IN,
        };
        try os.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, signal_fd, &signal_event);

        try std.io.getStdOut().writeAll("\npress <ENTER> to interrupt\n\n");

        // main event loop
        while (true) {
            const max_events = 8;
            const events_one: os.linux.epoll_event = undefined;
            var events = [_]os.linux.epoll_event{events_one} ** max_events;

            const n_events = os.epoll_wait(epoll_fd, &events, -1);

            var i_event: usize = 0;
            while (i_event < n_events) : (i_event += 1) {
                const event = events[i_event];

                if (event.data.fd == self.comm_fd) {
                    try self.handle_comm();
                } else if (event.data.fd == os.STDIN_FILENO) {
                    if (!self.user_presence) {
                        try self.notify_user_presence();
                        self.user_presence = true;
                    }
                    try self.handle_stdin();
                } else if (event.data.fd == signal_fd) {
                    if (try self.should_quit_shell(signal_fd)) {
                        std.debug.print("\n\ngoodbye!\n\n", .{});
                        return;
                    }
                }
            }
        }
    }

    fn notify_user_presence(self: *@This()) !void {
        var msg: ClientMsg = .None;
        _ = try os.write(self.comm_fd, std.mem.asBytes(&msg));
    }

    fn handle_comm(self: *@This()) !void {
        var msg: ServerMsg = .None;
        _ = try os.read(self.comm_fd, std.mem.asBytes(&msg));

        switch (msg) {
            .NewLogOffset => |offset| {
                if (offset < self.old_log_offset) {
                    self.old_log_offset = 0;
                }

                if (!self.user_presence) {
                    std.debug.print("{s}", .{self.log_buffer[self.old_log_offset..offset]});
                    self.old_log_offset = offset;
                }
            },
            .ForceShell => try self.prompt(),
            .None => {},
        }
    }

    pub fn print_logs(self: *@This()) void {
        if (std.mem.indexOf(u8, self.log_buffer, &.{0})) |end| {
            std.debug.print("{s}", .{self.log_buffer[0..end]});
        }
    }

    fn should_quit_shell(self: *@This(), fd: os.fd_t) !bool {
        _ = self;

        var siginfo = std.mem.zeroes(os.linux.signalfd_siginfo);
        _ = try os.read(fd, std.mem.asBytes(&siginfo));

        return siginfo.signo == os.SIG.USR1;
    }

    fn handle_stdin(self: *@This()) !void {
        defer self.prompt() catch {};

        var allocator = self.arena.allocator();

        var input = std.ArrayList(u8).init(allocator);
        defer input.deinit();

        if (self.buffer) |buffer| {
            try input.appendSlice(buffer);
            allocator.free(buffer);
            self.buffer = null;
        }

        var buf = [_]u8{0} ** 2048;
        const n = try os.read(os.STDIN_FILENO, &buf);

        var found = false;
        for (buf[0..n]) |byte| {
            if (byte == '\n') {
                found = true;
                break;
            }
            try input.append(byte);
        }

        if (!found) {
            // save the input for later
            self.buffer = try input.toOwnedSlice();
            return;
        }

        if (input.items.len == 0) {
            return;
        }

        const maybe_msg = Command.run(input.items, self) catch |err| {
            std.debug.print("error running command: {any}\n", .{err});
            return;
        };

        if (maybe_msg) |msg| {
            _ = try os.write(self.comm_fd, std.mem.asBytes(&msg));
        }
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        os.close(self.comm_fd);
    }
};

pub const Command = struct {
    const ArgsIterator = process.ArgIteratorGeneral(.{});

    const argv0 = enum {
        help, // NOTE: keep "help" at the top
        logs,
        poweroff,
        reboot,
        shell,
    };

    pub fn run(user_input: []const u8, shell_instance: *Shell) !?ClientMsg {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var allocator = arena.allocator();

        var args = try ArgsIterator.init(allocator, user_input);
        defer args.deinit();

        if (args.next()) |cmd| {
            var found = false;

            inline for (std.meta.fields(argv0)) |field| {
                if (std.mem.eql(u8, field.name, cmd)) {
                    found = true;
                    return @field(@This(), field.name).run(
                        allocator,
                        &args,
                        shell_instance,
                    );
                }
            }

            if (!found) {
                std.debug.print("unknown command '{s}'\n", .{cmd});
            }
        }

        return null;
    }

    const help = struct {
        const short_help = "get help";
        const long_help =
            \\Print all available commands or print specific command usage.
            \\
            \\Usage:
            \\help [command]
        ;

        fn run(a: std.mem.Allocator, args: *ArgsIterator, shell_instance: *Shell) !?ClientMsg {
            _ = shell_instance;
            _ = a;

            if (args.next()) |next| {
                var found = false;
                inline for (std.meta.fields(argv0)) |field| {
                    if (std.mem.eql(u8, field.name, next)) {
                        found = true;
                        const cmd_long_help = comptime @field(Command, field.name).long_help;
                        std.debug.print("\n{s}\n", .{cmd_long_help});
                    }
                }

                if (!found) {
                    std.debug.print("unknown command '{s}'\n", .{next});
                }
            } else {
                std.debug.print("\n", .{});

                inline for (std.meta.fields(argv0)) |field| {
                    const cmd_short_help = comptime @field(Command, field.name).short_help;
                    const space = 20 - comptime field.name.len;
                    std.debug.print("{s}{s}{s}\n", .{ field.name, " " ** space, cmd_short_help });
                }
            }

            return null;
        }
    };

    const poweroff = struct {
        const short_help = "poweroff the machine";
        const long_help =
            \\Immediately poweroff the machine.
            \\
            \\Usage:
            \\poweroff
        ;

        fn run(a: std.mem.Allocator, args: *ArgsIterator, shell_instance: *Shell) !?ClientMsg {
            _ = shell_instance;
            _ = args;
            _ = a;

            return .Poweroff;
        }
    };

    const reboot = struct {
        const short_help = "reboot the machine";
        const long_help =
            \\Immediately reboot the machine.
            \\
            \\Usage:
            \\reboot
        ;

        fn run(a: std.mem.Allocator, args: *ArgsIterator, shell_instance: *Shell) !?ClientMsg {
            _ = shell_instance;
            _ = args;
            _ = a;

            return .Reboot;
        }
    };

    const logs = struct {
        const short_help = "view logs";
        const long_help =
            \\View logs of the current boot.
            \\
            \\Usage:
            \\logs
        ;

        fn run(a: std.mem.Allocator, args: *ArgsIterator, shell_instance: *Shell) !?ClientMsg {
            _ = a;
            _ = args;

            shell_instance.print_logs();
            return null;
        }
    };

    const shell = struct {
        const short_help = "run posix shell commands";
        const long_help =
            \\Run the busybox ash shell.
            \\
            \\Usage:
            \\shell
        ;

        fn run(a: std.mem.Allocator, args: *ArgsIterator, shell_instance: *Shell) !?ClientMsg {
            _ = shell_instance;
            _ = args;

            var child = std.ChildProcess.init(&.{"/bin/sh"}, a);
            _ = try child.spawnAndWait();

            return null;
        }
    };
};
