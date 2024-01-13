const std = @import("std");
const log = std.log;
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const coreboot_support = b.option(bool, "coreboot", "Support for coreboot integration") orelse true;
    const tboot_loader_options = b.addOptions();
    tboot_loader_options.addOption(bool, "coreboot_support", coreboot_support);

    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });

    var optimize = b.standardOptimizeOption(.{});

    const tboot_loader = b.addExecutable(.{
        .name = "tboot-loader",
        .root_source_file = .{ .path = "src/tboot-loader.zig" },
        .target = target,
        .optimize = if (optimize == std.builtin.OptimizeMode.Debug)
            std.builtin.OptimizeMode.Debug
        else
            // Always use release small, smallest size is our goal.
            std.builtin.OptimizeMode.ReleaseSmall,
    });

    tboot_loader.addOptions("build_options", tboot_loader_options);

    // make the default step just compile tboot-loader
    b.default_step = &tboot_loader.step;

    // runs on builder
    const cpio_tool = b.addRunArtifact(b.addExecutable(.{
        .name = "cpio",
        .root_source_file = .{ .path = "src/cpio/main.zig" },
    }));
    cpio_tool.addArtifactArg(tboot_loader);
    const cpio_archive = b.addInstallFile(
        cpio_tool.addOutputFileArg("tboot-loader.cpio"),
        "tboot-loader.cpio",
    );

    // install the cpio archive during "zig build install"
    b.getInstallStep().dependOn(&cpio_archive.step);

    const tboot_bless_boot = b.addExecutable(.{
        .name = "tboot-bless-boot",
        .root_source_file = .{ .path = "src/tboot-bless-boot.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(tboot_bless_boot);

    const tboot_bless_boot_generator = b.addExecutable(.{
        .name = "tboot-bless-boot-generator",
        .root_source_file = .{ .path = "src/tboot-bless-boot-generator.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(tboot_bless_boot_generator);

    const tboot_nixos_install = b.addExecutable(.{
        .name = "tboot-nixos-install",
        .root_source_file = .{ .path = "src/tboot-nixos-install.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(tboot_nixos_install);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/test.zig" },
        .target = target,
        .optimize = optimize,
    });
    unit_tests.addOptions("build_options", tboot_loader_options);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const run_cmd = b.addSystemCommand(&.{switch (builtin.target.cpu.arch) {
        .aarch64 => "qemu-system-aarch64",
        .x86_64 => "qemu-system-x86_64",
        else => @compileError("don't know how to run qemu on build system"),
    }});
    run_cmd.step.dependOn(&cpio_archive.step);

    // TODO(jared): test for existence of /dev/kvm
    if (builtin.target.os.tag == .linux) {
        run_cmd.addArg("-enable-kvm");
    }

    var env = try std.process.getEnvMap(b.allocator);
    defer env.deinit();

    run_cmd.addArgs(&.{ "-machine", switch (builtin.target.cpu.arch) {
        .aarch64 => "virt",
        .x86_64 => "q35",
        else => @compileError("don't know how to run qemu on build system"),
    } });

    run_cmd.addArgs(&.{
        // "-fw_cfg",  "name=opt/org.tboot/pubkey,file=TODO",
        // "-chardev", "socket,id=chrtpm,path=TODO",
        // "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
        "-display", "none",
        "-serial",  "mon:stdio",
        "-smp",     "2",
        "-m",       "2G",
        "-netdev",  "user,id=n1",
        "-device",  "virtio-net-pci,netdev=n1",
    });

    if (env.get("TINYBOOT_KERNEL")) |kernel| {
        run_cmd.addArgs(&.{ "-kernel", kernel });
    }

    run_cmd.addArg("-initrd");
    run_cmd.addFileArg(cpio_archive.source);

    // extra args passed through to qemu
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run in qemu");
    run_step.dependOn(&run_cmd.step);
}
