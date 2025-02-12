const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap");

pub const std_options = std.Options{ .log_level = if (builtin.mode == .Debug) .debug else .info };

const DiskBootLoader = @import("./boot/disk.zig");

const BlsEntryFile = DiskBootLoader.BlsEntryFile;

const Error = error{
    InvalidAction,
    MissingBlsEntry,
};

const Action = enum {
    good,
    bad,
    status,

    pub fn fromStr(str: []const u8) !@This() {
        if (std.mem.eql(u8, str, "good")) {
            return .good;
        } else if (std.mem.eql(u8, str, "bad")) {
            return .bad;
        } else if (std.mem.eql(u8, str, "status")) {
            return .status;
        } else {
            return Error.InvalidAction;
        }
    }
};

fn markAsGood(
    allocator: std.mem.Allocator,
    parent_dir: std.fs.Dir,
    original_entry_filename: []const u8,
    bls_entry_file: BlsEntryFile,
) !void {
    if (bls_entry_file.tries_left) |tries_left| {
        _ = tries_left;

        const new_filename = try std.fmt.allocPrint(
            allocator,
            "{s}.conf",
            .{bls_entry_file.name},
        );

        try parent_dir.rename(original_entry_filename, new_filename);
    }
}

fn markAsBad(
    allocator: std.mem.Allocator,
    parent_dir: std.fs.Dir,
    original_entry_filename: []const u8,
    bls_entry_file: BlsEntryFile,
) !void {
    const new_filename = b: {
        if (bls_entry_file.tries_done) |tries_done| {
            break :b try std.fmt.allocPrint(
                allocator,
                "{s}+0-{}.conf",
                .{ bls_entry_file.name, tries_done },
            );
        } else {
            break :b try std.fmt.allocPrint(
                allocator,
                "{s}+0.conf",
                .{bls_entry_file.name},
            );
        }
    };

    try parent_dir.rename(original_entry_filename, new_filename);
}

fn printStatus(
    original_entry_filename: []const u8,
    bls_entry_file: BlsEntryFile,
) !void {
    var stdout = std.io.getStdOut().writer();

    try stdout.print("{s}:\n", .{original_entry_filename});

    if (bls_entry_file.tries_left) |tries_left| {
        if (tries_left > 0) {
            try stdout.print("\t{} tries left until entry is bad\n", .{tries_left});
        } else if (bls_entry_file.tries_done) |tries_done| {
            try stdout.print("\tentry is bad, {} tries attempted\n", .{tries_done});
        } else {
            try stdout.print("\tentry is bad\n", .{});
        }

        if (bls_entry_file.tries_done) |tries_done| {
            try stdout.print("\t{} tries done\n", .{tries_done});
        }
    } else {
        try stdout.print("\tentry is good\n", .{});
    }
}

fn findEntry(
    allocator: std.mem.Allocator,
    esp_mnt: []const u8,
    entry_name: []const u8,
    action: Action,
) !void {
    const entries_path = try std.fs.path.join(
        allocator,
        &.{ esp_mnt, "loader", "entries" },
    );

    var entries_dir = try std.fs.cwd().openDir(
        entries_path,
        .{ .iterate = true },
    );
    defer entries_dir.close();

    var iter = entries_dir.iterate();
    while (try iter.next()) |dir_entry| {
        if (dir_entry.kind != .file) {
            continue;
        }

        const bls_entry = BlsEntryFile.parse(dir_entry.name) catch |err| {
            std.log.debug(
                "failed to parse boot entry {s}: {}",
                .{ dir_entry.name, err },
            );
            continue;
        };

        if (std.mem.eql(u8, bls_entry.name, entry_name)) {
            return switch (action) {
                .good => try markAsGood(allocator, entries_dir, dir_entry.name, bls_entry),
                .bad => try markAsBad(allocator, entries_dir, dir_entry.name, bls_entry),
                .status => try printStatus(dir_entry.name, bls_entry),
            };
        }
    }

    return Error.MissingBlsEntry;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Display this help and exit.
        \\--esp-mnt <DIR>         UEFI system partition mountpoint (default /boot).
        \\<ACTION>                Action to take against current boot entry (mark as "good"/"bad", or print "status").
        \\
    );

    const parsers = comptime .{
        .ACTION = clap.parsers.string,
        .DIR = clap.parsers.string,
    };

    const stderr = std.io.getStdErr().writer();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, &parsers, .{
        .diagnostic = &diag,
        .allocator = arena.allocator(),
    }) catch |err| {
        try diag.report(stderr, err);
        try clap.usage(stderr, clap.Help, &params);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }

    const esp_mnt = res.args.@"esp-mnt" orelse std.fs.path.sep_str ++ "boot";
    const action = if (res.positionals[0]) |action| try Action.fromStr(action) else Action.status;

    const kernel_cmdline_file = try std.fs.cwd().openFile("/proc/cmdline", .{});
    defer kernel_cmdline_file.close();

    const kernel_cmdline = try kernel_cmdline_file.readToEndAlloc(allocator, 1024);

    var split = std.mem.splitScalar(u8, kernel_cmdline, ' ');
    const tboot_bls_entry = b: {
        while (split.next()) |kernel_param| {
            if (std.mem.startsWith(u8, kernel_param, "tboot.bls-entry=")) {
                var param_split = std.mem.splitScalar(u8, kernel_param, '=');
                _ = param_split.next().?;

                // /proc/cmdline contains newline at the end of the file
                break :b std.mem.trimRight(
                    u8,
                    param_split.next() orelse return Error.MissingBlsEntry,
                    "\n",
                );
            }
        }

        return Error.MissingBlsEntry;
    };

    try findEntry(
        allocator,
        esp_mnt,
        tboot_bls_entry,
        action,
    );
}
