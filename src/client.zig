const std = @import("std");
const os = std.os;
const posix = std.posix;
const process = std.process;

const linux_headers = @import("linux_headers");

const ClientMsg = @import("./message.zig").ClientMsg;
const ServerMsg = @import("./message.zig").ServerMsg;
const system = @import("./system.zig");
const xmodem_recv = @import("./xmodem.zig").xmodem_recv;

pub const Client = struct {
    waiting_for_response: bool = false,
    has_prompt: bool = false,
    watching_logs: bool = true,
    input_cursor: u16 = 0,
    input_end: u16 = 0,
    stream: std.net.Stream,
    input_buffer: [buffer_size]u8 = undefined,
    log_file: std.fs.File,
    arena: std.heap.ArenaAllocator,
    writer: BufferedWriter,

    const buffer_size = 4096;
    const BufferedWriter = std.io.BufferedWriter(buffer_size, std.fs.File.Writer);

    pub fn init() !@This() {
        return @This(){
            .stream = try std.net.connectUnixSocket("/run/bus"),
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .writer = std.io.bufferedWriter(std.io.getStdOut().writer()),
            .log_file = try std.fs.openFileAbsolute("/run/log", .{}),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.log_file.close();
        self.stream.close();
        self.arena.deinit();
    }

    fn flush(self: *@This()) !void {
        try self.writer.flush();
    }

    fn writeAll(self: *@This(), bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            index += try self.writer.write(bytes[index..]);
        }
    }

    fn writeAllAndFlush(self: *@This(), bytes: []const u8) !void {
        try self.writeAll(bytes);
        return self.flush();
    }

    fn prompt(self: *@This()) !void {
        try self.writeAllAndFlush(">> ");
    }

    pub fn run(self: *@This()) !void {
        try self.writeAllAndFlush("\npress <ENTER> to interrupt\n\n");

        try self.printLogs(.{}); // print all logs we've received up to now

        const epoll_fd = try posix.epoll_create1(linux_headers.EPOLL_CLOEXEC);
        defer posix.close(epoll_fd);

        var stdin_event = os.linux.epoll_event{
            .data = .{ .fd = posix.STDIN_FILENO },
            .events = os.linux.EPOLL.IN,
        };
        try posix.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, posix.STDIN_FILENO, &stdin_event);

        var server_event = os.linux.epoll_event{
            .data = .{ .fd = self.stream.handle },
            .events = os.linux.EPOLL.IN,
        };
        try posix.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, self.stream.handle, &server_event);

        const inotify_fd = try posix.inotify_init1(0);
        const logs_watch_fd = try posix.inotify_add_watch(inotify_fd, "/run/log", os.linux.IN.MODIFY);
        defer posix.close(inotify_fd);
        var inotify_event = os.linux.epoll_event{
            .data = .{ .fd = inotify_fd },
            .events = os.linux.EPOLL.IN,
        };
        try posix.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, inotify_fd, &inotify_event);

        defer self.writeAllAndFlush("\ngoodbye!\n\n") catch {};

        // main event loop
        while (true) {
            const max_events = 8; // arbitrary
            var events = [_]os.linux.epoll_event{undefined} ** max_events;

            const n_events = posix.epoll_wait(epoll_fd, &events, -1);

            var i_event: usize = 0;
            while (i_event < n_events) : (i_event += 1) {
                const event = events[i_event];

                // If we got an event that wasn't on the inotify fd, it means
                // the client will no longer need to passively watch logs, so
                // we remove the inotify watcher.
                if (event.data.fd != inotify_fd and self.watching_logs) {
                    try posix.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_DEL, inotify_fd, null);
                    posix.inotify_rm_watch(inotify_fd, logs_watch_fd);
                    self.watching_logs = false;
                }

                if (event.data.fd == self.stream.handle) {
                    const should_quit = try self.handleMsg();
                    if (should_quit) {
                        return;
                    }

                    if (self.waiting_for_response) {
                        self.waiting_for_response = false;
                        try self.prompt();
                    }
                } else if (event.data.fd == posix.STDIN_FILENO) {
                    try self.handleStdin();
                } else if (event.data.fd == inotify_fd and self.watching_logs) {
                    // Consume the event on the inotify fd. We don't
                    // actually use the data since we only have one file
                    // registered. If we don't do this, we will continue to
                    // get epoll notifications for this fd.
                    var buf: [@sizeOf(os.linux.inotify_event)]u8 = undefined;
                    _ = posix.read(inotify_fd, &buf) catch {};
                    try self.printLogs(.{ .from_start = false });
                }
            }
        }
    }

    fn notifyUserPresence(self: *@This()) !void {
        var msg: ClientMsg = .None;
        try self.stream.writeAll(std.mem.asBytes(&msg));
    }

    /// Returns true if the remote side shutdown, indicating we are done.
    fn handleMsg(self: *@This()) !bool {
        var msg: ServerMsg = .None;
        if (try self.stream.readAll(std.mem.asBytes(&msg)) == 0) {
            // If we end up here, this means our connection was dropped on the
            // other side. This should only happen if the server has completed
            // successfully or if I wrote a bug :).
            return true;
        }

        switch (msg) {
            .ForceShell => {
                std.log.debug("shell forced from server", .{});
                try self.prompt();
                self.has_prompt = true;
            },
            .None => {},
        }

        return false;
    }

    pub fn printLogs(self: *@This(), opts: struct {
        from_start: bool = true,
    }) !void {
        if (opts.from_start) {
            try self.log_file.seekTo(0);
        }

        while (true) {
            var buf: [4096]u8 = undefined;
            const n_bytes = try self.log_file.reader().readAll(&buf);
            try self.writeAll(buf[0..n_bytes]);
            if (n_bytes < buf.len) {
                try self.flush();
                break;
            }
        }
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
        // We may already have a prompt from a boot timeout, so don't print
        // a prompt if we already have one.
        if (!self.has_prompt) {
            try self.notifyUserPresence();
            try self.prompt();
            self.has_prompt = true;
        }

        // We should only ever get 1 byte of data from stdin since we put the
        // terminal in raw mode.
        var buf = [_]u8{0};
        if (try posix.read(posix.STDIN_FILENO, &buf) != 1) {
            return;
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
                try self.writeAll("\n");
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
                    try self.writeAll(self.input_buffer[self.input_cursor..self.input_end]);
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
                    try self.writeAll(self.input_buffer[self.input_cursor..self.input_end]);
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
                try self.writeAll("\n");
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
                    try self.writeAll(self.input_buffer[self.input_cursor - 2 .. self.input_cursor]);
                    break :b true;
                }

                break :b false;
            },
            // C-u
            0x15 => b: {
                if (self.input_cursor > 0) {
                    self.cursorLeft(self.input_cursor);
                    try self.writeAll(self.input_buffer[self.input_cursor..self.input_end]);
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
                    try self.writeAll(self.input_buffer[self.input_cursor..self.input_end]);
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
                std.debug.print("\nerror running command: {any}\n", .{err});
                try self.prompt();
                return;
            };

            if (maybe_msg) |msg| {
                try self.stream.writeAll(std.mem.asBytes(&msg));
                self.waiting_for_response = true;
            } else {
                // Write the next prompt
                try self.prompt();
            }
        }
    }
};

pub const Command = struct {
    const ArgsIterator = process.ArgIteratorGeneral(.{});

    const argv0 = enum {
        help, // NOTE: keep "help" at the top
        boot_xmodem,
        dmesg,
        logs,
        poweroff,
        reboot,
    };

    pub fn run(user_input: []const u8, shell_instance: *Client) !?ClientMsg {
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

        fn run(a: std.mem.Allocator, args: *ArgsIterator, shell_instance: *Client) !?ClientMsg {
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

        fn run(a: std.mem.Allocator, args: *ArgsIterator, shell_instance: *Client) !?ClientMsg {
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

        fn run(a: std.mem.Allocator, args: *ArgsIterator, shell_instance: *Client) !?ClientMsg {
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

        fn run(a: std.mem.Allocator, args: *ArgsIterator, shell_instance: *Client) !?ClientMsg {
            _ = a;
            _ = args;

            try shell_instance.printLogs(.{});
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

        fn run(a: std.mem.Allocator, args: *ArgsIterator, shell_instance: *Client) !?ClientMsg {
            _ = args;
            const kernel_logs = try system.kernelLogs(a);
            defer a.free(kernel_logs);
            try shell_instance.writeAllAndFlush(kernel_logs);

            return null;
        }
    };

    const boot_xmodem = struct {
        const short_help = "boot over xmodem";
        const long_help =
            \\Boot via kernel and initrd obtained over the xmodem protocol.
            \\
            \\Usage:
            \\boot_xmodem [-n]
            \\
            \\Options:
            \\  -n    no initrd
        ;

        fn run(a: std.mem.Allocator, args: *ArgsIterator, shell_instance: *Client) !?ClientMsg {
            defer system.setupTty(posix.STDIN_FILENO, .user_input) catch {};

            try system.setupTty(posix.STDIN_FILENO, .file_transfer_recv);

            _ = shell_instance;

            const skip_initrd = if (args.next()) |next| std.mem.eql(u8, next, "-n") else false;

            std.log.info("fetching kernel over xmodem", .{});
            const kernel_bytes = try xmodem_recv(a, posix.STDIN_FILENO);
            defer a.free(kernel_bytes);
            var kernel = try std.fs.createFileAbsolute("/run/kernel", .{ .read = true });
            defer kernel.close();
            try kernel.writeAll(kernel_bytes);
            std.log.info("received kernel of size {} bytes", .{kernel_bytes.len});

            if (!skip_initrd) {
                std.log.info("fetching initrd over xmodem", .{});
                const initrd_bytes = try xmodem_recv(a, posix.STDIN_FILENO);
                defer a.free(initrd_bytes);
                var initrd = try std.fs.createFileAbsolute("/run/initrd", .{ .read = true });
                defer initrd.close();
                try initrd.writeAll(initrd_bytes);
                std.log.info("received initrd of size {} bytes", .{initrd_bytes.len});
            }

            std.log.info("fetching kernel params over xmodem", .{});
            const kernel_params_bytes = try xmodem_recv(a, posix.STDIN_FILENO);
            defer a.free(kernel_params_bytes);
            std.log.info("received kernel params '{any}'", .{kernel_params_bytes[0..16]});

            return null;
        }
    };
};
