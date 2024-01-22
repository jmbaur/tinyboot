const std = @import("std");
const os = std.os;
const process = std.process;

const ClientMsg = @import("./message.zig").ClientMsg;
const Config = @import("./config.zig").Config;
const Seat = @import("./seat.zig").Seat;
const ServerMsg = @import("./message.zig").ServerMsg;
const system = @import("./system.zig");

pub const Shell = struct {
    user_presence: bool = false,
    waiting_for_response: bool = false,
    has_prompt: bool = false,
    input_cursor: u16 = 0,
    input_end: u16 = 0,
    comm_fd: os.fd_t,
    old_log_offset: usize = 0,
    log_buffer: []align(std.mem.page_size) u8,
    input_buffer: [buffer_size]u8 = undefined,
    arena: std.heap.ArenaAllocator,
    writer: BufferedWriter,

    const buffer_size = 4096;
    const BufferedWriter = std.io.BufferedWriter(buffer_size, std.fs.File.Writer);

    pub fn init(comm_fd: os.fd_t, log_buffer: []align(std.mem.page_size) u8) @This() {
        return @This(){
            .comm_fd = comm_fd,
            .log_buffer = log_buffer,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .writer = std.io.bufferedWriter(std.io.getStdOut().writer()),
        };
    }

    fn writeAll(self: *@This(), bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            index += try self.writer.write(bytes[index..]);
        }
    }

    fn writeAllAndFlush(self: *@This(), bytes: []const u8) !void {
        try self.writeAll(bytes);
        return self.writer.flush();
    }

    fn prompt(self: *@This()) !void {
        try self.writeAllAndFlush(">> ");
        self.has_prompt = true;
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

        try self.writeAllAndFlush("\npress <ENTER> to interrupt\n\n");

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
                    try self.handleComm();
                    if (self.waiting_for_response) {
                        self.waiting_for_response = false;
                        try self.prompt();
                    }
                } else if (event.data.fd == os.STDIN_FILENO) {
                    try self.handleStdin();
                } else if (event.data.fd == signal_fd) {
                    if (try self.shouldQuitShell(signal_fd)) {
                        try self.writeAllAndFlush("\ngoodbye!\n\n");
                        return;
                    }
                }
            }
        }
    }

    fn notifyUserPresence(self: *@This()) !void {
        var msg: ClientMsg = .None;
        _ = try os.write(self.comm_fd, std.mem.asBytes(&msg));
    }

    fn handleComm(self: *@This()) !void {
        var msg: ServerMsg = .None;
        _ = try os.read(self.comm_fd, std.mem.asBytes(&msg));

        switch (msg) {
            .NewLogOffset => |offset| {
                if (offset < self.old_log_offset) {
                    self.old_log_offset = 0;
                }

                if (!self.user_presence) {
                    try self.writeAllAndFlush(self.log_buffer[self.old_log_offset..offset]);
                    self.old_log_offset = offset;
                }
            },
            .ForceShell => try self.prompt(),
            .None => {},
        }
    }

    pub fn printLogs(self: *@This()) !void {
        if (std.mem.indexOf(u8, self.log_buffer, &.{0})) |end| {
            try self.writeAllAndFlush(self.log_buffer[0..end]);
        }
    }

    fn shouldQuitShell(self: *@This(), fd: os.fd_t) !bool {
        _ = self;

        var siginfo = std.mem.zeroes(os.linux.signalfd_siginfo);
        _ = try os.read(fd, std.mem.asBytes(&siginfo));

        return siginfo.signo == os.SIG.USR1;
    }

    /// Caller required to flush
    fn cursorLeft(self: *@This(), n: u16) void {
        if (n > 0) {
            var buf: [5]u8 = undefined;
            const out = std.fmt.bufPrint(&buf, "{d:0>5}", .{n}) catch return;
            self.writeAll(&.{ 0x1b, '[', out[0], out[1], out[2], out[3], out[4], 'D' }) catch {};
        }
    }

    /// Caller required to flush
    fn cursorRight(self: *@This(), n: u16) void {
        if (n > 0) {
            var buf: [5]u8 = undefined;
            const out = std.fmt.bufPrint(&buf, "{d:0>5}", .{n}) catch return;
            self.writeAll(&.{ 0x1b, '[', out[0], out[1], out[2], out[3], out[4], 'C' }) catch {};
        }
    }

    /// Caller required to flush
    fn eraseToEndOfLine(self: *@This()) void {
        self.writeAll(&.{ 0x1b, '[', 'K' }) catch {};
    }

    /// Empties the display and moves the cursor to absolute position 0, 0.
    fn clearScreen(self: *@This()) void {
        // empties the display
        self.writeAll(&.{ 0x1b, '[', '2', 'J' }) catch {};
        // moves the cursor to 0, 0
        self.writeAll(&.{ 0x1b, '[', '0', ';', '0', 'H' }) catch {};
    }

    fn handleStdin(self: *@This()) !void {
        if (!self.user_presence) {
            try self.notifyUserPresence();
            self.user_presence = true;

            // We may already have a prompt from a boot timeout, so don't print
            // a prompt if we already have one.
            if (!self.has_prompt) {
                try self.prompt();
            }
        }

        var buf = [_]u8{0};
        const bytes_read = try os.read(os.STDIN_FILENO, &buf);
        if (bytes_read != 1) {
            @panic("TODO: handle bytes_read != 1");
        }

        const char = buf[0];

        var done = false;

        const needs_flush = switch (char) {
            // C-k
            0x0b => b: {
                self.eraseToEndOfLine();
                self.input_end = self.input_cursor;
                break :b true;
            },
            // C-a
            0x01 => b: {
                if (self.input_cursor > 0) {
                    self.cursorLeft(self.input_cursor);
                    self.input_cursor = 0;
                    break :b true;
                }

                break :b false;
            },
            // C-b
            0x02 => b: {
                if (self.input_cursor > 0) {
                    self.cursorLeft(1);
                    self.input_cursor -= 1;
                    break :b true;
                }

                break :b false;
            },
            // C-c
            0x03 => b: {
                self.writeAll("\n") catch {};
                self.input_cursor = 0;
                self.input_end = 0;
                try self.prompt();
                break :b false;
            },
            // C-d
            0x04 => b: {
                if (self.input_cursor < self.input_end) {
                    std.mem.copyForwards(
                        u8,
                        self.input_buffer[self.input_cursor .. self.input_end - 1],
                        self.input_buffer[self.input_cursor + 1 .. self.input_end],
                    );
                    self.input_end -= 1;
                    self.writeAll(self.input_buffer[self.input_cursor..self.input_end]) catch {};
                    self.eraseToEndOfLine();
                    self.cursorLeft(self.input_end - self.input_cursor);
                    break :b true;
                }

                break :b false;
            },
            // C-e
            0x05 => b: {
                if (self.input_cursor < self.input_end) {
                    self.cursorRight(self.input_end - self.input_cursor);
                    self.input_cursor = self.input_end;
                    break :b true;
                }

                break :b false;
            },
            // C-f
            0x06 => b: {
                if (self.input_cursor < self.input_end) {
                    self.cursorRight(1);
                    self.input_cursor += 1;
                    break :b true;
                }

                break :b false;
            },
            // C-h, Backspace
            0x08, 0x7f => b: {
                if (self.input_cursor > 0) {
                    std.mem.copyForwards(
                        u8,
                        self.input_buffer[self.input_cursor - 1 .. self.input_end - 1],
                        self.input_buffer[self.input_cursor..self.input_end],
                    );
                    self.input_cursor -= 1;
                    self.input_end -= 1;
                    self.cursorLeft(1);
                    self.writeAll(self.input_buffer[self.input_cursor..self.input_end]) catch {};
                    self.eraseToEndOfLine();
                    self.cursorLeft(self.input_end - self.input_cursor);
                    break :b true;
                }

                break :b false;
            },
            // C-l
            0x0c => b: {
                self.clearScreen();
                try self.prompt();
                try self.writeAll(self.input_buffer[0..self.input_end]);
                self.cursorLeft(self.input_end - self.input_cursor);
                break :b true;
            },
            // \n, C-j
            0x0d, 0x0a => b: {
                self.writeAll("\n") catch {};
                if (self.input_cursor == 0) {
                    try self.prompt();
                } else {
                    done = true;
                }
                break :b true;
            },
            // C-n
            0x0e => false,
            // C-p
            0x10 => false,
            // C-r
            0x12 => false,
            // C-t
            0x14 => b: {
                if (0 < self.input_cursor and self.input_cursor < self.input_end) {
                    std.mem.swap(
                        u8,
                        &self.input_buffer[self.input_cursor - 1],
                        &self.input_buffer[self.input_cursor],
                    );
                    self.cursorLeft(1);
                    self.input_cursor += 1;
                    self.writeAll(self.input_buffer[self.input_cursor - 2 .. self.input_cursor]) catch {};
                    break :b true;
                }

                break :b false;
            },
            // C-u
            0x15 => b: {
                if (self.input_cursor > 0) {
                    self.cursorLeft(self.input_cursor);
                    self.writeAll(self.input_buffer[self.input_cursor..self.input_end]) catch {};
                    self.eraseToEndOfLine();
                    self.input_end = self.input_end - self.input_cursor;
                    self.input_cursor = 0;
                    self.cursorLeft(self.input_end);
                    break :b true;
                }

                break :b false;
            },
            // C-w
            0x17 => false,
            // space, A-Za-z
            0x20, 0x41...0x7a => b: {
                // make sure we have room for another character
                if (self.input_end + 1 < self.input_buffer.len) {
                    std.mem.copyBackwards(
                        u8,
                        self.input_buffer[self.input_cursor + 1 .. self.input_end + 1],
                        self.input_buffer[self.input_cursor..self.input_end],
                    );
                    self.input_buffer[self.input_cursor] = char;
                    self.input_end += 1;
                    self.writeAll(self.input_buffer[self.input_cursor..self.input_end]) catch {};
                    self.input_cursor += 1;
                    self.cursorLeft(self.input_end - self.input_cursor);
                    break :b true;
                }

                break :b false;
            },
            else => false,
        };

        if (needs_flush) {
            try self.writer.flush();
        }

        if (done and self.input_end > 0) {
            const end = self.input_end;
            self.input_cursor = 0;
            self.input_end = 0;

            const maybe_msg = Command.run(self.input_buffer[0..end], self) catch |err| {
                std.debug.print("error running command: {any}\n", .{err});
                return;
            };

            if (maybe_msg) |msg| {
                _ = try os.write(self.comm_fd, std.mem.asBytes(&msg));
                self.waiting_for_response = true;
            } else {
                try self.prompt();
            }
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
        dmesg,
        poweroff,
        reboot,
    };

    pub fn run(user_input: []const u8, shell_instance: *Shell) !?ClientMsg {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

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

            try shell_instance.printLogs();
            return null;
        }
    };

    const dmesg = struct {
        const short_help = "view kernel logs";
        const long_help =
            \\View logs from the kernel.
            \\
            \\Usage:
            \\dmesg
        ;

        fn run(a: std.mem.Allocator, args: *ArgsIterator, shell_instance: *Shell) !?ClientMsg {
            _ = args;
            const kernel_logs = try system.kernelLogs(a);
            defer a.free(kernel_logs);
            try shell_instance.writeAllAndFlush(kernel_logs);
            return null;
        }
    };
};
