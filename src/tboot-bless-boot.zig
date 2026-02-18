const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap");

pub const std_options = std.Options{ .log_level = if (builtin.mode == .Debug) .debug else .info };

const DiskBootLoader = @import("./boot/disk.zig");
const LiveUpdate = @import("./liveupdate.zig");

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
    var stdout_file = std.fs.File.stdout();
    var buf = [_]u8{0} ** 1024;
    var stdout_writer = stdout_file.writer(&buf);
    var writer = &stdout_writer.interface;
    defer writer.flush() catch {};

    try writer.print("{s}:\n", .{original_entry_filename});

    if (bls_entry_file.tries_left) |tries_left| {
        if (tries_left > 0) {
            try writer.print("\t{} tries left until entry is bad\n", .{tries_left});
        } else if (bls_entry_file.tries_done) |tries_done| {
            try writer.print("\tentry is bad, {} tries attempted\n", .{tries_done});
        } else {
            try writer.print("\tentry is bad\n", .{});
        }

        if (bls_entry_file.tries_done) |tries_done| {
            try writer.print("\t{} tries done\n", .{tries_done});
        }
    } else {
        try writer.print("\tentry is good\n", .{});
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

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, &parsers, .{
        .diagnostic = &diag,
        .allocator = arena.allocator(),
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        try clap.usageToFile(.stderr(), clap.Help, &params);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(.stderr(), clap.Help, &params, .{});
    }

    const esp_mnt = res.args.@"esp-mnt" orelse std.fs.path.sep_str ++ "boot";
    const action = if (res.positionals[0]) |action| try Action.fromStr(action) else Action.status;

    var liveupdate = try LiveUpdate.init(.retrieve);
    defer liveupdate.deinit();

    const memfd = try liveupdate.retrieve(DiskBootLoader.luo_entry_token);
    defer std.posix.close(memfd);

    try std.posix.lseek_SET(memfd, 0);

    var buf: [1024]u8 = undefined;
    const read = try std.posix.read(memfd, &buf);
    const tboot_bls_entry = buf[0..read];

    try findEntry(
        allocator,
        esp_mnt,
        tboot_bls_entry,
        action,
    );
}
