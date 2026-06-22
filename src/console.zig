const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const process = std.process;

const BootLoader = @import("./boot/bootloader.zig");
const Fdt = @import("./fdt.zig");
const LiveUpdate = @import("./liveupdate.zig");
const system = @import("./system.zig");
const utils = @import("./utils.zig");

const ack = std.ascii.control_code.ack;
const bel = std.ascii.control_code.bel;
const bs = std.ascii.control_code.bs;
const cr = std.ascii.control_code.cr;
const dc2 = std.ascii.control_code.dc2;
const dc4 = std.ascii.control_code.dc4;
const del = std.ascii.control_code.del;
const dle = std.ascii.control_code.dle;
const enq = std.ascii.control_code.enq;
const eot = std.ascii.control_code.eot;
const esc = std.ascii.control_code.esc;
const etb = std.ascii.control_code.etb;
const etx = std.ascii.control_code.etx;
const ff = std.ascii.control_code.ff;
const ht = std.ascii.control_code.ht;
const lf = std.ascii.control_code.lf;
const nak = std.ascii.control_code.nak;
const so = std.ascii.control_code.so;
const soh = std.ascii.control_code.soh;
const stx = std.ascii.control_code.stx;
const vt = std.ascii.control_code.vt;

const ArgsIterator = process.Args.IteratorGeneral(.{});

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

const stdout: std.Io.File = .stdout();
const stdin: std.Io.File = .stdin();

const Shell = struct {
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    input_cursor: usize = 0,
    input_end: usize = 0,
    in_buf: [1]u8,
    in: std.Io.File.Reader,
    out_buf: [1024]u8,
    out: std.Io.File.Writer,
    input_buffer: [std.math.maxInt(u9)]u8 = undefined,
    history: History = .{},

    pub fn deinit(self: *@This()) void {
        defer self.arena.deinit();

        self.history.deinit(self.arena.allocator());
    }

    fn flush(self: *Shell) void {
        self.out.interface.flush() catch {};
    }

    /// Flushes occur transparently. Do not use if control over when flushes occur
    /// is needed.
    fn print(self: *Shell, comptime fmt: []const u8, args: anytype) void {
        self.out.interface.print(fmt, args) catch {};
    }

    fn writeAll(self: *Shell, bytes: []const u8) void {
        self.out.interface.writeAll(bytes) catch {};
    }

    fn writeAllAndFlush(self: *Shell, bytes: []const u8) void {
        self.writeAll(bytes);
        self.flush();
    }

    /// Assumes cursor is already located at `start`.
    fn eraseInputAndUpdateCursor(self: *Shell, input: []u8, start: usize, end: *usize, n: usize) void {
        std.mem.copyForwards(
            u8,
            input[start..end.* -| n],
            input[start +| n..end.*],
        );
        end.* -|= n;
        self.cursorLeft(start);
        self.writeAll(input[0..end.*]);
        self.eraseToEndOfLine();
        self.cursorLeft(end.* -| start);
    }

    /// Caller required to flush
    fn cursorLeft(self: *Shell, n: usize) void {
        if (n > 0) {
            self.print(.{esc} ++ "[{d:0>5}D", .{n});
        }
    }

    /// Caller required to flush
    fn cursorRight(self: *Shell, n: usize) void {
        if (n > 0) {
            self.print(.{esc} ++ "[{d}C", .{n});
        }
    }

    /// Caller required to flush
    fn eraseToEndOfLine(self: *Shell) void {
        self.writeAll(.{esc} ++ "[0K");
    }

    /// Caller required to flush
    fn eraseToCursor(self: *Shell) void {
        self.writeAll(.{esc} ++ "[1K");
    }

    /// Empties the display and moves the cursor to absolute position 0, 0.
    fn clearScreen(self: *Shell) void {
        // empties the display
        self.writeAll(.{esc} ++ "[2J");
        // moves the cursor to 0, 0
        self.writeAll(.{esc} ++ "[0;0H");
    }

    pub fn prompt(self: *@This(), context: ?*BootLoader) void {
        if (context) |ctx| {
            self.writeAll(ctx.name());
        }
        self.writeAllAndFlush("> ");
    }

    fn historyPrev(self: *@This()) bool {
        if (self.history.prev()) |prev| {
            @memcpy(self.input_buffer[0..prev.len], prev);
            const old_end = self.input_end;

            self.input_end = prev.len;
            self.input_cursor = prev.len;

            self.cursorLeft(old_end);
            self.writeAll(self.input_buffer[0..self.input_end]);
            self.eraseToEndOfLine();

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

            self.cursorLeft(old_end);
            self.writeAll(self.input_buffer[0..self.input_end]);
            self.eraseToEndOfLine();

            return true;
        } else {
            // We are back out of scrolling through history, start from
            // a clean slate.
            self.cursorLeft(self.input_end);

            self.input_end = 0;
            self.input_cursor = 0;

            self.eraseToEndOfLine();

            return true;
        }

        return false;
    }

    fn moveLeft(self: *@This()) bool {
        if (self.input_cursor > 0) {
            self.cursorLeft(1);
            self.input_cursor -|= 1;
            return true;
        }

        return false;
    }

    fn moveRight(self: *@This()) bool {
        if (self.input_cursor < self.input_end) {
            self.cursorRight(1);
            self.input_cursor +|= 1;
            return true;
        }

        return false;
    }

    pub fn handleInput(self: *@This(), context: ?*BootLoader) !?[]const u8 {
        std.debug.assert(self.input_cursor <= self.input_end);

        var done = false;

        const char = try self.in.interface.takeByte();

        const needs_flush = switch (char) {
            // C-k
            vt => b: {
                self.eraseToEndOfLine();
                self.input_end = self.input_cursor;
                break :b true;
            },
            // C-a
            soh => b: {
                if (self.input_cursor > 0) {
                    self.cursorLeft(self.input_cursor);
                    self.input_cursor = 0;
                    break :b true;
                }

                break :b false;
            },
            // C-b
            stx => self.moveLeft(),
            // C-c
            etx => b: {
                self.writeAll("\n");
                self.input_cursor = 0;
                self.input_end = 0;
                done = true;
                break :b true;
            },
            // C-d
            eot => b: {
                if (self.input_cursor < self.input_end) {
                    self.eraseInputAndUpdateCursor(&self.input_buffer, self.input_cursor, &self.input_end, 1);
                    break :b true;
                }

                break :b false;
            },
            // C-e
            enq => b: {
                if (self.input_cursor < self.input_end) {
                    self.cursorRight(self.input_end -| self.input_cursor);
                    self.input_cursor = self.input_end;
                    break :b true;
                }

                break :b false;
            },
            // C-f
            ack => self.moveRight(),
            // Bell
            bel => false,
            // C-h, Backspace
            bs, del => b: {
                if (self.input_cursor > 0) {
                    std.mem.copyForwards(
                        u8,
                        self.input_buffer[self.input_cursor -| 1..self.input_end -| 1],
                        self.input_buffer[self.input_cursor..self.input_end],
                    );
                    self.input_cursor -|= 1;
                    self.input_end -|= 1;
                    self.cursorLeft(1);
                    self.writeAll(self.input_buffer[self.input_cursor..self.input_end]);
                    self.eraseToEndOfLine();
                    self.cursorLeft(self.input_end -| self.input_cursor);
                    break :b true;
                }

                break :b false;
            },
            // Tab
            ht => false,
            // C-l
            ff => b: {
                self.clearScreen();
                self.prompt(context);
                self.writeAll(self.input_buffer[0..self.input_end]);
                self.cursorLeft(self.input_end -| self.input_cursor);
                break :b true;
            },
            // \r, \n; \n is also known as C-j
            cr, lf => b: {
                self.writeAll("\n");
                done = true;
                break :b true;
            },
            // C-n
            so => self.historyNext(),
            // C-p
            dle => self.historyPrev(),
            // C-r
            dc2 => false,
            // C-t
            dc4 => b: {
                if (0 < self.input_cursor and self.input_cursor < self.input_end) {
                    std.mem.swap(
                        u8,
                        &self.input_buffer[self.input_cursor -| 1],
                        &self.input_buffer[self.input_cursor],
                    );
                    self.cursorLeft(1);
                    self.input_cursor +|= 1;
                    self.writeAll(self.input_buffer[self.input_cursor -| 2..self.input_cursor]);
                    break :b true;
                }

                break :b false;
            },
            // C-u
            nak => b: {
                if (self.input_cursor > 0) {
                    self.cursorLeft(self.input_cursor);
                    self.writeAll(self.input_buffer[self.input_cursor..self.input_end]);
                    self.eraseToEndOfLine();
                    self.input_end = self.input_end -| self.input_cursor;
                    self.input_cursor = 0;
                    self.cursorLeft(self.input_end);
                    break :b true;
                }

                break :b false;
            },
            // C-w
            etb => b: {
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

                    self.cursorLeft(old_cursor - self.input_cursor);
                    self.eraseInputAndUpdateCursor(
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
                    self.print("\n{}\n", .{self});
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
                    self.writeAll(self.input_buffer[self.input_cursor..self.input_end]);
                    self.input_cursor +|= 1;
                    self.cursorLeft(self.input_end -| self.input_cursor);
                    break :b true;
                }

                break :b false;
            },
            // Escape sequence
            esc => b: {
                switch (try self.in.interface.takeByte()) {
                    0x5b => {
                        switch (try self.in.interface.takeByte()) {
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

                            self.cursorLeft(old_cursor -| self.input_cursor);

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

                            self.eraseInputAndUpdateCursor(
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

                            self.cursorRight(self.input_cursor -| old_cursor);

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
            self.flush();
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
shell: Shell,
tty: system.Tty,

pub fn init(io: std.Io) !Console {
    // Turn off local echo, making the ENTER key the only thing that shows a
    // sign of user input.
    var tty = system.Tty.init(std.Io.File.stdin());
    try tty.setMode(.no_echo);

    var in_buf: [1]u8 = undefined;
    var out_buf: [1024]u8 = undefined;
    var shell: Shell = .{
        .in_buf = in_buf,
        .in = stdin.reader(io, &in_buf),
        .out_buf = out_buf,
        .out = stdout.writer(io, &out_buf),
    };
    shell.writeAllAndFlush("\npress ENTER to interrupt\n\n");

    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, posix.SIG.WINCH);
    posix.sigprocmask(posix.SIG.BLOCK, &mask, null);

    const resize_signal = try posix.signalfd(-1, &mask, 0);

    return .{
        .shell = shell,
        .resize_signal = resize_signal,
        .tty = tty,
    };
}

pub fn prompt(self: *Console) void {
    self.shell.prompt(self.context);
}

pub fn deinit(self: *Console) void {
    defer self.arena.deinit();

    self.shell.deinit();

    self.tty.deinit();

    _ = linux.close(self.resize_signal);
}

pub fn handleResize(self: *Console) void {
    self.shell.writeAll("\n");
    self.prompt();
}

pub fn handleStdin(self: *Console, io: std.Io, boot_loaders: []*BootLoader, liveupdate: *LiveUpdate) !?Event {
    const maybe_input = try self.shell.handleInput(self.context);

    if (maybe_input) |user_input| {
        defer {
            if (self.context == null) {
                _ = self.arena.reset(.retain_capacity);
            }
        }

        var args = try ArgsIterator.init(self.arena.allocator(), user_input);
        defer args.deinit();

        if (self.runCommand(io, &args, boot_loaders, liveupdate)) |maybe_event| {
            if (maybe_event) |event| {
                return event;
            }
        } else |err| {
            self.shell.print("\nerror running command: {}\n", .{err});
        }

        self.prompt();
        try self.shell.history.push(user_input, self.shell.arena.allocator());
    }

    return null;
}

pub fn format(
    self: Console,
    writer: *std.Io.Writer,
) !void {
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
    io: std.Io,
    args: *ArgsIterator,
    boot_loaders: []*BootLoader,
    liveupdate: *LiveUpdate,
) !?Event {
    if (args.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "help")) {
            return Command.help.run(self, io, args, boot_loaders, liveupdate);
        }

        if (self.context) |ctx| {
            inline for (std.meta.fields(Command.Context)) |field| {
                if (std.mem.eql(u8, field.name, cmd)) {
                    return @field(Command, field.name).run(
                        self,
                        io,
                        args,
                        ctx,
                        liveupdate,
                    );
                }
            }
        } else {
            inline for (std.meta.fields(Command.NoContext)) |field| {
                if (std.mem.eql(u8, field.name, cmd)) {
                    return @field(Command, field.name).run(
                        self,
                        io,
                        args,
                        boot_loaders,
                        liveupdate,
                    );
                }
            }
        }

        self.shell.print("\nunknown command \"{s}\"\n", .{cmd});
    }

    return null;
}

pub const Command = struct {
    const NoContext = enum {
        autoboot,
        clear,
        fdt,
        history,
        info,
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
        fn helpAll(shell: *Shell, t: anytype) void {
            shell.print("\n", .{});

            inline for (std.meta.fields(t)) |field| {
                const cmd_short_help = comptime @field(Command, field.name).short_help;
                const space = 20 - comptime field.name.len;
                shell.print("{s}{s}{s}\n", .{ field.name, " " ** space, cmd_short_help });
            }
        }

        /// Prints a help message for a single command.
        fn helpOne(shell: *Shell, t: anytype, cmd: []const u8) void {
            if (std.mem.eql(u8, cmd, "help")) {
                const cmd_long_help = comptime @field(Command, "help").long_help;
                shell.print("\n{s}\n", .{cmd_long_help});
                return;
            }

            inline for (std.meta.fields(t)) |field| {
                if (std.mem.eql(u8, field.name, cmd)) {
                    const cmd_long_help = comptime @field(Command, field.name).long_help;
                    shell.print("\n{s}\n", .{cmd_long_help});
                    return;
                }
            }

            shell.print("unknown command \"{s}\"\n", .{cmd});
        }

        fn run(console: *Console, _: std.Io, args: *ArgsIterator, _: []*BootLoader, _: *LiveUpdate) !?Event {
            if (args.next()) |cmd| {
                if (console.context == null) {
                    helpOne(&console.shell, NoContext, cmd);
                } else {
                    helpOne(&console.shell, Context, cmd);
                }
            } else {
                if (console.context == null) {
                    helpAll(&console.shell, NoContext);
                } else {
                    helpAll(&console.shell, Context);
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

        fn run(_: *Console, _: std.Io, _: *ArgsIterator, _: []*BootLoader, _: *LiveUpdate) !?Event {
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

        fn run(_: *Console, _: std.Io, _: *ArgsIterator, _: []*BootLoader, _: *LiveUpdate) !?Event {
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

        fn run(console: *Console, _: std.Io, args: *ArgsIterator, _: []*BootLoader, _: *LiveUpdate) !?Event {
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
                &console.shell.out.interface,
            );

            return null;
        }
    };

    const fdt = struct {
        const short_help = "show flattened devicetree";
        const long_help =
            \\Show flattened devicetree. Unavailable on ACPI platforms.
            \\
            \\Usage:
            \\fdt
        ;

        fn run(console: *Console, io: std.Io, _: *ArgsIterator, _: []*BootLoader, _: *LiveUpdate) !?Event {
            const sys_firmware_fdt = std.Io.Dir.cwd().openFile(io, "/sys/firmware/fdt", .{}) catch {
                console.shell.writeAll("FDT not found\n");
                return null;
            };
            defer sys_firmware_fdt.close(io);

            var buffer: [1024]u8 = undefined;
            var reader = sys_firmware_fdt.reader(io, &buffer);
            var fdt_ = try Fdt.init(&reader.interface, console.arena.allocator());
            defer fdt_.deinit();

            var node = fdt_.dt_struct.first orelse return error.InvalidFdt;

            var depth: usize = 0;

            while (true) {
                const node_data: *Fdt.Node = @fieldParentPtr("inner", node);
                switch (node_data.token) {
                    .Nop => {},
                    .BeginNode => |node_name| {
                        if (node_name.len != 0) {
                            if (depth == 0) {
                                try console.shell.out.interface.writeByte('\n');
                            }
                            try console.shell.out.interface.splatByteAll('\t', depth);
                            try console.shell.out.interface.print("{s}:\n", .{node_name});

                            depth += 1;
                        }
                    },
                    .EndNode => {
                        depth -%= 1;
                    },
                    .End => break,
                    .Prop => |prop| {
                        const prop_name = try fdt_.getString(prop.inner.name_offset);
                        try console.shell.out.interface.splatByteAll('\t', depth);
                        try console.shell.out.interface.print("{s}=", .{prop_name});
                        try Fdt.printValue(&console.shell.out.interface, prop.value);
                        try console.shell.out.interface.print("\n", .{});
                    },
                }

                node = node.next orelse return error.InvalidFdt;
            }

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

        fn run(console: *Console, _: std.Io, _: *ArgsIterator, _: []*BootLoader, _: *LiveUpdate) !?Event {
            console.shell.writeAll("\n");
            const len = console.shell.history.items.len;
            for (0..len) |i| {
                const index = len - 1 - i;
                const item = console.shell.history.items[index];
                if (item) |item_| {
                    console.shell.print("{d:0>2} {s}\n", .{ index, item_ });
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

        fn run(console: *Console, _: std.Io, _: *ArgsIterator, _: []*BootLoader, _: *LiveUpdate) !?Event {
            console.shell.clearScreen();

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

        fn run(console: *Console, _: std.Io, args: *ArgsIterator, boot_loaders: []*BootLoader, _: *LiveUpdate) !?Event {
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
                                console.shell.print(
                                    "selected boot loader: {s} ({f})\n",
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
                        console.shell.print(
                            "selected boot loader: {s} ({f})\n",
                            .{ boot_loader.name(), boot_loader.device },
                        );
                        return null;
                    }
                }
            }

            return error.NotFound;
        }
    };

    const info = struct {
        const short_help = "show machine info";
        const long_help =
            \\Show machine info.
            \\
            \\Usage:
            \\info
        ;

        fn run(console: *Console, io: std.Io, args: *ArgsIterator, boot_loaders: []*BootLoader, _: *LiveUpdate) !?Event {
            _ = args;
            _ = boot_loaders;

            try utils.dumpFile(io, std.Io.Dir.cwd(), &console.shell.out.interface, "/proc/version");

            console.shell.print("\nInit:\n", .{});
            try utils.dumpFile(io, std.Io.Dir.cwd(), &console.shell.out.interface, "/proc/1/stat");

            console.shell.print("\nConsoles:\n", .{});
            utils.dumpFile(io, std.Io.Dir.cwd(), &console.shell.out.interface, "/proc/consoles") catch {
                console.shell.print("?\n", .{});
            };

            console.shell.print("\nMemory:\n", .{});
            utils.dumpFile(io, std.Io.Dir.cwd(), &console.shell.out.interface, "/proc/meminfo") catch {
                console.shell.print("?\n", .{});
            };

            // According to https://github.com/torvalds/linux/blob/aef17cb3d3c43854002956f24c24ec8e1a0e3546/Documentation/admin-guide/devices.txt,
            // the first TPM will be at major number 10, minor number 224, and
            // since the minor numbers are incremented for each following
            // device, we have at least one TPM if this path exists.
            console.shell.print("\nTPM: ", .{});
            if (utils.absolutePathExists(io, "/dev/char/10:224")) {
                console.shell.print("yes\n", .{});
                var pcr_sha256_dir = try std.Io.Dir.cwd().openDir(io, "/sys/class/tpm/tpm0/pcr-sha256", .{});
                defer pcr_sha256_dir.close(io);
                for (0..24) |pcr| {
                    console.shell.print("\tPCR{d}: ", .{pcr});
                    utils.dumpFile(io, pcr_sha256_dir, &console.shell.out.interface, &.{'0' + @as(u8, @intCast(pcr))}) catch {
                        console.shell.print("n/a\n", .{});
                    };
                }
            } else {
                console.shell.print("no\n", .{});
            }

            console.shell.print("\nKeys:\n", .{});
            utils.dumpFile(io, std.Io.Dir.cwd(), &console.shell.out.interface, "/proc/keys") catch {
                console.shell.print("?\n", .{});
            };

            console.shell.print("\nIMA policy:\n", .{});
            utils.dumpFile(io, std.Io.Dir.cwd(), &console.shell.out.interface, "/sys/kernel/security/integrity/ima/policy") catch {
                console.shell.print("n/a\n", .{});
            };

            console.shell.print("\nIMA measurements:\n", .{});
            utils.dumpFile(io, std.Io.Dir.cwd(), &console.shell.out.interface, "/sys/kernel/security/integrity/ima/ascii_runtime_measurements") catch {
                console.shell.print("n/a\n", .{});
            };

            console.shell.print("\nMTD:\n", .{});
            utils.dumpFile(io, std.Io.Dir.cwd(), &console.shell.out.interface, "/proc/mtd") catch {
                console.shell.print("?\n", .{});
            };

            console.shell.print("\nPartitions:\n", .{});
            utils.dumpFile(io, std.Io.Dir.cwd(), &console.shell.out.interface, "/proc/partitions") catch {
                console.shell.print("?\n", .{});
            };

            console.shell.flush();

            return null;
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

        fn run(console: *Console, _: std.Io, _: *ArgsIterator, boot_loaders: []*BootLoader, _: *LiveUpdate) !?Event {
            console.shell.writeAll("\n");

            for (boot_loaders, 0..) |bl, index| {
                console.shell.print(
                    "{d}\t{s}\t{f}{s}\n",
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

        fn run(console: *Console, _: std.Io, _: *ArgsIterator, _: *BootLoader, _: *LiveUpdate) !?Event {
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

        fn run(console: *Console, io: std.Io, _: *ArgsIterator, boot_loader: *BootLoader, _: *LiveUpdate) !?Event {
            const entries = boot_loader.probe(io) catch |err| {
                console.shell.print("failed to probe: {}\n", .{err});
                return null;
            };

            console.shell.writeAll("\n");

            for (entries, 0..) |entry, index| {
                console.shell.print("{d}\n\tlinux={s}\n\tinitrd={?s}\n\tcmdline=\"{s}\"\n", .{
                    index,
                    entry.linux,
                    entry.initrd,
                    if (entry.cmdline) |cmdline| cmdline else "",
                });
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

        fn run(console: *Console, io: std.Io, args: *ArgsIterator, boot_loader: *BootLoader, liveupdate: *LiveUpdate) !?Event {
            const want_index = try std.fmt.parseInt(
                usize,
                args.next() orelse "0",
                10,
            );

            const entries = boot_loader.probe(io) catch |err| {
                console.shell.print("failed to probe: {}\n", .{err});
                return null;
            };

            for (entries, 0..) |entry, index| {
                if (want_index == index) {
                    if (boot_loader.load(io, entry, liveupdate)) {
                        console.shell.print(
                            "selected entry:\n\tlinux={s}\n\tinitrd={?s}\n\tcmdline=\"{s}\"\n",
                            .{ entry.linux, entry.initrd, if (entry.cmdline) |cmdline| cmdline else "" },
                        );

                        return .kexec;
                    } else |err| {
                        console.shell.print("failed to load entry: {}\n", .{err});
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

        fn run(_: *Console, io: std.Io, _: *ArgsIterator, boot_loaders: []*BootLoader, liveupdate: *LiveUpdate) !?Event {
            for (boot_loaders) |bl| {
                if (bl.autoboot) {
                    const entries = bl.probe(io) catch |err| {
                        std.log.err("failed to probe {f}: {}", .{ bl.device, err });
                        continue;
                    };

                    for (entries) |entry| {
                        if (bl.load(io, entry, liveupdate)) {
                            return .kexec;
                        } else |err| {
                            std.log.err("failed to probe {f}: {}", .{ bl.device, err });
                        }
                    }
                }
            }

            return null;
        }
    };
};
