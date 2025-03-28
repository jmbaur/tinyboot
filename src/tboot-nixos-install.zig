const builtin = @import("builtin");
const std = @import("std");
const path = std.fs.path;
const utils = @import("./utils.zig");
const clap = @import("clap");

pub const std_options = std.Options{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

const DiskBootLoader = @import("./boot/disk.zig");
const signFile = @import("./tboot-sign.zig").signFile;
const BootSpecV1 = @import("./bootspec.zig").BootSpecV1;
const BootJson = @import("./bootspec.zig").BootJson;

const BlsEntryFile = DiskBootLoader.BlsEntryFile;

fn ensureFilesystemState(
    esp: *std.fs.Dir,
    args: *const Args,
) !void {
    std.log.debug("ensuring filesystem state", .{});

    if (!args.dry_run) {
        try esp.makePath("loader/nixos");
        try esp.makePath("loader/entries");
    }

    if (!utils.pathExists(esp, "loader/entries.srel")) {
        if (!args.dry_run) {
            var entries_srel_file = try esp.createFile(
                "loader/entries.srel",
                .{},
            );
            defer entries_srel_file.close();

            try entries_srel_file.writeAll("type1\n");
        }
        std.log.info("installed entries.srel", .{});
    }

    std.log.debug("filesystem state is good", .{});
}

fn installGeneration(
    arena_alloc: std.mem.Allocator,
    nixos_known_files: *StringSet,
    entries_known_files: *StringSet,
    spec: *const BootSpecV1,
    nixos_dir: *std.fs.Dir,
    entries_dir: *std.fs.Dir,
    esp: *std.fs.Dir,
    generation: u32,
    args: *const Args,
) !void {
    var entry_contents_list = std.ArrayList(u8).init(arena_alloc);

    const linux_target_filename = try std.fmt.allocPrint(
        arena_alloc,
        "{s}-{s}",
        .{
            path.basename(path.dirname(spec.kernel).?),
            path.basename(spec.kernel),
        },
    );

    const linux_target = try path.resolve(arena_alloc, &.{
        "loader",
        "nixos",
        linux_target_filename,
    });

    const full_linux_path = try path.resolve(
        arena_alloc,
        &.{ args.efi_sys_mount_point, linux_target },
    );

    if (!utils.pathExists(esp, linux_target)) {
        if (!args.dry_run) {
            if (args.sign) |sign| {
                try signFile(
                    arena_alloc,
                    spec.kernel,
                    full_linux_path,
                    sign.private_key,
                    sign.public_key,
                );

                std.log.info("signed {s}", .{linux_target_filename});
            } else {
                try std.fs.cwd().copyFile(
                    spec.kernel,
                    nixos_dir.*,
                    linux_target_filename,
                    .{},
                );
            }
        }

        std.log.info("installed {s}", .{linux_target_filename});
    }

    try nixos_known_files.put(linux_target_filename, {});

    const initrd_target = b: {
        if (spec.initrd) |initrd| {
            const initrd_target_filename = try std.fmt.allocPrint(
                arena_alloc,
                "{s}-{s}",
                .{
                    path.basename(path.dirname(initrd).?),
                    path.basename(initrd),
                },
            );

            const initrd_target = try path.resolve(arena_alloc, &.{
                "loader",
                "nixos",
                initrd_target_filename,
            });

            const full_initrd_path = try path.resolve(arena_alloc, &.{
                args.efi_sys_mount_point,
                initrd_target,
            });

            if (!utils.pathExists(esp, initrd_target)) {
                if (!args.dry_run) {
                    if (args.sign) |sign| {
                        try signFile(
                            arena_alloc,
                            initrd,
                            full_initrd_path,
                            sign.private_key,
                            sign.public_key,
                        );

                        std.log.info("signed {s}", .{initrd_target_filename});
                    } else {
                        try std.fs.cwd().copyFile(
                            initrd,
                            nixos_dir.*,
                            initrd_target_filename,
                            .{},
                        );
                    }
                }

                std.log.info("installed {s}", .{initrd_target_filename});
            }

            try nixos_known_files.put(initrd_target_filename, {});

            break :b initrd_target;
        } else {
            break :b null;
        }
    };

    const kernel_params_without_init = try std.mem.join(
        arena_alloc,
        " ",
        spec.kernel_params,
    );

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

    var it = entries_dir.iterate();
    while (try it.next()) |dir_entry| {
        if (dir_entry.kind != .file) {
            continue;
        }

        const existing_entry = BlsEntryFile.parse(dir_entry.name) catch continue;

        if (std.mem.eql(u8, existing_entry.name, entry_name)) {
            std.log.debug("entry {s} already installed", .{entry_name});
            try entries_known_files.put(dir_entry.name, {});
            return;
        }
    }

    if (!args.dry_run) {
        var entry_file = try entries_dir.createFile(entry_filename_with_counters, .{});
        defer entry_file.close();

        try entry_file.writeAll(try entry_contents_list.toOwnedSlice());
        try entries_known_files.put(entry_filename_with_counters, {});
    }

    std.log.info("installed {s}", .{entry_filename_with_counters});
}

fn cleanupDir(
    known_files: *StringSet,
    dir: *std.fs.Dir,
    args: *const Args,
) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        if (known_files.get(entry.name) == null) {
            if (!args.dry_run) {
                try dir.deleteFile(entry.name);
            }

            std.log.info("cleaned up {s}", .{entry.name});
        }
    }
}

const StringSet = std.StringHashMap(void);

const SignArgs = struct {
    private_key: []const u8,
    public_key: []const u8,
};

const Args = struct {
    sign: ?SignArgs = null,
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
        \\--certificate <FILE>    X509 certificate to sign with.
        \\--esp-mnt <DIR>         EFI system partition mountpoint (default /boot).
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

    if (res.positionals[0] == null or
        // If a private or public key is provided but the other corresponding
        // key is not provided, error out.
        ((res.args.@"private-key" == null) !=
            (res.args.certificate == null)))
    {
        try diag.report(stderr, error.InvalidArgument);
        try clap.usage(stderr, clap.Help, &params);
        return;
    }

    var args = Args{
        .default_nixos_system_closure = try std.fs.cwd().realpathAlloc(
            arena.allocator(),
            res.positionals[0].?,
        ),
    };

    if (res.args.@"private-key" != null and
        res.args.certificate != null)
    {
        args.sign = .{
            .private_key = res.args.@"private-key".?,
            .public_key = res.args.certificate.?,
        };
    }

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

    var esp = try std.fs.cwd().openDir(args.efi_sys_mount_point, .{
        .iterate = true,
    });
    defer esp.close();

    try ensureFilesystemState(
        &esp,
        &args,
    );

    var nixos_dir = try esp.openDir("loader/nixos", .{ .iterate = true });
    defer nixos_dir.close();

    var entries_dir = try esp.openDir("loader/entries", .{ .iterate = true });
    defer entries_dir.close();

    var nixos_profiles_dir = try std.fs.cwd().openDir(
        "/nix/var/nix/profiles",
        .{ .iterate = true },
    );
    defer nixos_profiles_dir.close();

    var nixos_known_files = StringSet.init(arena_alloc);
    var entries_known_files = StringSet.init(arena_alloc);

    var it = nixos_profiles_dir.iterate();
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

        const boot_json_path = try path.resolve(arena_alloc, &.{
            entry.name,
            "boot.json",
        });

        var boot_json_file = try nixos_profiles_dir.openFile(boot_json_path, .{});
        defer boot_json_file.close();

        const boot_json_contents = try boot_json_file.readToEndAlloc(arena_alloc, 8192);

        const boot_json = BootJson.parse(arena_alloc, boot_json_contents) catch |err| {
            std.log.err("failed to parse bootspec boot.json: {any}", .{err});
            continue;
        };

        try installGeneration(
            arena_alloc,
            &nixos_known_files,
            &entries_known_files,
            &boot_json.spec,
            &nixos_dir,
            &entries_dir,
            &esp,
            generation,
            &args,
        );

        if (boot_json.specialisations) |specialisations| {
            for (specialisations) |s| {
                try installGeneration(
                    arena_alloc,
                    &nixos_known_files,
                    &entries_known_files,
                    &s,
                    &nixos_dir,
                    &entries_dir,
                    &esp,
                    generation,
                    &args,
                );
            }
        }

        if (std.mem.eql(u8, boot_json.spec.toplevel, args.default_nixos_system_closure)) {
            const loader_conf_path = "loader/loader.conf";

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
        }
    }

    try cleanupDir(&nixos_known_files, &nixos_dir, &args);
    try cleanupDir(&entries_known_files, &entries_dir, &args);
}
