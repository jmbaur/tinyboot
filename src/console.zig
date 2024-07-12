const std = @import("std");
const posix = std.posix;
const process = std.process;

const linux_headers = @import("linux_headers");

const BootLoader = @import("./boot/bootloader.zig");
const Device = @import("./device.zig");
const Xmodem = @import("./boot/xmodem.zig").Xmodem;
const system = @import("./system.zig");
const utils = @import("./utils.zig");

const esc = std.ascii.control_code.esc;

const ArgsIterator = process.ArgIteratorGeneral(.{});

pub const Event = enum {
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

pub const IN = posix.STDIN_FILENO;

var out = std.io.bufferedWriter(std.io.getStdOut().writer());

arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
input_cursor: u16 = 0,
input_end: u16 = 0,
input_buffer: [IO_BUFFER_SIZE]u8 = undefined,
context: ?*BootLoader = null,
tty: ?system.Tty = null,

pub fn init() !Console {
    // Turn off local echo, making the ENTER key the only thing that shows a
    // sign of user input.
    {
        _ = try system.setupTty(IN, .no_echo);
        writeAllAndFlush("\npress <ENTER> to interrupt\n\n");
    }

    return .{};
}

fn flush() void {
    out.flush() catch {};
}

/// Flushes occur transparently. Do not use if control over when flushes occur
/// is needed.
fn print(comptime format: []const u8, args: anytype) void {
    out.writer().print(format, args) catch {};
}

fn writeAll(bytes: []const u8) void {
    out.writer().writeAll(bytes) catch {};
}

fn writeAllAndFlush(bytes: []const u8) void {
    writeAll(bytes);
    flush();
}

fn prompt(self: *Console) !void {
    if (self.context) |ctx| {
        try out.writer().writeAll(ctx.name());
    }
    writeAllAndFlush("> ");
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

pub fn deinit(self: *Console) void {
    defer self.arena.deinit();

    if (self.tty) |*tty| {
        tty.reset();
    }
}

pub fn handleStdin(self: *Console, boot_loaders: []*BootLoader) !?Event {
    // We may already have a prompt from a boot timeout, so don't print
    // a prompt if we already have one.
    if (self.tty == null) {
        self.tty = try system.setupTty(IN, .user_input);
        std.log.debug("user presence detected", .{});
        try self.prompt();
    }

    // We should only ever get 1 byte of data from stdin since we put the
    // terminal in raw mode.
    var buf = [_]u8{0};
    if (try std.io.getStdIn().read(&buf) != 1) {
        return null;
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
                _ = self.arena.reset(.retain_capacity);
            }
        }

        const end = self.input_end;
        self.input_cursor = 0;
        self.input_end = 0;

        const user_input = self.input_buffer[0..end];
        var args = try ArgsIterator.init(self.arena.allocator(), user_input);
        defer args.deinit();

        const maybe_notification = self.runCommand(&args, boot_loaders);

        const event = maybe_notification catch |err| {
            print("\nerror running command: {}\n", .{err});
            try self.prompt();
            return null;
        } orelse {
            try self.prompt();
            return null;
        };

        return event;
    }

    return null;
}

fn runCommand(
    self: *Console,
    args: *ArgsIterator,
    boot_loaders: []*BootLoader,
) !?Event {
    if (args.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "help")) {
            return @field(Command, "help").run(self, args, boot_loaders);
        }

        if (self.context) |ctx| {
            inline for (std.meta.fields(Command.Context)) |field| {
                if (std.mem.eql(u8, field.name, cmd)) {
                    return @field(Command, field.name).run(
                        self,
                        args,
                        ctx,
                    );
                }
            }
        } else {
            inline for (std.meta.fields(Command.NoContext)) |field| {
                if (std.mem.eql(u8, field.name, cmd)) {
                    return @field(Command, field.name).run(
                        self,
                        args,
                        boot_loaders,
                    );
                }
            }
        }

        print("unknown command \"{s}\"\n", .{cmd});
    }

    return null;
}

pub const Command = struct {
    const NoContext = enum {
        clear,
        logs,
        poweroff,
        reboot,
        list,
        select,
    };

    const Context = enum {
        exit,
        probe,
        boot,
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
            print("\n", .{});

            inline for (std.meta.fields(t)) |field| {
                const cmd_short_help = comptime @field(Command, field.name).short_help;
                const space = 20 - comptime field.name.len;
                print("{s}{s}{s}\n", .{ field.name, " " ** space, cmd_short_help });
            }
        }

        /// Prints a help message for a single command.
        fn helpOne(t: anytype, cmd: []const u8) void {
            if (std.mem.eql(u8, cmd, "help")) {
                const cmd_long_help = comptime @field(Command, "help").long_help;
                print("\n{s}\n", .{cmd_long_help});
                return;
            }

            inline for (std.meta.fields(t)) |field| {
                if (std.mem.eql(u8, field.name, cmd)) {
                    const cmd_long_help = comptime @field(Command, field.name).long_help;
                    print("\n{s}\n", .{cmd_long_help});
                    return;
                }
            }

            print("unknown command \"{s}\"\n", .{cmd});
        }

        fn run(console: *Console, args: *ArgsIterator, _: []*const BootLoader) !?Event {
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

        fn run(_: *Console, _: *ArgsIterator, _: []*const BootLoader) !?Event {
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

        fn run(_: *Console, _: *ArgsIterator, _: []*const BootLoader) !?Event {
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

        fn run(console: *Console, args: *ArgsIterator, _: []*const BootLoader) !?Event {
            const filter = if (args.next()) |filter_str|
                try std.fmt.parseInt(u3, filter_str, 10)
            else
                6;

            try system.printKernelLogs(
                console.arena.allocator(),
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

        fn run(_: *Console, _: *ArgsIterator, _: []*const BootLoader) !?Event {
            clearScreen();

            return null;
        }
    };

    const select = struct {
        const short_help = "select boot loader";
        const long_help =
            \\Select a boot loader.
            \\
            \\Usage:
            \\select <index>
            \\
            \\Example:
            \\select 2
        ;

        fn run(console: *Console, args: *ArgsIterator, boot_loaders: []*BootLoader) !?Event {
            const want_index = try std.fmt.parseInt(
                usize,
                args.next() orelse return error.InvalidArgument,
                10,
            );

            for (boot_loaders, 0..) |boot_loader, index| {
                if (want_index == index) {
                    console.context = boot_loader;
                    print(
                        "selected boot loader: {s} ({})\n",
                        .{ boot_loader.name(), boot_loader.device },
                    );
                    return null;
                }
            }

            return error.NotFound;
        }
    };

    const list = struct {
        const short_help = "list boot loaders";
        const long_help =
            \\List all active boot loaders.
            \\
            \\Usage:
            \\list
        ;

        fn run(_: *Console, _: *ArgsIterator, boot_loaders: []*BootLoader) !?Event {
            writeAll("\n");

            for (boot_loaders, 0..) |boot_loader, index| {
                print(
                    "{d}\t{s} ({})\n",
                    .{ index, boot_loader.name(), boot_loader.device },
                );
            }

            return null;
        }
    };

    const exit = struct {
        const short_help = "exit context";
        const long_help =
            \\Exit bootloader context.
            \\
            \\Usage:
            \\exit
        ;

        fn run(console: *Console, _: *ArgsIterator, _: *BootLoader) !?Event {
            defer console.context = null;

            return null;
        }
    };

    const probe = struct {
        const short_help = "probe for boot entries";
        const long_help =
            \\Probe and show all boot entries on a device.
            \\
            \\Usage:
            \\probe
        ;

        fn run(_: *Console, _: *ArgsIterator, boot_loader: *BootLoader) !?Event {
            const entries = boot_loader.probe() catch |err| {
                print("failed to probe: {}\n", .{err});
                return null;
            };

            writeAll("\n");

            for (entries, 0..) |entry, index| {
                print("{d}\t{s}\n", .{ index, entry.linux });
            }

            return null;
        }
    };

    const boot = struct {
        const short_help = "boot an entry";
        const long_help =
            \\Boot an entry.
            \\
            \\Usage:
            \\boot <index>          Default is to boot the first entry
            \\
            \\Example
            \\boot 7
        ;

        fn run(_: *Console, args: *ArgsIterator, boot_loader: *BootLoader) !?Event {
            const want_index = try std.fmt.parseInt(
                usize,
                args.next() orelse "0",
                10,
            );

            const entries = boot_loader.probe() catch |err| {
                print("failed to probe: {}\n", .{err});
                return null;
            };

            for (entries, 0..) |entry, index| {
                if (want_index == index) {
                    if (boot_loader.load(entry)) {
                        print(
                            "selected entry: {s}\n",
                            .{entry.linux},
                        );

                        return Event.kexec;
                    } else |err| {
                        print("failed to load entry: {}", .{err});
                        return null;
                    }
                }
            }

            return error.NotFound;
        }
    };
};
