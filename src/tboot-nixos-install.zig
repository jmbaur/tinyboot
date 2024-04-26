const std = @import("std");
const path = std.fs.path;
const json = std.json;

const bls = @import("./boot/bls.zig");

const Args = struct {
    sign_file: []const u8 = "",
    private_key: []const u8 = "",
    public_key: []const u8 = "",
    efi_sys_mount_point: []const u8 = std.fs.path.sep_str ++ "boot",
    max_tries: u8 = 3,
    timeout: u8 = 5,
    default_nixos_system_closure: []const u8 = "",
    dry_run: bool = false,

    const Error = error{
        MissingNixosSystemClosure,
        MissingSignFileProgram,
        MissingPrivateKey,
        MissingPublicKey,
    };

    pub fn init() !@This() {
        var self = @This(){};

        var args = std.process.args();
        while (args.next()) |arg| {
            var split = std.mem.splitSequence(u8, arg, "=");
            const key = split.next().?;
            if (split.next()) |value| {
                if (std.mem.eql(u8, key, "dry-run")) {
                    self.dry_run = std.mem.eql(u8, value, "1");
                } else if (std.mem.eql(u8, key, "sign-file")) {
                    self.sign_file = value;
                } else if (std.mem.eql(u8, key, "private-key")) {
                    self.private_key = value;
                } else if (std.mem.eql(u8, key, "public-key")) {
                    self.public_key = value;
                } else if (std.mem.eql(u8, key, "efi-sys-mount-point")) {
                    self.efi_sys_mount_point = value;
                } else if (std.mem.eql(u8, key, "max-tries")) {
                    self.max_tries = std.fmt.parseInt(u8, value, 10) catch {
                        std.log.err("invalid max-tries '{s}', using default of {d}", .{ value, self.max_tries });
                        continue;
                    };
                } else if (std.mem.eql(u8, key, "timeout")) {
                    self.timeout = std.fmt.parseInt(u8, value, 10) catch {
                        std.log.err("invalid timeout '{s}', using default of {d}", .{ value, self.timeout });
                        continue;
                    };
                }
            } else {
                self.default_nixos_system_closure = key;
            }
        }

        if (self.default_nixos_system_closure.len == 0) {
            return Error.MissingNixosSystemClosure;
        } else if (self.sign_file.len == 0) {
            return Error.MissingSignFileProgram;
        } else if (self.private_key.len == 0) {
            return Error.MissingPrivateKey;
        } else if (self.public_key.len == 0) {
            return Error.MissingPublicKey;
        }

        return self;
    }
};

const BootJson = struct {
    spec: BootSpecV1,
    specialisations: ?[]BootSpecV1 = null,
    allocator: std.mem.Allocator,
    tree: json.Parsed(json.Value),

    const Error = error{
        Invalid,
    };

    pub fn parse(allocator: std.mem.Allocator, contents: []const u8) !@This() {
        const tree = try json.parseFromSlice(json.Value, allocator, contents, .{});
        errdefer tree.deinit();

        const toplevel_object = o: {
            switch (tree.value) {
                .object => |obj| break :o obj,
                else => return Error.Invalid,
            }
        };

        const spec = try BootSpecV1.parse(
            allocator,
            null,
            toplevel_object.get("org.nixos.bootspec.v1") orelse return Error.Invalid,
        );

        const specialisations: ?[]BootSpecV1 = s: {
            if (toplevel_object.get("org.nixos.specialisation.v1")) |special| switch (special) {
                .object => |obj| {
                    var special_list = std.ArrayList(BootSpecV1).init(allocator);
                    defer special_list.deinit();

                    var it = obj.iterator();

                    while (it.next()) |next| {
                        const sub_obj = o: {
                            switch (next.value_ptr.*) {
                                .object => |o| break :o o,
                                else => return Error.Invalid,
                            }
                        };

                        // Specialisations cannot be recursive, so we don't
                        // have to look for specialisations of specialisations.
                        const special_spec = try BootSpecV1.parse(
                            allocator,
                            next.key_ptr.*,
                            sub_obj.get("org.nixos.bootspec.v1") orelse return Error.Invalid,
                        );
                        try special_list.append(special_spec);
                    }

                    break :s try special_list.toOwnedSlice();
                },
                else => return Error.Invalid,
            } else {
                break :s null;
            }
        };

        return @This(){
            .spec = spec,
            .specialisations = specialisations,
            .allocator = allocator,
            .tree = tree,
        };
    }

    pub fn deinit(self: *const @This()) void {
        self.spec.deinit();

        if (self.specialisations) |specialisations| {
            for (specialisations) |s| {
                s.deinit();
            }

            self.allocator.free(specialisations);
        }

        self.tree.deinit();
    }
};

const BootSpecV1 = struct {
    allocator: std.mem.Allocator,

    name: ?[]const u8,

    init: []const u8,
    initrd: ?[]const u8 = null,
    initrd_secrets: ?[]const u8 = null,
    kernel: []const u8,
    kernel_params: []const []const u8,
    label: []const u8,
    system: std.Target.Cpu.Arch,
    toplevel: []const u8,

    const Error = error{
        Invalid,
    };

    fn ensureRequiredArch(val: ?json.Value) !std.Target.Cpu.Arch {
        if (val) |value| {
            switch (value) {
                .string => |string| {
                    if (std.mem.eql(u8, string, "x86_64-linux")) {
                        return std.Target.Cpu.Arch.x86_64;
                    } else if (std.mem.eql(u8, string, "aarch64-linux")) {
                        return std.Target.Cpu.Arch.aarch64;
                    } else {
                        return Error.Invalid;
                    }
                },
                else => return Error.Invalid,
            }
        } else {
            return Error.Invalid;
        }
    }

    fn ensureRequiredStringSlice(a: std.mem.Allocator, val: ?json.Value) ![]const []const u8 {
        if (val) |value| {
            switch (value) {
                .array => |array| {
                    var new_list = std.ArrayList([]const u8).init(a);
                    defer new_list.deinit();

                    for (array.items) |inner_val| {
                        switch (inner_val) {
                            .string => |string| try new_list.append(string),
                            else => return Error.Invalid,
                        }
                    }

                    return new_list.toOwnedSlice();
                },
                else => return Error.Invalid,
            }
        } else {
            return Error.Invalid;
        }
    }

    fn ensureOptionalString(val: ?json.Value) !?[]const u8 {
        if (val) |v| {
            switch (v) {
                .string => |string| return string,
                else => return Error.Invalid,
            }
        }

        return null;
    }

    fn ensureRequiredString(val: ?json.Value) ![]const u8 {
        return @This().ensureOptionalString(val) catch |err| {
            return err;
        } orelse return Error.Invalid;
    }

    pub fn parse(allocator: std.mem.Allocator, name: ?[]const u8, j: json.Value) !@This() {
        const object = o: {
            switch (j) {
                .object => |obj| break :o obj,
                else => return Error.Invalid,
            }
        };

        return @This(){
            .allocator = allocator,
            .name = name,
            .init = try @This().ensureRequiredString(object.get("init")),
            .initrd = try @This().ensureOptionalString(object.get("initrd")),
            .initrd_secrets = try @This().ensureOptionalString(object.get("initrdSecrets")),
            .kernel = try @This().ensureRequiredString(object.get("kernel")),
            .kernel_params = try @This().ensureRequiredStringSlice(allocator, object.get("kernelParams")),
            .label = try @This().ensureRequiredString(object.get("label")),
            .system = try @This().ensureRequiredArch(object.get("system")),
            .toplevel = try @This().ensureRequiredString(object.get("toplevel")),
        };
    }

    pub fn deinit(self: *const @This()) void {
        self.allocator.free(self.kernel_params);
    }
};

fn ensureFilesystemState(
    alloc: std.mem.Allocator,
    loader_entries_dir_path: []const u8,
    efi_nixos_dir_path: []const u8,
    args: Args,
) !void {
    std.log.debug("ensuring filesystem state", .{});

    var root = try std.fs.openDirAbsolute("/", .{});
    defer root.close();

    if (!args.dry_run) {
        try root.makePath(loader_entries_dir_path);
        try root.makePath(efi_nixos_dir_path);
    }

    const entries_srel_path = try path.join(alloc, &.{
        path.sep_str,
        args.efi_sys_mount_point,
        "loader",
        "entries.srel",
    });

    if (!pathExists(entries_srel_path)) {
        if (!args.dry_run) {
            var entries_srel_file = try std.fs.createFileAbsolute(entries_srel_path, .{});
            defer entries_srel_file.close();

            try entries_srel_file.writeAll("type1\n");
        }
        std.log.info("installed {s}", .{entries_srel_path});
    }

    std.log.debug("filesystem state is good", .{});
}

fn pathExists(p: []const u8) bool {
    std.fs.accessAbsolute(p, .{}) catch {
        return false;
    };

    return true;
}

fn installGeneration(
    alloc: std.mem.Allocator,
    known_files: *StringSet,
    spec: *const BootSpecV1,
    generation: u32,
    loader_entries_dir_path: []const u8,
    args: *const Args,
) !void {
    const linux_target_filename = try std.fmt.allocPrint(
        alloc,
        "{s}-{s}",
        .{ path.basename(path.dirname(spec.kernel).?), path.basename(spec.kernel) },
    );

    const linux_target = try path.join(alloc, &.{
        path.sep_str,
        "EFI",
        "nixos",
        linux_target_filename,
    });

    const full_linux_path = try path.join(
        alloc,
        &.{ args.efi_sys_mount_point, linux_target },
    );

    if (!pathExists(full_linux_path)) {
        if (!args.dry_run) {
            try std.fs.copyFileAbsolute(spec.kernel, full_linux_path, .{});

            var kernel_child = std.ChildProcess.init(&.{
                args.sign_file,
                "sha256",
                args.private_key,
                args.public_key,
                full_linux_path,
            }, alloc);
            _ = try kernel_child.spawnAndWait();
        }
        std.log.info("installed {s}", .{full_linux_path});
    }

    try known_files.put(full_linux_path, {});

    // TODO(jared): NixOS always has an initrd, but we should still
    // handle the case where it does not exist.
    const initrd_target_filename = try std.fmt.allocPrint(
        alloc,
        "{s}-{s}",
        .{ path.basename(path.dirname(spec.initrd.?).?), path.basename(spec.initrd.?) },
    );

    const initrd_target = try path.join(alloc, &.{
        path.sep_str,
        "EFI",
        "nixos",
        initrd_target_filename,
    });

    const full_initrd_path = try path.join(alloc, &.{
        path.sep_str,
        args.efi_sys_mount_point,
        initrd_target,
    });

    if (!pathExists(full_initrd_path)) {
        if (!args.dry_run) {
            try std.fs.copyFileAbsolute(spec.initrd.?, full_initrd_path, .{});

            var initrd_child = std.ChildProcess.init(&.{
                args.sign_file,
                "sha256",
                args.private_key,
                args.public_key,
                full_initrd_path,
            }, alloc);
            _ = try initrd_child.spawnAndWait();
        }
        std.log.info("installed {s}", .{full_initrd_path});
    }

    try known_files.put(full_initrd_path, {});

    const kernel_params_without_init = try std.mem.join(alloc, " ", spec.kernel_params);

    const kernel_params = try std.fmt.allocPrint(
        alloc,
        "init={s} {s}",
        .{ spec.init, kernel_params_without_init },
    );

    const sub_name = if (spec.name) |name|
        try std.fmt.allocPrint(alloc, " ({s})", .{name})
    else
        try alloc.alloc(u8, 0);

    const entry_contents = try std.fmt.allocPrint(alloc,
        \\title {s}{s}
        \\version {s}
        \\linux {s}
        \\initrd {s}
        \\options {s}
    , .{
        spec.label,
        sub_name,
        spec.label,
        linux_target,
        initrd_target,
        kernel_params,
    });

    const sub_entry_name = if (spec.name) |name|
        try std.fmt.allocPrint(alloc, "-specialisation-{s}", .{name})
    else
        try alloc.alloc(u8, 0);

    const entry_name = try std.fmt.allocPrint(
        alloc,
        "nixos-generation-{d}{s}",
        .{ generation, sub_entry_name },
    );

    const entry_filename_with_counters = try std.fmt.allocPrint(
        alloc,
        "{s}+{d}-0.conf",
        .{ entry_name, args.max_tries },
    );

    const entry_path = try path.join(alloc, &.{
        path.sep_str,
        args.efi_sys_mount_point,
        "loader",
        "entries",
        entry_filename_with_counters,
    });

    var entries_dir = try std.fs.openDirAbsolute(
        loader_entries_dir_path,
        .{ .iterate = true },
    );
    defer entries_dir.close();

    var it = entries_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        const existing_entry = bls.EntryFilename.parse(entry.name) catch continue;

        if (std.mem.eql(u8, existing_entry.name, entry_name)) {
            std.log.debug("entry {s} already installed", .{entry_name});
            const known_entry = try path.join(alloc, &.{
                path.sep_str,
                args.efi_sys_mount_point,
                "loader",
                "entries",
                entry.name,
            });
            try known_files.put(known_entry, {});
            return;
        }
    }

    if (!args.dry_run) {
        var entry_file = try std.fs.createFileAbsolute(entry_path, .{});
        defer entry_file.close();

        try entry_file.writeAll(entry_contents);
        try known_files.put(entry_path, {});
    }

    std.log.info("installed {s}", .{entry_path});
}

fn cleanupDir(
    alloc: std.mem.Allocator,
    known_files: *StringSet,
    dir: []const u8,
    args: *const Args,
) !void {
    var open_dir = try std.fs.openDirAbsolute(dir, .{ .iterate = true });
    defer open_dir.close();

    var it = open_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        const full_path = try path.join(alloc, &.{ path.sep_str, dir, entry.name });

        if (known_files.get(full_path) == null) {
            if (!args.dry_run) {
                try std.fs.deleteFileAbsolute(full_path);
            }
            std.log.info("cleaned up {s}", .{full_path});
        }
    }
}

const StringSet = std.StringHashMap(void);

pub fn main() !void {
    const args = try Args.init();

    if (args.dry_run) {
        std.log.warn("running a dry run, no filesystem changes will occur", .{});
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const efi_nixos_dir_path = try path.join(allocator, &.{
        path.sep_str,
        args.efi_sys_mount_point,
        "EFI",
        "nixos",
    });

    const loader_entries_dir_path = try path.join(allocator, &.{
        path.sep_str,
        args.efi_sys_mount_point,
        "loader",
        "entries",
    });

    try ensureFilesystemState(
        allocator,
        loader_entries_dir_path,
        efi_nixos_dir_path,
        args,
    );

    var nixos_system_profile_dir = try std.fs.openDirAbsolute(
        "/nix/var/nix/profiles",
        .{ .iterate = true },
    );
    defer nixos_system_profile_dir.close();

    var known_files = StringSet.init(allocator);

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

        const boot_json_path = try path.join(allocator, &.{
            path.sep_str,
            "nix",
            "var",
            "nix",
            "profiles",
            entry.name,
            "boot.json",
        });

        var boot_json_file = try std.fs.openFileAbsolute(boot_json_path, .{});
        defer boot_json_file.close();

        const boot_json_contents = try boot_json_file.readToEndAlloc(allocator, 8192);

        const boot_json = BootJson.parse(allocator, boot_json_contents) catch |err| {
            std.log.err("failed to parse bootspec boot.json: {any}", .{err});
            continue;
        };

        try installGeneration(
            allocator,
            &known_files,
            &boot_json.spec,
            generation,
            loader_entries_dir_path,
            &args,
        );
        if (boot_json.specialisations) |specialisations| {
            for (specialisations) |s| {
                try installGeneration(
                    allocator,
                    &known_files,
                    &s,
                    generation,
                    loader_entries_dir_path,
                    &args,
                );
            }
        }

        if (std.mem.eql(u8, boot_json.spec.toplevel, args.default_nixos_system_closure)) {
            const loader_conf_path = try path.join(allocator, &.{
                path.sep_str,
                args.efi_sys_mount_point,
                "loader",
                "loader.conf",
            });

            const loader_conf_contents = try std.fmt.allocPrint(allocator,
                \\timeout {d}
                \\default nixos-generation-{d}
            , .{ args.timeout, generation });

            if (!args.dry_run) {
                var loader_conf_file = try std.fs.createFileAbsolute(loader_conf_path, .{});
                defer loader_conf_file.close();

                try loader_conf_file.writeAll(loader_conf_contents);
            }
            std.log.info("installed {s}", .{loader_conf_path});

            try known_files.put(loader_conf_path, {});
        }
    }

    try cleanupDir(allocator, &known_files, efi_nixos_dir_path, &args);
    try cleanupDir(allocator, &known_files, loader_entries_dir_path, &args);
}

test "boot spec parsing" {
    const json_contents =
        \\{
        \\  "org.nixos.bootspec.v1": {
        \\    "init": "/nix/store/00000000000000000000000000000000-xxxxxxxxxx/init",
        \\    "initrd": "/nix/store/00000000000000000000000000000000-initrd-linux-x.x.xx/initrd",
        \\    "initrdSecrets": "/nix/store/00000000000000000000000000000000-append-initrd-secrets/bin/append-initrd-secrets",
        \\    "kernel": "/nix/store/00000000000000000000000000000000-linux-x.x.xx/bzImage",
        \\    "kernelParams": [
        \\      "loglevel=4",
        \\      "nvidia-drm.modeset=1"
        \\    ],
        \\    "label": "foobar",
        \\    "system": "x86_64-linux",
        \\    "toplevel": "/nix/store/00000000000000000000000000000000-xxxxxxxxxx"
        \\  },
        \\  "org.nixos.specialisation.v1": {}
        \\}
    ;

    const boot_json = try BootJson.parse(std.testing.allocator, json_contents);
    defer boot_json.deinit();

    try std.testing.expectEqualStrings("/nix/store/00000000000000000000000000000000-xxxxxxxxxx/init", boot_json.spec.init);
    try std.testing.expectEqualStrings("/nix/store/00000000000000000000000000000000-initrd-linux-x.x.xx/initrd", boot_json.spec.initrd.?);
    try std.testing.expectEqualStrings("/nix/store/00000000000000000000000000000000-append-initrd-secrets/bin/append-initrd-secrets", boot_json.spec.initrd_secrets.?);
    try std.testing.expectEqualStrings("/nix/store/00000000000000000000000000000000-linux-x.x.xx/bzImage", boot_json.spec.kernel);
    try std.testing.expectEqual(@as(usize, 2), boot_json.spec.kernel_params.len);
    try std.testing.expectEqualStrings("loglevel=4", boot_json.spec.kernel_params[0]);
    try std.testing.expectEqualStrings("nvidia-drm.modeset=1", boot_json.spec.kernel_params[1]);
    try std.testing.expectEqualStrings("foobar", boot_json.spec.label);
    try std.testing.expectEqual(std.Target.Cpu.Arch.x86_64, boot_json.spec.system);
    try std.testing.expectEqualStrings("/nix/store/00000000000000000000000000000000-xxxxxxxxxx", boot_json.spec.toplevel);

    try std.testing.expectEqual(@as(usize, 0), boot_json.specialisations.?.len);
}

test "boot spec with specialisation" {
    const contents =
        \\{
        \\  "org.nixos.bootspec.v1": {
        \\    "init": "/nix/store/00000000000000000000000000000000-xxxxxxxxxx/init",
        \\    "initrd": "/nix/store/00000000000000000000000000000000-initrd-linux-x.x.x/initrd",
        \\    "initrdSecrets": "/nix/store/00000000000000000000000000000000-append-initrd-secrets/bin/append-initrd-secrets",
        \\    "kernel": "/nix/store/00000000000000000000000000000000-linux-x.x.x/bzImage",
        \\    "kernelParams": [
        \\      "console=ttyS0,115200",
        \\      "loglevel=4"
        \\    ],
        \\    "label": "foobar",
        \\    "system": "x86_64-linux",
        \\    "toplevel": "/nix/store/00000000000000000000000000000000-xxxxxxxxxx"
        \\  },
        \\  "org.nixos.specialisation.v1": {
        \\    "alternate": {
        \\      "org.nixos.bootspec.v1": {
        \\        "init": "/nix/store/00000000000000000000000000000000-xxxxxxxxxx/init",
        \\        "initrd": "/nix/store/00000000000000000000000000000000-initrd-linux-x.x.x/initrd",
        \\        "initrdSecrets": "/nix/store/00000000000000000000000000000000-append-initrd-secrets/bin/append-initrd-secrets",
        \\        "kernel": "/nix/store/00000000000000000000000000000000-linux-x.x.x/bzImage",
        \\        "kernelParams": [
        \\          "console=ttyS0,115200",
        \\          "console=tty1",
        \\          "loglevel=4"
        \\        ],
        \\        "label": "foobaz",
        \\        "system": "x86_64-linux",
        \\        "toplevel": "/nix/store/00000000000000000000000000000000-xxxxxxxxxx"
        \\      },
        \\      "org.nixos.specialisation.v1": {}
        \\    }
        \\  }
        \\}
    ;

    const boot_json = try BootJson.parse(std.testing.allocator, contents);
    defer boot_json.deinit();

    try std.testing.expectEqual(@as(usize, 1), boot_json.specialisations.?.len);
}
