const std = @import("std");
const posix = std.posix;
const process = std.process;
const esc = std.ascii.control_code.esc;
pub const IN = posix.STDIN_FILENO;
const builtin = @import("builtin");

const BootLoader = @import("./boot/bootloader.zig");
const system = @import("./system.zig");

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

const NON_WORD_CHARS = std.ascii.whitespace ++ [_]u8{ '.', ';', ',' };

var out = std.io.bufferedWriter(std.io.getStdOut().writer());

const Shell = struct {
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    input_cursor: usize = 0,
    input_end: usize = 0,
    stdin: std.fs.File.Reader = std.io.getStdIn().reader(),
    input_buffer: [std.math.maxInt(u9)]u8 = undefined,
    history: History = .{},

    pub fn deinit(self: *@This()) void {
        defer self.arena.deinit();

        self.history.deinit(self.arena.allocator());
    }

    pub fn prompt(self: *@This(), context: ?*BootLoader) void {
        _ = self;

        if (context) |ctx| {
            writeAll(ctx.name());
        }
        writeAllAndFlush("> ");
    }

    fn historyPrev(self: *@This()) bool {
        if (self.history.prev()) |prev| {
            @memcpy(self.input_buffer[0..prev.len], prev);
            const old_end = self.input_end;

            self.input_end = prev.len;
            self.input_cursor = prev.len;

            cursorLeft(old_end);
            writeAll(self.input_buffer[0..self.input_end]);
            eraseToEndOfLine();

            return true;
        }

        return false;
    }

    fn historyNext(self: *@This()) bool {
        if (self.history.next()) |next| {
            @memcpy(self.input_buffer[0..next.len], next);
            const old_end = self.input_end;

            self.input_end = next.len;
            self.input_cursor = next.len;

            cursorLeft(old_end);
            writeAll(self.input_buffer[0..self.input_end]);
            eraseToEndOfLine();

            return true;
        } else {
            // We are back out of scrolling through history, start from
            // a clean slate.
            cursorLeft(self.input_end);

            self.input_end = 0;
            self.input_cursor = 0;

            eraseToEndOfLine();

            return true;
        }

        return false;
    }

    fn moveLeft(self: *@This()) bool {
        if (self.input_cursor > 0) {
            cursorLeft(1);
            self.input_cursor -|= 1;
            return true;
        }

        return false;
    }

    fn moveRight(self: *@This()) bool {
        if (self.input_cursor < self.input_end) {
            cursorRight(1);
            self.input_cursor +|= 1;
            return true;
        }

        return false;
    }

    pub fn handleInput(self: *@This(), context: ?*BootLoader) !?[]const u8 {
        std.debug.assert(self.input_cursor <= self.input_end);

        var done = false;

        const char = try self.stdin.readByte();

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
            0x02 => self.moveLeft(),
            // C-c
            0x03 => b: {
                writeAll("\n");
                self.input_cursor = 0;
                self.input_end = 0;
                done = true;
                break :b true;
            },
            // C-d
            0x04 => b: {
                if (self.input_cursor < self.input_end) {
                    eraseInputAndUpdateCursor(&self.input_buffer, self.input_cursor, &self.input_end, 1);
                    break :b true;
                }

                break :b false;
            },
            // C-e
            0x05 => b: {
                if (self.input_cursor < self.input_end) {
                    cursorRight(self.input_end -| self.input_cursor);
                    self.input_cursor = self.input_end;
                    break :b true;
                }

                break :b false;
            },
            // C-f
            0x06 => self.moveRight(),
            // Bell
            0x07 => false,
            // C-h, Backspace
            0x08, 0x7f => b: {
                if (self.input_cursor > 0) {
                    std.mem.copyForwards(
                        u8,
                        self.input_buffer[self.input_cursor -| 1..self.input_end -| 1],
                        self.input_buffer[self.input_cursor..self.input_end],
                    );
                    self.input_cursor -|= 1;
                    self.input_end -|= 1;
                    cursorLeft(1);
                    writeAll(self.input_buffer[self.input_cursor..self.input_end]);
                    eraseToEndOfLine();
                    cursorLeft(self.input_end -| self.input_cursor);
                    break :b true;
                }

                break :b false;
            },
            // Tab
            0x09 => false,
            // C-l
            0x0c => b: {
                clearScreen();
                self.prompt(context);
                writeAll(self.input_buffer[0..self.input_end]);
                cursorLeft(self.input_end -| self.input_cursor);
                break :b true;
            },
            // \r, \n; \n is also known as C-j
            0x0d, 0x0a => b: {
                writeAll("\n");
                done = true;
                break :b true;
            },
            // C-n
            0x0e => self.historyNext(),
            // C-p
            0x10 => self.historyPrev(),
            // C-r
            0x12 => false,
            // C-t
            0x14 => b: {
                if (0 < self.input_cursor and self.input_cursor < self.input_end) {
                    std.mem.swap(
                        u8,
                        &self.input_buffer[self.input_cursor -| 1],
                        &self.input_buffer[self.input_cursor],
                    );
                    cursorLeft(1);
                    self.input_cursor +|= 1;
                    writeAll(self.input_buffer[self.input_cursor -| 2..self.input_cursor]);
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
                    self.input_end = self.input_end -| self.input_cursor;
                    self.input_cursor = 0;
                    cursorLeft(self.input_end);
                    break :b true;
                }

                break :b false;
            },
            // C-w
            0x17 => b: {
                if (self.input_cursor > 0) {
                    const old_cursor = self.input_cursor;

                    const last_word = std.mem.lastIndexOfNone(
                        u8,
                        self.input_buffer[0..self.input_cursor],
                        &NON_WORD_CHARS,
                    ) orelse 0;

                    self.input_cursor = @intCast(last_word);

                    const last_non_word = std.mem.lastIndexOfAny(
                        u8,
                        self.input_buffer[0..self.input_cursor],
                        &NON_WORD_CHARS,
                    ) orelse 0;

                    self.input_cursor = @intCast(last_non_word);

                    if (self.input_cursor > 0) {
                        const first_word = std.mem.indexOfNone(
                            u8,
                            self.input_buffer[self.input_cursor..self.input_end],
                            &NON_WORD_CHARS,
                        ) orelse 0;
                        self.input_cursor +|= @intCast(first_word);
                    }

                    cursorLeft(old_cursor - self.input_cursor);
                    eraseInputAndUpdateCursor(
                        &self.input_buffer,
                        self.input_cursor,
                        &self.input_end,
                        old_cursor - self.input_cursor,
                    );

                    break :b true;
                }

                break :b false;
            },
            // Space...~
            0x20...0x7e => b: {
                if (builtin.mode == .Debug and char == '?') {
                    print("\n{}\n", .{self});
                    break :b true;
                } else if

                // make sure we have room for another character
                (self.input_end +| 1 < self.input_buffer.len) {
                    std.mem.copyBackwards(
                        u8,
                        self.input_buffer[self.input_cursor +| 1..self.input_end +| 1],
                        self.input_buffer[self.input_cursor..self.input_end],
                    );
                    self.input_buffer[self.input_cursor] = char;
                    self.input_end +|= 1;
                    writeAll(self.input_buffer[self.input_cursor..self.input_end]);
                    self.input_cursor +|= 1;
                    cursorLeft(self.input_end -| self.input_cursor);
                    break :b true;
                }

                break :b false;
            },
            // Escape sequence
            0x1b => b: {
                switch (try self.stdin.readByte()) {
                    0x5b => {
                        switch (try self.stdin.readByte()) {
                            // Up arrow
                            0x41 => break :b self.historyPrev(),
                            // Down arrow
                            0x42 => break :b self.historyNext(),
                            // Right arrow
                            0x43 => break :b self.moveRight(),
                            // Left arrow
                            0x44 => break :b self.moveLeft(),
                            else => {},
                        }
                    },
                    // M-b
                    0x62 => {
                        if (self.input_cursor > 0) {
                            const old_cursor = self.input_cursor;

                            const last_word = std.mem.lastIndexOfNone(
                                u8,
                                self.input_buffer[0..self.input_cursor],
                                &NON_WORD_CHARS,
                            ) orelse 0;

                            self.input_cursor = @intCast(last_word);

                            const last_non_word = std.mem.lastIndexOfAny(
                                u8,
                                self.input_buffer[0..self.input_cursor],
                                &NON_WORD_CHARS,
                            ) orelse 0;

                            self.input_cursor = @intCast(last_non_word);

                            if (self.input_cursor > 0) {
                                const first_word = std.mem.indexOfNone(
                                    u8,
                                    self.input_buffer[self.input_cursor..self.input_end],
                                    &NON_WORD_CHARS,
                                ) orelse 0;
                                self.input_cursor +|= @intCast(first_word);
                            }

                            cursorLeft(old_cursor -| self.input_cursor);

                            break :b true;
                        }
                    },
                    // M-d
                    0x64 => {
                        if (self.input_cursor < self.input_end) {
                            var cursor = self.input_cursor;

                            const first_word = std.mem.indexOfNone(
                                u8,
                                self.input_buffer[cursor..self.input_end],
                                &NON_WORD_CHARS,
                            ) orelse self.input_end -| cursor;

                            cursor +|= first_word;

                            const first_non_word = std.mem.indexOfAny(
                                u8,
                                self.input_buffer[cursor..self.input_end],
                                &NON_WORD_CHARS,
                            ) orelse self.input_end -| cursor;

                            cursor +|= first_non_word;

                            const next_word = std.mem.indexOfNone(
                                u8,
                                self.input_buffer[cursor..self.input_end],
                                &NON_WORD_CHARS,
                            );

                            const end = if (next_word == null)
                                // erase to end else
                                self.input_end -| self.input_cursor
                            else
                                first_word + first_non_word;

                            eraseInputAndUpdateCursor(
                                &self.input_buffer,
                                self.input_cursor,
                                &self.input_end,
                                end,
                            );

                            break :b true;
                        }
                    },
                    // M-f
                    0x66 => {
                        if (self.input_cursor < self.input_end) {
                            const old_cursor = self.input_cursor;

                            const first_non_word = std.mem.indexOfAny(
                                u8,
                                self.input_buffer[self.input_cursor..self.input_end],
                                &NON_WORD_CHARS,
                            ) orelse self.input_end -| self.input_cursor;

                            self.input_cursor +|= @intCast(first_non_word);

                            const first_word = std.mem.indexOfNone(
                                u8,
                                self.input_buffer[self.input_cursor..self.input_end],
                                &NON_WORD_CHARS,
                            ) orelse self.input_end -| self.input_cursor;

                            self.input_cursor +|= @intCast(first_word);

                            cursorRight(self.input_cursor -| old_cursor);

                            break :b true;
                        }
                    },
                    else => {},
                }

                break :b false;
            },
            else => b: {
                std.log.debug("unknown input character 0x{x}", .{char});
                break :b false;
            },
        };

        if (needs_flush) {
            flush();
        }

        if (done) {
            const input = self.input_buffer[0..self.input_end];

            self.input_cursor = 0;
            self.input_end = 0;

            if (input.len > 0) {
                // Caller responsible for spawning new prompt when done
                // printing to screen.
                return input;
            } else {
                self.prompt(context);
            }
        }

        return null;
    }

    const History = struct {
        const size = 10;

        index: ?usize = null,

        items: [size]?[]const u8 = [_]?[]const u8{null} ** size,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.items) |item| {
                if (item) |item_| {
                    allocator.free(item_);
                }
            }
        }

        pub fn resetIndex(self: *@This()) void {
            self.index = null;
        }

        pub fn push(
            self: *@This(),
            value: []const u8,
            allocator: std.mem.Allocator,
        ) !void {
            for (1..self.items.len) |i| {
                const index = self.items.len - i;

                const old = self.items[index];
                const new = self.items[index - 1];

                // free the last element
                if (index == self.items.len - 1) {
                    if (old) |old_| {
                        allocator.free(old_);
                    }
                }

                self.items[index] = new;
            }

            // set new first item
            self.items[0] = try allocator.dupe(u8, value);
            self.resetIndex();
        }

        pub fn prev(self: *@This()) ?[]const u8 {
            const new_index = if (self.index) |index| index +| 1 else 0;

            if (new_index >= size) {
                return null;
            }

            std.debug.assert(new_index < size);
            if (self.items[new_index]) |item| {
                self.index = new_index;
                return item;
            }

            return null;
        }

        pub fn next(self: *@This()) ?[]const u8 {
            const new_index = (self.index orelse return null) -| 1;

            if (self.index == 0) {
                self.resetIndex();
                return null;
            }

            std.debug.assert(new_index < size);
            if (self.items[new_index]) |item| {
                self.index = new_index;
                return item;
            }

            return null;
        }
    };
};

test "shell history" {
    var history = Shell.History{};
    defer history.deinit(std.testing.allocator);

    try std.testing.expect(history.prev() == null);
    try std.testing.expect(history.next() == null);
    history.push("foo", std.testing.allocator) catch unreachable;
    try std.testing.expectEqualStrings("foo", history.prev() orelse unreachable);
    try std.testing.expect(history.prev() == null);
    history.push("bar", std.testing.allocator) catch unreachable;
    try std.testing.expectEqualStrings("bar", history.prev() orelse unreachable);
    try std.testing.expectEqualStrings("foo", history.prev() orelse unreachable);
    try std.testing.expectEqualStrings("bar", history.next() orelse unreachable);
    try std.testing.expect(history.next() == null);
}

arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
context: ?*BootLoader = null,
resize_signal: posix.fd_t,
shell: Shell = .{},
tty: ?system.Tty = null,

pub fn init() !Console {
    // Turn off local echo, making the ENTER key the only thing that shows a
    // sign of user input.
    {
        _ = try system.setupTty(IN, .no_echo);
        writeAllAndFlush("\npress ENTER to interrupt\n\n");
    }

    var mask = std.mem.zeroes(posix.sigset_t);
    std.os.linux.sigaddset(&mask, posix.SIG.WINCH);
    posix.sigprocmask(posix.SIG.BLOCK, &mask, null);

    const resize_signal = try posix.signalfd(-1, &mask, 0);

    return .{
        .resize_signal = resize_signal,
    };
}

fn flush() void {
    out.flush() catch {};
}

/// Flushes occur transparently. Do not use if control over when flushes occur
/// is needed.
fn print(comptime fmt: []const u8, args: anytype) void {
    out.writer().print(fmt, args) catch {};
}

fn writeAll(bytes: []const u8) void {
    out.writer().writeAll(bytes) catch {};
}

fn writeAllAndFlush(bytes: []const u8) void {
    writeAll(bytes);
    flush();
}

/// Assumes cursor is already located at `start`.
fn eraseInputAndUpdateCursor(input: []u8, start: usize, end: *usize, n: usize) void {
    std.mem.copyForwards(
        u8,
        input[start..end.* -| n],
        input[start +| n..end.*],
    );
    end.* -|= n;
    cursorLeft(start);
    writeAll(input[0..end.*]);
    eraseToEndOfLine();
    cursorLeft(end.* -| start);
}

/// Caller required to flush
fn cursorLeft(n: usize) void {
    if (n > 0) {
        out.writer().print(.{esc} ++ "[{d:0>5}D", .{n}) catch {};
    }
}

/// Caller required to flush
fn cursorRight(n: usize) void {
    if (n > 0) {
        out.writer().print(.{esc} ++ "[{d}C", .{n}) catch {};
    }
}

/// Caller required to flush
fn eraseToEndOfLine() void {
    out.writer().writeAll(.{esc} ++ "[0K") catch {};
}

/// Caller required to flush
fn eraseToCursor() void {
    out.writer().writeAll(.{esc} ++ "[1K") catch {};
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

    self.shell.deinit();

    if (self.tty) |*tty| {
        tty.reset();
    }

    posix.close(self.resize_signal);
}

pub fn handleResize(self: *Console) void {
    writeAll("\n");
    self.shell.prompt(self.context);
}

pub fn handleStdin(self: *Console, boot_loaders: []*BootLoader) !?Event {
    // We may already have a prompt from a boot timeout, so don't print
    // a prompt if we already have one.
    if (self.tty == null) {
        self.tty = try system.setupTty(IN, .user_input);
        self.shell.prompt(self.context);
    }

    const maybe_input = try self.shell.handleInput(self.context);

    if (maybe_input) |user_input| {
        defer {
            if (self.context == null) {
                _ = self.arena.reset(.retain_capacity);
            }
        }

        var args = try ArgsIterator.init(self.arena.allocator(), user_input);
        defer args.deinit();

        if (self.runCommand(&args, boot_loaders)) |maybe_event| {
            if (maybe_event) |event| {
                return event;
            }
        } else |err| {
            print("\nerror running command: {}\n", .{err});
        }

        self.shell.prompt(self.context);
        try self.shell.history.push(user_input, self.shell.arena.allocator());
    }

    return null;
}

pub fn format(
    self: Console,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    try writer.print(
        "input_cursor={}" ++ "\n" ++ "input_end={}" ++ "\n" ++ "input_buffer={any}",
        .{
            self.input_cursor,
            self.input_end,
            self.input_buffer[0..self.input_end],
        },
    );
}

fn runCommand(
    self: *Console,
    args: *ArgsIterator,
    boot_loaders: []*BootLoader,
) !?Event {
    if (args.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "help")) {
            return Command.help.run(self, args, boot_loaders);
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

        print("\nunknown command \"{s}\"\n", .{cmd});
    }

    return null;
}

pub const Command = struct {
    const NoContext = enum {
        autoboot,
        clear,
        history,
        list,
        logs,
        poweroff,
        reboot,
        select,
    };

    const Context = enum {
        boot,
        exit,
        probe,
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

        fn run(console: *Console, args: *ArgsIterator, _: []*BootLoader) !?Event {
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

        fn run(_: *Console, _: *ArgsIterator, _: []*BootLoader) !?Event {
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

        fn run(_: *Console, _: *ArgsIterator, _: []*BootLoader) !?Event {
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

        fn run(console: *Console, args: *ArgsIterator, _: []*BootLoader) !?Event {
            var filter = if (args.next()) |filter_str|
                try std.fmt.parseInt(usize, filter_str, 10)
            else
                6;

            if (filter > std.math.maxInt(u3)) {
                filter = std.math.maxInt(u3);
            }

            try system.printKernelLogs(
                console.arena.allocator(),
                @intCast(filter),
                out.writer().any(),
            );

            return null;
        }
    };

    const history = struct {
        const short_help = "show shell history";
        const long_help =
            \\Show shell history.
            \\
            \\Usage:
            \\history
        ;

        fn run(console: *Console, _: *ArgsIterator, _: []*BootLoader) !?Event {
            writeAll("\n");
            const len = console.shell.history.items.len;
            for (0..len) |i| {
                const index = len - 1 - i;
                const item = console.shell.history.items[index];
                if (item) |item_| {
                    print("{d:0>2} {s}\n", .{ index, item_ });
                }
            }

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

        fn run(_: *Console, _: *ArgsIterator, _: []*BootLoader) !?Event {
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
            \\select <selection-parameter>
            \\
            \\Where the selection parameter can either be the boot loader index
            \\or the device's major & minor numbers (in the form "major:minor").
            \\
            \\Example:
            \\select 2          Selects the second boot loader in the list
            \\
            \\select 8:1        Selects the boot loader attached to device 8:1
        ;

        fn run(console: *Console, args: *ArgsIterator, boot_loaders: []*BootLoader) !?Event {
            const select_arg = args.next() orelse return error.InvalidArgument;

            var split = std.mem.splitScalar(u8, select_arg, ':');
            const first = split.next() orelse return error.InvalidArgument;
            const second = split.next();

            if (second) |minor_str| {
                const major = try std.fmt.parseInt(u32, first, 10);
                const minor = try std.fmt.parseInt(u32, minor_str, 10);

                for (boot_loaders) |boot_loader| {
                    switch (boot_loader.device.type) {
                        .node => |node| {
                            const have_major, const have_minor = node;
                            if (have_major == major and have_minor == minor) {
                                console.context = boot_loader;
                                print(
                                    "selected boot loader: {s} ({})\n",
                                    .{ boot_loader.name(), boot_loader.device },
                                );
                                return null;
                            }
                        },
                        .ifindex => continue,
                    }
                }
            } else {
                const want_index = try std.fmt.parseInt(usize, first, 10);

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
            }

            return error.NotFound;
        }
    };

    const list = struct {
        const short_help = "list boot loaders";
        const long_help =
            \\List all known boot loaders.
            \\
            \\Usage:
            \\list
        ;

        fn run(_: *Console, _: *ArgsIterator, boot_loaders: []*BootLoader) !?Event {
            writeAll("\n");

            for (boot_loaders, 0..) |bl, index| {
                print(
                    "{d}\t{s}\t{}{s}\n",
                    .{
                        index,
                        bl.name(),
                        bl.device,
                        if (bl.autoboot) "\tautoboot" else "",
                    },
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
                        print("failed to load entry: {}\n", .{err});
                        return null;
                    }
                }
            }

            return error.NotFound;
        }
    };

    const autoboot = struct {
        const short_help = "autoboot from all bootloaders";
        const long_help =
            \\Autoboot from all bootloaders currently available. Bootloaders
            \\that don't support autobooting will be skipped.
            \\
            \\Usage:
            \\autoboot
        ;

        fn run(_: *Console, _: *ArgsIterator, boot_loaders: []*BootLoader) !?Event {
            for (boot_loaders) |bl| {
                if (bl.autoboot) {
                    const entries = bl.probe() catch |err| {
                        std.log.err(
                            "failed to probe {}: {}",
                            .{ bl.device, err },
                        );
                        continue;
                    };

                    for (entries) |entry| {
                        if (bl.load(entry)) {
                            break;
                        } else |err| {
                            std.log.err(
                                "failed to probe {}: {}",
                                .{ bl.device, err },
                            );
                        }
                    }
                }
            }
            return null;
        }
    };
};
