const std = @import("std");
const json = std.json;

pub const BootSpecV1 = struct {
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
pub const BootJson = struct {
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
