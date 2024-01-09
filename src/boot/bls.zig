const std = @import("std");

pub const BootLoaderSpec = struct {
    pub fn setup(self: *@This()) !void {
        _ = self;
    }

    pub fn probe(self: *@This()) void {
        _ = self;
    }

    pub fn teardown(self: *@This()) void {
        _ = self;
    }
};

pub const EntryFilename = struct {
    name: []const u8,
    tries_left: ?u8 = null,
    tries_done: ?u8 = null,

    const Error = error{
        MissingSuffix,
        InvalidTriesSyntax,
    };

    pub fn parse(contents: []const u8) @This().Error!@This() {
        const filename_wo_suffix = std.mem.trimRight(u8, contents, ".conf");
        if (contents.len == filename_wo_suffix.len) {
            return Error.MissingSuffix;
        }

        var plus_split = std.mem.splitSequence(u8, filename_wo_suffix, "+");

        // stdlib says it will always return at least `buffer`
        const name = plus_split.next().?;

        if (plus_split.next()) |counter_info| {
            var minus_split = std.mem.splitSequence(u8, counter_info, "-");

            const plus_info = minus_split.next().?;
            const tries_done = std.fmt.parseInt(u8, plus_info, 10) catch {
                return Error.InvalidTriesSyntax;
            };

            if (minus_split.next()) |minus_info| {
                const tries_left = std.fmt.parseInt(u8, minus_info, 10) catch {
                    return Error.InvalidTriesSyntax;
                };
                return .{ .name = name, .tries_done = tries_done, .tries_left = tries_left };
            } else {
                return .{ .name = name, .tries_done = tries_done };
            }
        } else {
            return .{ .name = name };
        }
    }
};

test "entry filename parsing" {
    try std.testing.expectError(
        EntryFilename.Error.MissingSuffix,
        EntryFilename.parse("my-entry"),
    );

    try std.testing.expectError(
        EntryFilename.Error.InvalidTriesSyntax,
        EntryFilename.parse("my-entry+foo.conf"),
    );

    try std.testing.expectError(
        EntryFilename.Error.InvalidTriesSyntax,
        EntryFilename.parse("my-entry+foo-bar.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry" },
        EntryFilename.parse("my-entry.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry-1" },
        EntryFilename.parse("my-entry-1.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry", .tries_done = 1 },
        EntryFilename.parse("my-entry+1.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry", .tries_done = 0 },
        EntryFilename.parse("my-entry+0.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry", .tries_done = 0, .tries_left = 3 },
        EntryFilename.parse("my-entry+0-3.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry-1", .tries_done = 5, .tries_left = 0 },
        EntryFilename.parse("my-entry-1+5-0.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry-2", .tries_done = 3, .tries_left = 1 },
        EntryFilename.parse("my-entry-2+3-1.conf"),
    );

    try std.testing.expectEqualDeep(
        .{ .name = "my-entry-3", .tries_done = 2 },
        EntryFilename.parse("my-entry-3+2.conf"),
    );
}

const ConsoleMode = enum {
    Zero,
    One,
    Two,
    Auto,
    Max,
    Keep,

    fn parse(contents: []const u8) ?@This() {
        if (std.mem.eql(u8, contents, "0")) {
            return .Zero;
        } else if (std.mem.eql(u8, contents, "1")) {
            return .One;
        } else if (std.mem.eql(u8, contents, "2")) {
            return .Two;
        } else if (std.mem.eql(u8, contents, "auto")) {
            return .Auto;
        } else if (std.mem.eql(u8, contents, "max")) {
            return .Max;
        } else if (std.mem.eql(u8, contents, "keep")) {
            return .Keep;
        }
        return null;
    }
};

const SecureBootEnroll = enum {
    Off,
    Manual,
    IfSafe,
    Force,

    fn parse(contents: []const u8) ?@This() {
        if (std.mem.eql(u8, contents, "off")) {
            return .Off;
        } else if (std.mem.eql(u8, contents, "manual")) {
            return .Manual;
        } else if (std.mem.eql(u8, contents, "if-safe")) {
            return .IfSafe;
        } else if (std.mem.eql(u8, contents, "force")) {
            return .Force;
        }
        return null;
    }
};

/// Configuration of the BootLoaderSpec, as found in `loader.conf`. See
/// https://www.freedesktop.org/software/systemd/man/latest/loader.conf.html.
const LoaderConf = struct {
    /// Glob pattern used to find the default boot entry.
    default_entry: ?[]const u8 = null,

    /// Seconds to wait before selecting the default entry.
    timeout: u8 = 0,

    console_mode: ?ConsoleMode = null,

    /// Enable or disable editing boot entries.
    editor: bool = true,

    auto_entries: bool = true,

    auto_firmware: bool = true,

    beep: bool = false,

    secure_boot_enroll: ?SecureBootEnroll = null,

    reboot_for_bitlocker: bool = false,

    //  Boolean arguments may be written as:
    //  "yes"/"y"/"true"/"t"/"on"/"1" or "no"/"n"/"false"/"f"/"off"/"0"
    fn parseBool(contents: []const u8) ?bool {
        if (std.mem.eql(u8, contents, "yes")) {
            return true;
        } else if (std.mem.eql(u8, contents, "y")) {
            return true;
        } else if (std.mem.eql(u8, contents, "true")) {
            return true;
        } else if (std.mem.eql(u8, contents, "t")) {
            return true;
        } else if (std.mem.eql(u8, contents, "on")) {
            return true;
        } else if (std.mem.eql(u8, contents, "1")) {
            return true;
        } else if (std.mem.eql(u8, contents, "no")) {
            return false;
        } else if (std.mem.eql(u8, contents, "n")) {
            return false;
        } else if (std.mem.eql(u8, contents, "false")) {
            return false;
        } else if (std.mem.eql(u8, contents, "f")) {
            return false;
        } else if (std.mem.eql(u8, contents, "off")) {
            return false;
        } else if (std.mem.eql(u8, contents, "0")) {
            return false;
        }
        return null;
    }

    fn parse(contents: []const u8) @This() {
        var self = @This(){};

        var all_split = std.mem.splitSequence(u8, contents, "\n");

        while (all_split.next()) |line| {
            if (std.mem.eql(u8, line, "")) {
                continue;
            }

            var line_split = std.mem.splitSequence(u8, line, " ");

            var maybe_key: ?[]const u8 = null;
            var maybe_value: ?[]const u8 = null;

            while (line_split.next()) |section| {
                if (std.mem.eql(u8, section, "")) {
                    continue;
                }

                if (maybe_key == null) {
                    maybe_key = section;
                } else if (maybe_value == null) {
                    maybe_value = section;
                    break;
                }
            }

            if (maybe_key == null or maybe_value == null) {
                continue;
            }

            const key = maybe_key.?;
            const value = maybe_value.?;

            if (std.mem.eql(u8, key, "default")) {
                self.default_entry = value;
            } else if (std.mem.eql(u8, key, "timeout")) {
                self.timeout = std.fmt.parseInt(u8, value, 10) catch {
                    std.log.err("invalid timeout value '{s}'", .{value});
                    continue;
                };
            } else if (std.mem.eql(u8, key, "console-mode")) {
                if (ConsoleMode.parse(value)) |final_value| {
                    self.console_mode = final_value;
                }
            } else if (std.mem.eql(u8, key, "editor")) {
                if (@This().parseBool(value)) |final_value| {
                    self.editor = final_value;
                }
            } else if (std.mem.eql(u8, key, "auto-entries")) {
                if (@This().parseBool(value)) |final_value| {
                    self.auto_entries = final_value;
                }
            } else if (std.mem.eql(u8, key, "auto-firmware")) {
                if (@This().parseBool(value)) |final_value| {
                    self.auto_firmware = final_value;
                }
            } else if (std.mem.eql(u8, key, "beep")) {
                if (@This().parseBool(value)) |final_value| {
                    self.beep = final_value;
                }
            } else if (std.mem.eql(u8, key, "secure-boot-enroll")) {
                if (SecureBootEnroll.parse(value)) |final_value| {
                    self.secure_boot_enroll = final_value;
                }
            } else if (std.mem.eql(u8, key, "reboot-for-bitlocker")) {
                if (@This().parseBool(value)) |final_value| {
                    self.reboot_for_bitlocker = final_value;
                }
            }
        }

        return self;
    }
};

test "loader.conf parsing" {
    const simple =
        \\timeout 0
        \\default 01234567890abcdef1234567890abdf0-*
        \\editor no
    ;

    try std.testing.expectEqualDeep(.{
        .timeout = 0,
        .default_entry = "01234567890abcdef1234567890abdf0-*",
        .editor = false,
    }, LoaderConf.parse(simple));
}
