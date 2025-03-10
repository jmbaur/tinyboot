const builtin = @import("builtin");
const std = @import("std");
const path = std.fs.path;
const utils = @import("./utils.zig");
const clap = @import("clap");

pub const std_options = std.Options{ .log_level = if (builtin.mode == .Debug) .debug else .info };

const DiskBootLoader = @import("./boot/disk.zig");
const signFile = @import("./tboot-sign.zig").signFile;
const BootSpecV1 = @import("./bootspec.zig").BootSpecV1;
const BootJson = @import("./bootspec.zig").BootJson;

const BlsEntryFile = DiskBootLoader.BlsEntryFile;

fn ensureFilesystemState(
    esp: std.fs.Dir,
    args: *const Args,
) !void {
    std.log.debug("ensuring filesystem state", .{});

    if (!args.dry_run) {
        try esp.makePath("EFI/nixos");
        try esp.makePath("loader/entries");
    }

    if (!utils.pathExists(esp, "loader/entries.srel")) {
        if (!args.dry_run) {
            var entries_srel_file = try esp.createFile("loader/entries.srel", .{});
            defer entries_srel_file.close();

            try entries_srel_file.writeAll("type1\n");
        }
        std.log.info("installed entries.srel", .{});
    }

    std.log.debug("filesystem state is good", .{});
}

fn installGeneration(
    arena_alloc: std.mem.Allocator,
    known_files: *StringSet,
    spec: *const BootSpecV1,
    generation: u32,
    esp: std.fs.Dir,
    args: *const Args,
) !void {
    var entry_contents_list = std.ArrayList(u8).init(arena_alloc);

    const linux_target_filename = try std.fmt.allocPrint(
        arena_alloc,
        "{s}-{s}",
        .{ path.basename(path.dirname(spec.kernel).?), path.basename(spec.kernel) },
    );

    const linux_target = try path.join(arena_alloc, &.{
        "EFI",
        "nixos",
        linux_target_filename,
    });

    const full_linux_path = try path.join(
        arena_alloc,
        &.{ args.efi_sys_mount_point, linux_target },
    );

    if (!utils.pathExists(esp, linux_target)) {
        if (!args.dry_run) {
            try signFile(
                arena_alloc,
                spec.kernel,
                full_linux_path,
                args.private_key,
                args.public_key,
            );
            std.log.info("signed {s}", .{full_linux_path});
        }
        std.log.info("installed {s}", .{full_linux_path});
    }

    try known_files.put(full_linux_path, {});

    const initrd_target = b: {
        if (spec.initrd) |initrd| {
            const initrd_target_filename = try std.fmt.allocPrint(
                arena_alloc,
                "{s}-{s}",
                .{ path.basename(path.dirname(initrd).?), path.basename(initrd) },
            );

            const initrd_target = try path.join(arena_alloc, &.{
                "EFI",
                "nixos",
                initrd_target_filename,
            });

            const full_initrd_path = try path.join(arena_alloc, &.{
                path.sep_str,
                args.efi_sys_mount_point,
                initrd_target,
            });

            if (!utils.pathExists(esp, initrd_target)) {
                if (!args.dry_run) {
                    try signFile(
                        arena_alloc,
                        initrd,
                        full_initrd_path,
                        args.private_key,
                        args.public_key,
                    );
                    std.log.info("signed {s}", .{full_initrd_path});
                }
                std.log.info("installed {s}", .{full_initrd_path});
            }

            try known_files.put(full_initrd_path, {});

            break :b initrd_target;
        } else {
            break :b null;
        }
    };

    const kernel_params_without_init = try std.mem.join(arena_alloc, " ", spec.kernel_params);

    const kernel_params = try std.fmt.allocPrint(
        arena_alloc,
        "init={s} {s}",
        .{ spec.init, kernel_params_without_init },
    );

    const sub_name = if (spec.name) |name|
        try std.fmt.allocPrint(arena_alloc, " ({s})", .{name})
    else
        try arena_alloc.alloc(u8, 0);

    try entry_contents_list.writer().print("title {s}{s}\n", .{ spec.label, sub_name });
    try entry_contents_list.writer().print("version {s}\n", .{spec.label});
    try entry_contents_list.writer().print("linux {s}\n", .{linux_target});
    if (initrd_target) |initrd_target_| {
        try entry_contents_list.writer().print("initrd {s}\n", .{initrd_target_});
    }
    try entry_contents_list.writer().print("options {s}\n", .{kernel_params});
    const entry_contents = try entry_contents_list.toOwnedSlice();

    const sub_entry_name = if (spec.name) |name|
        try std.fmt.allocPrint(arena_alloc, "-specialisation-{s}", .{name})
    else
        try arena_alloc.alloc(u8, 0);

    const entry_name = try std.fmt.allocPrint(
        arena_alloc,
        "nixos-generation-{d}{s}",
        .{ generation, sub_entry_name },
    );

    const entry_filename_with_counters = try std.fmt.allocPrint(
        arena_alloc,
        "{s}+{d}-0.conf",
        .{ entry_name, args.max_tries },
    );

    var entries_dir = try esp.openDir(
        "loader/entries",
        .{ .iterate = true },
    );
    defer entries_dir.close();

    var it = entries_dir.iterate();
    while (try it.next()) |dir_entry| {
        if (dir_entry.kind != .file) {
            continue;
        }

        const existing_entry = BlsEntryFile.parse(dir_entry.name) catch continue;

        if (std.mem.eql(u8, existing_entry.name, entry_name)) {
            std.log.debug("entry {s} already installed", .{entry_name});
            const known_entry = try path.join(arena_alloc, &.{
                path.sep_str,
                args.efi_sys_mount_point,
                "loader",
                "entries",
                dir_entry.name,
            });
            try known_files.put(known_entry, {});
            return;
        }
    }

    // TODO(jared): There doesn't appear to be a way in the zig standard
    // library to obtain the "realpath" of a filepath if the path doesn't
    // actually exist.
    const entry_path = try path.join(arena_alloc, &.{
        "loader",
        "entries",
        entry_filename_with_counters,
    });

    if (!args.dry_run) {
        var entry_file = try entries_dir.createFile(entry_filename_with_counters, .{});
        defer entry_file.close();

        try entry_file.writeAll(entry_contents);
        try known_files.put(entry_path, {});
    }

    std.log.info("installed {s}", .{entry_path});
}

fn cleanupDir(
    alloc: std.mem.Allocator,
    known_files: *StringSet,
    parent_dir: std.fs.Dir,
    dir: []const u8,
    args: *const Args,
) !void {
    var open_dir = try parent_dir.openDir(dir, .{ .iterate = true });
    defer open_dir.close();

    var it = open_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        const full_path = try path.join(alloc, &.{ path.sep_str, dir, entry.name });

        if (known_files.get(full_path) == null) {
            if (!args.dry_run) {
                try std.fs.cwd().deleteFile(full_path);
            }
            std.log.info("cleaned up {s}", .{full_path});
        }
    }
}

const StringSet = std.StringHashMap(void);

const Args = struct {
    private_key: []const u8,
    public_key: []const u8,
    efi_sys_mount_point: []const u8 = std.fs.path.sep_str ++ "boot",
    max_tries: u8 = 3,
    timeout: u8 = 5,
    default_nixos_system_closure: []const u8,
    dry_run: bool = false,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const arena_alloc = arena.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Display this help and exit.
        \\--dry-run               Don't make any modifications to the filesystem.
        \\--private-key <FILE>    Private key to sign with.
        \\--public-key  <FILE>    Public key to sign with.
        \\--esp-mnt <DIR>         UEFI system partition mountpoint (default /boot).
        \\--max-tries <NUM>       Maximum number of boot attempts (default 3).
        \\--timeout <NUM>         Bootloader timeout (default 5).
        \\<DIR>                   NixOS toplevel directory.
        \\
    );

    const parsers = comptime .{
        .FILE = clap.parsers.string,
        .DIR = clap.parsers.string,
        .NUM = clap.parsers.int(u8, 10),
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

    if (res.positionals[0] == null or res.args.@"private-key" == null or res.args.@"public-key" == null) {
        try diag.report(stderr, error.InvalidArgument);
        try clap.usage(stderr, clap.Help, &params);
        return;
    }

    var args = Args{
        .default_nixos_system_closure = res.positionals[0].?,
        .private_key = res.args.@"private-key".?,
        .public_key = res.args.@"public-key".?,
    };

    if (res.args.@"dry-run" > 0) {
        args.dry_run = true;
    }

    if (res.args.@"esp-mnt") |esp_mnt| {
        args.efi_sys_mount_point = esp_mnt;
    }

    if (res.args.timeout) |timeout| {
        args.timeout = timeout;
    }

    if (res.args.@"max-tries") |max_tries| {
        args.max_tries = max_tries;
    }

    if (args.dry_run) {
        std.log.warn("in dry run mode, no filesystem changes will occur", .{});
    }

    const esp = try std.fs.cwd().openDir(args.efi_sys_mount_point, .{
        .iterate = true,
    });

    try ensureFilesystemState(
        esp,
        &args,
    );

    var nixos_system_profile_dir = try std.fs.cwd().openDir(
        "/nix/var/nix/profiles",
        .{ .iterate = true },
    );
    defer nixos_system_profile_dir.close();

    var known_files = StringSet.init(arena_alloc);

    var it = nixos_system_profile_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .sym_link) {
            continue;
        }

        // expecting the name "system-N-link"
        var name_split = std.mem.splitSequence(u8, entry.name, "-");
        if (!std.mem.eql(u8, name_split.next().?, "system")) {
            continue;
        }

        const generation = gen: {
            if (name_split.next()) |maybe_generation| {
                break :gen std.fmt.parseInt(u32, maybe_generation, 10) catch continue;
            } else {
                continue;
            }
        };

        const boot_json_path = try path.join(arena_alloc, &.{
            entry.name,
            "boot.json",
        });

        var boot_json_file = try nixos_system_profile_dir.openFile(boot_json_path, .{});
        defer boot_json_file.close();

        const boot_json_contents = try boot_json_file.readToEndAlloc(arena_alloc, 8192);

        const boot_json = BootJson.parse(arena_alloc, boot_json_contents) catch |err| {
            std.log.err("failed to parse bootspec boot.json: {any}", .{err});
            continue;
        };

        try installGeneration(
            arena_alloc,
            &known_files,
            &boot_json.spec,
            generation,
            esp,
            &args,
        );
        if (boot_json.specialisations) |specialisations| {
            for (specialisations) |s| {
                try installGeneration(
                    arena_alloc,
                    &known_files,
                    &s,
                    generation,
                    esp,
                    &args,
                );
            }
        }

        if (std.mem.eql(u8, boot_json.spec.toplevel, args.default_nixos_system_closure)) {
            const loader_conf_path = try path.join(arena_alloc, &.{
                "loader",
                "loader.conf",
            });

            const loader_conf_contents = try std.fmt.allocPrint(arena_alloc,
                \\timeout {d}
                \\default nixos-generation-{d}
            , .{ args.timeout, generation });

            if (!args.dry_run) {
                var loader_conf_file = try esp.createFile(loader_conf_path, .{});
                defer loader_conf_file.close();

                try loader_conf_file.writeAll(loader_conf_contents);
            }
            std.log.info("installed {s}", .{loader_conf_path});

            try known_files.put(loader_conf_path, {});
        }
    }

    try cleanupDir(arena_alloc, &known_files, esp, "EFI/nixos", &args);
    try cleanupDir(arena_alloc, &known_files, esp, "loader/entries", &args);
}
