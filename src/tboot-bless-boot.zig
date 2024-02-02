const std = @import("std");

const bls = @import("./boot/bls.zig");

const Error = error{
    MissingEfiSysMountPoint,
    MissingAction,
    InvalidAction,
    MissingBlsEntry,
};

const Action = enum {
    good,
    bad,
    status,

    pub fn from_str(str: []const u8) !@This() {
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

fn mark_as_good(
    allocator: std.mem.Allocator,
    parent_path: []const u8,
    original_entry_filename: []const u8,
    bls_entry: bls.EntryFilename,
) !void {
    if (bls_entry.tries_left) |tries_left| {
        _ = tries_left;

        const orig_fullpath = try std.fs.path.join(
            allocator,
            &.{ parent_path, original_entry_filename },
        );

        const new_filename = try std.fmt.allocPrint(
            allocator,
            "{s}.conf",
            .{bls_entry.name},
        );

        const new_fullpath = try std.fs.path.join(
            allocator,
            &.{ parent_path, new_filename },
        );

        try std.fs.renameAbsolute(orig_fullpath, new_fullpath);
    }
}

fn mark_as_bad(
    allocator: std.mem.Allocator,
    parent_path: []const u8,
    original_entry_filename: []const u8,
    bls_entry: bls.EntryFilename,
) !void {
    const orig_fullpath = try std.fs.path.join(
        allocator,
        &.{ parent_path, original_entry_filename },
    );

    const new_filename = b: {
        if (bls_entry.tries_done) |tries_done| {
            break :b try std.fmt.allocPrint(
                allocator,
                "{s}+0-{}.conf",
                .{ bls_entry.name, tries_done },
            );
        } else {
            break :b try std.fmt.allocPrint(
                allocator,
                "{s}+0.conf",
                .{bls_entry.name},
            );
        }
    };

    const new_fullpath = try std.fs.path.join(
        allocator,
        &.{ parent_path, new_filename },
    );

    try std.fs.renameAbsolute(orig_fullpath, new_fullpath);
}

fn print_status(
    allocator: std.mem.Allocator,
    parent_path: []const u8,
    original_entry_filename: []const u8,
    bls_entry: bls.EntryFilename,
) !void {
    const orig_fullpath = try std.fs.path.join(
        allocator,
        &.{ parent_path, original_entry_filename },
    );

    var stdout = std.io.getStdOut().writer();

    try stdout.print("{s}:\n", .{orig_fullpath});

    if (bls_entry.tries_left) |tries_left| {
        if (tries_left > 0) {
            try stdout.print("\t{} tries left until entry is bad\n", .{tries_left});
        } else if (bls_entry.tries_done) |tries_done| {
            try stdout.print("\tentry is bad, {} tries attempted\n", .{tries_done});
        } else {
            try stdout.print("\tentry is bad\n", .{});
        }
    } else {
        try stdout.print("\tentry is good\n", .{});
    }
}

fn find_entry(
    allocator: std.mem.Allocator,
    efi_sys_mount_point: []const u8,
    entry_name: []const u8,
    action: Action,
) !void {
    const entries_path = try std.fs.path.join(
        allocator,
        &.{ efi_sys_mount_point, "loader", "entries" },
    );

    var entries_dir = try std.fs.openIterableDirAbsolute(entries_path, .{});
    defer entries_dir.close();

    var iter = entries_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        const bls_entry = bls.EntryFilename.parse(entry.name) catch |err| {
            std.log.debug("failed to parse boot entry {s}: {}", .{ entry.name, err });
            continue;
        };

        if (std.mem.eql(u8, bls_entry.name, entry_name)) {
            switch (action) {
                .good => try mark_as_good(allocator, entries_path, entry.name, bls_entry),
                .bad => try mark_as_bad(allocator, entries_path, entry.name, bls_entry),
                .status => try print_status(allocator, entries_path, entry.name, bls_entry),
            }
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.process.args();

    _ = args.next().?; // skip argv[0]
    const efi_sys_mount_point = args.next() orelse return Error.MissingEfiSysMountPoint;
    const action = try Action.from_str(args.next() orelse return Error.MissingAction);

    const kernel_cmdline_file = try std.fs.openFileAbsolute("/proc/cmdline", .{});
    defer kernel_cmdline_file.close();

    const kernel_cmdline = try kernel_cmdline_file.readToEndAlloc(allocator, 1024);

    var split = std.mem.split(u8, kernel_cmdline, " ");
    const tboot_bls_entry = b: {
        while (split.next()) |kernel_param| {
            if (std.mem.startsWith(u8, kernel_param, "tboot.bls-entry=")) {
                var param_split = std.mem.split(u8, kernel_param, "=");
                _ = param_split.next().?;
                break :b param_split.next() orelse return Error.MissingBlsEntry;
            }
        }

        return Error.MissingBlsEntry;
    };

    try find_entry(
        allocator,
        efi_sys_mount_point,
        tboot_bls_entry,
        action,
    );
}
