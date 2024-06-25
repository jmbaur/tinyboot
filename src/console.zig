const std = @import("std");
const posix = std.posix;
const process = std.process;
const system = std.posix.system;

const linux_headers = @import("linux_headers");

const BootEntry = @import("./boot.zig").BootEntry;
const BootLoader = @import("./boot.zig").BootLoader;
const Xmodem = @import("./boot/xmodem.zig").Xmodem;
const printKernelLogs = @import("./system.zig").printKernelLogs;
const setupTty = @import("./system.zig").setupTty;
const kexecLoad = @import("./boot.zig").kexecLoad;
const utils = @import("./utils.zig");

const esc = std.ascii.control_code.esc;

const ArgsIterator = process.ArgIteratorGeneral(.{});

pub const Notification = enum {
    /// Indication that a user is present at the console, only sent once.
    presence,

    /// Reboot initiated from console.
    reboot,

    /// Poweroff initiated from console.
    poweroff,

    /// Kexec initiated from console.
    kexec,
};

const Console = @This();

const CONSOLE = "/dev/char/5:1";

const IO_BUFFER_SIZE = 4096;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

var out = std.io.bufferedWriter(std.io.getStdOut().writer());

notify: posix.fd_t,
waiting_for_response: bool = false,
has_prompt: bool = false,
watching_logs: bool = true,
input_cursor: u16 = 0,
input_end: u16 = 0,
input_buffer: [IO_BUFFER_SIZE]u8 = undefined,
context: ?BootLoader = null,

pub fn input(notify: posix.fd_t, done: posix.fd_t) !void {
    defer arena.deinit();

    {
        var console = try std.fs.cwd().openFile(CONSOLE, .{ .mode = .read_write });
        defer console.close();

        try posix.dup2(console.handle, posix.STDIN_FILENO);
        try posix.dup2(console.handle, posix.STDOUT_FILENO);
        try posix.dup2(console.handle, posix.STDERR_FILENO);
    }

    var tty = try setupTty(posix.STDIN_FILENO, .user_input);
    defer tty.reset();

    var console = Console{ .notify = notify };
    writeAllAndFlush("\npress <ENTER> to interrupt\n\n");

    const epoll_fd = try posix.epoll_create1(linux_headers.EPOLL_CLOEXEC);
    defer posix.close(epoll_fd);

    try posix.epoll_ctl(epoll_fd, system.EPOLL.CTL_ADD, done, @constCast(&.{
        .data = .{ .fd = done },
        .events = system.EPOLL.IN | system.EPOLL.ONESHOT,
    }));

    try posix.epoll_ctl(epoll_fd, system.EPOLL.CTL_ADD, posix.STDIN_FILENO, @constCast(&.{
        .data = .{ .fd = posix.STDIN_FILENO },
        .events = system.EPOLL.IN,
    }));

    while (true) {
        const max_events = 8;
        var events = [_]system.epoll_event{undefined} ** max_events;

        const n_events = posix.epoll_wait(epoll_fd, &events, -1);

        var i_event: usize = 0;
        while (i_event < n_events) : (i_event += 1) {
            const event = events[i_event];
            if (event.data.fd == done) {
                writeAllAndFlush("\ngoodbye!\n\n");
                return;
            } else if (event.data.fd == posix.STDIN_FILENO) {
                try console.handleStdin();
            }
        }
    }
}

fn flush() void {
    out.flush() catch {};
}

fn writeAll(bytes: []const u8) void {
    out.writer().writeAll(bytes) catch {};
}

fn writeAllAndFlush(bytes: []const u8) void {
    writeAll(bytes);
    flush();
}

fn prompt(self: *Console) !void {
    if (self.context) |*ctx| {
        try out.writer().writeAll(ctx.name());
    }
    writeAllAndFlush("> ");
}

fn writeNotification(self: *Console, notification: Notification) !void {
    _ = try posix.write(
        self.notify,
        std.mem.asBytes(&@as(u64, @intFromEnum(notification) + 1)),
    );
}

/// Caller required to flush
fn cursorLeft(n: u16) void {
    if (n > 0) {
        out.writer().print(.{esc} ++ "[{d:0>5}D", .{n}) catch {};
    }
}

/// Caller required to flush
fn cursorRight(n: u16) void {
    if (n > 0) {
        out.writer().print(.{esc} ++ "[{d}C", .{n}) catch {};
    }
}

/// Caller required to flush
fn eraseToEndOfLine() void {
    out.writer().writeAll(.{esc} ++ "[K") catch {};
}

/// Empties the display and moves the cursor to absolute position 0, 0.
fn clearScreen() void {
    // empties the display
    out.writer().writeAll(.{esc} ++ "[2J") catch {};
    // moves the cursor to 0, 0
    out.writer().writeAll(.{esc} ++ "[0;0H") catch {};
}

fn handleStdin(self: *Console) !void {
    // We may already have a prompt from a boot timeout, so don't print
    // a prompt if we already have one.
    if (!self.has_prompt) {
        try utils.eventfdWriteEnum(Notification, self.notify, .presence);
        try self.prompt();
        self.has_prompt = true;
    }

    // We should only ever get 1 byte of data from stdin since we put the
    // terminal in raw mode.
    var buf = [_]u8{0};
    if (try std.io.getStdIn().read(&buf) != 1) {
        return;
    }

    const char = buf[0];

    var done = false;

    const needs_flush = switch (char) {
        // C-k
        0x0b => b: {
            eraseToEndOfLine();
            self.input_end = self.input_cursor;
            break :b true;
        },
        // C-a
        0x01 => b: {
            if (self.input_cursor > 0) {
                cursorLeft(self.input_cursor);
                self.input_cursor = 0;
                break :b true;
            }

            break :b false;
        },
        // C-b
        0x02 => b: {
            if (self.input_cursor > 0) {
                cursorLeft(1);
                self.input_cursor -= 1;
                break :b true;
            }

            break :b false;
        },
        // C-c
        0x03 => b: {
            writeAll("\n");
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
                writeAll(self.input_buffer[self.input_cursor..self.input_end]);
                eraseToEndOfLine();
                cursorLeft(self.input_end - self.input_cursor);
                break :b true;
            }

            break :b false;
        },
        // C-e
        0x05 => b: {
            if (self.input_cursor < self.input_end) {
                cursorRight(self.input_end - self.input_cursor);
                self.input_cursor = self.input_end;
                break :b true;
            }

            break :b false;
        },
        // C-f
        0x06 => b: {
            if (self.input_cursor < self.input_end) {
                cursorRight(1);
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
                cursorLeft(1);
                writeAll(self.input_buffer[self.input_cursor..self.input_end]);
                eraseToEndOfLine();
                cursorLeft(self.input_end - self.input_cursor);
                break :b true;
            }

            break :b false;
        },
        // C-l
        0x0c => b: {
            clearScreen();
            try self.prompt();
            writeAll(self.input_buffer[0..self.input_end]);
            cursorLeft(self.input_end - self.input_cursor);
            break :b true;
        },
        // \r, \n; \n is also known as C-j
        0x0d, 0x0a => b: {
            writeAll("\n");
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
                cursorLeft(1);
                self.input_cursor += 1;
                writeAll(self.input_buffer[self.input_cursor - 2 .. self.input_cursor]);
                break :b true;
            }

            break :b false;
        },
        // C-u
        0x15 => b: {
            if (self.input_cursor > 0) {
                cursorLeft(self.input_cursor);
                writeAll(self.input_buffer[self.input_cursor..self.input_end]);
                eraseToEndOfLine();
                self.input_end = self.input_end - self.input_cursor;
                self.input_cursor = 0;
                cursorLeft(self.input_end);
                break :b true;
            }

            break :b false;
        },
        // C-w
        0x17 => false,
        // Space...~
        0x20...0x7e => b: {
            // make sure we have room for another character
            if (self.input_end + 1 < self.input_buffer.len) {
                std.mem.copyBackwards(
                    u8,
                    self.input_buffer[self.input_cursor + 1 .. self.input_end + 1],
                    self.input_buffer[self.input_cursor..self.input_end],
                );
                self.input_buffer[self.input_cursor] = char;
                self.input_end += 1;
                writeAll(self.input_buffer[self.input_cursor..self.input_end]);
                self.input_cursor += 1;
                cursorLeft(self.input_end - self.input_cursor);
                break :b true;
            }

            break :b false;
        },
        else => false,
    };

    if (needs_flush) {
        flush();
    }

    if (done and self.input_end > 0) {
        defer {
            if (self.context == null) {
                _ = arena.reset(.retain_capacity);
            }
        }

        const end = self.input_end;
        self.input_cursor = 0;
        self.input_end = 0;

        const user_input = self.input_buffer[0..end];
        var args = try ArgsIterator.init(arena.allocator(), user_input);
        defer args.deinit();

        const maybe_notification = self.runCommand(&args);

        const notification = maybe_notification catch |err| {
            std.debug.print("\nerror running command: {any}\n", .{err});
            try self.prompt();
            return;
        } orelse {
            return try self.prompt();
        };

        utils.eventfdWriteEnum(Notification, self.notify, notification) catch |err| {
            std.log.err("failed to send notification from console: {}", .{err});
        };
    }
}

fn runCommand(self: *Console, args: *ArgsIterator) !?Notification {
    if (args.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "help")) {
            return @field(Command, "help").run(self, args);
        }

        if (self.context) |*ctx| {
            inline for (std.meta.fields(Command.Context)) |field| {
                if (std.mem.eql(u8, field.name, cmd)) {
                    return @field(Command, field.name).run(self, args, ctx);
                }
            }
        } else {
            inline for (std.meta.fields(Command.NoContext)) |field| {
                if (std.mem.eql(u8, field.name, cmd)) {
                    return @field(Command, field.name).run(self, args);
                }
            }
        }

        std.debug.print("unknown command \"{s}\"\n", .{cmd});
    }

    return null;
}

pub const Command = struct {
    const NoContext = enum {
        clear,
        loader,
        logs,
        poweroff,
        reboot,
    };

    const Context = enum {
        // exit,
        // list,
    };

    const help = struct {
        const short_help = "get help";
        const long_help =
            \\Print all available commands or print specific command usage.
            \\
            \\Usage:
            \\help [command]
        ;

        /// Prints a help message for all commands.
        fn helpAll(t: anytype) void {
            std.debug.print("\n", .{});

            inline for (std.meta.fields(t)) |field| {
                const cmd_short_help = comptime @field(Command, field.name).short_help;
                const space = 20 - comptime field.name.len;
                std.debug.print("{s}{s}{s}\n", .{ field.name, " " ** space, cmd_short_help });
            }
        }

        /// Prints a help message for a single command.
        fn helpOne(t: anytype, cmd: []const u8) void {
            if (std.mem.eql(u8, cmd, "help")) {
                const cmd_long_help = comptime @field(Command, "help").long_help;
                std.debug.print("\n{s}\n", .{cmd_long_help});
                return;
            }

            inline for (std.meta.fields(t)) |field| {
                if (std.mem.eql(u8, field.name, cmd)) {
                    const cmd_long_help = comptime @field(Command, field.name).long_help;
                    std.debug.print("\n{s}\n", .{cmd_long_help});
                    return;
                }
            }

            std.debug.print("unknown command \"{s}\"\n", .{cmd});
        }

        fn run(console: *Console, args: *ArgsIterator) !?Notification {
            if (args.next()) |cmd| {
                if (console.context == null) {
                    helpOne(NoContext, cmd);
                } else {
                    helpOne(Context, cmd);
                }
            } else {
                if (console.context == null) {
                    helpAll(NoContext);
                } else {
                    helpAll(Context);
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

        fn run(_: *Console, _: *ArgsIterator) !?Notification {
            return .poweroff;
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

        fn run(_: *Console, _: *ArgsIterator) !?Notification {
            return .reboot;
        }
    };

    const logs = struct {
        const short_help = "view kernel logs";
        const long_help =
            \\View kernel logs. All logs at or below the specified filter will
            \\be shown.
            \\
            \\Usage:
            \\logs [log level filter]          Default filter is log level 6
            \\
            \\Example:
            \\logs 7
        ;

        fn run(_: *Console, args: *ArgsIterator) !?Notification {
            const filter = if (args.next()) |filter_str|
                try std.fmt.parseInt(u3, filter_str, 10)
            else
                6;

            try printKernelLogs(
                arena.allocator(),
                filter,
                out.writer().any(),
            );

            return null;
        }
    };

    const clear = struct {
        const short_help = "clear the screen";
        const long_help =
            \\Clear the screen.
            \\
            \\Usage:
            \\clear
        ;

        fn run(_: *Console, _: *ArgsIterator) !?Notification {
            clearScreen();

            return null;
        }
    };

    const loader = struct {
        const short_help = "choose a bootloader";
        // TODO(jared): comptime generation of possible list of bootloaders
        const long_help =
            \\Choose a bootloader. One of "disk" or "xmodem".
            \\
            \\Usage:
            \\loader [bootloader]
            \\
            \\Example:
            \\loader disk
        ;

        fn run(console: *Console, args: *ArgsIterator) !?Notification {
            const loader_name = args.next() orelse return error.InvalidArgs;

            if (std.mem.eql(u8, loader_name, "disk")) {
                _ = console;
                // console.context = try BootLoader.init(arena.allocator(), .disk);
            }

            return null;
        }
    };

    // const exit = struct {
    //     const short_help = "exit context";
    //     const long_help =
    //         \\Exit bootloader context.
    //         \\
    //         \\Usage:
    //         \\exit
    //     ;
    //
    //     fn run(console: *Console, _: *ArgsIterator, boot_loader: *BootLoader) !?Notification {
    //         defer console.context = null;
    //
    //         try boot_loader.deinit();
    //
    //         return null;
    //     }
    // };

    // const list = struct {
    //     const short_help = "list boot devices";
    //     const long_help =
    //         \\List boot devices.
    //         \\
    //         \\Usage:
    //         \\list
    //     ;
    //
    //     fn run(_: *Console, _: *ArgsIterator, boot_loader: *BootLoader) !?Notification {
    //         const devices = try boot_loader.listBootDevices();
    //
    //         for (devices) |device| {
    //             std.debug.print("{}\n", .{device.name});
    //         }
    //
    //         return null;
    //     }
    // };
};

// const boot_xmodem = struct {
//     const short_help = "boot over xmodem";
//     const long_help =
//         \\Boot via kernel and initrd obtained over the xmodem protocol. The
//         \\serial console will fetch the following content over xmodem in
//         \\succession:
//         \\ - kernel
//         \\ - initrd (optional)
//         \\ - kernel params
//         \\
//         \\Usage:
//         \\boot_xmodem [options]
//         \\
//         \\Options:
//         \\  -n              No initrd
//     ;
//
//     fn run(console: *Console, args: *ArgsIterator) !?Outcome {
//         var xmodem = try Xmodem.init(console.allocator, .{
//             .serial_name = "console-stdin",
//             .serial_fd = posix.STDIN_FILENO,
//             .skip_initrd = if (args.next()) |next|
//                 std.mem.eql(u8, next, "-n")
//             else
//                 false,
//         });
//         var boot_loader = BootLoader{ .xmodem = &xmodem };
//         defer boot_loader.teardown() catch {};
//
//         try boot_loader.setup();
//         const devices = try boot_loader.probe();
//         for (devices) |device| {
//             for (device.entries) |entry| {
//                 if (kexecLoad(c.allocator, entry.linux, entry.initrd, entry.cmdline)) {
//                     boot_loader.entryLoaded(entry.context);
//                     return .{ .data = .kexec };
//                 } else |err| {
//                     std.log.err("failed to load kernel: {}", .{err});
//                 }
//             }
//         }
//
//         return null;
//     }
// };
