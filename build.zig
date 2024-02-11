const std = @import("std");
const log = std.log;
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const coreboot_support = b.option(bool, "coreboot", "Support for coreboot integration") orelse true;
    const tboot_loader_options = b.addOptions();
    tboot_loader_options.addOption(bool, "coreboot_support", coreboot_support);

    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });

    const optimize = b.standardOptimizeOption(.{});

    const tboot_loader_optimize = if (optimize == std.builtin.OptimizeMode.Debug)
        std.builtin.OptimizeMode.Debug
    else
        // Always use release small, smallest size is our goal.
        std.builtin.OptimizeMode.ReleaseSmall;

    const linux_kexec_header_translated = b.addTranslateC(.{
        .source_file = .{ .path = "src/linux.h" },
        .target = target,
        .optimize = tboot_loader_optimize,
    });

    const linux_headers_module = b.addModule("linux_headers", .{
        .source_file = linux_kexec_header_translated.getOutput(),
    });

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
    tboot_loader.addModule("linux_headers", linux_headers_module);
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

    const modem_tool = b.addExecutable(.{
        .name = "xmodem",
        .root_source_file = .{ .path = "src/xmodem.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(modem_tool);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/test.zig" },
        .target = target,
        .optimize = optimize,
    });
    unit_tests.addModule("linux_headers", linux_headers_module);
    unit_tests.addOptions("build_options", tboot_loader_options);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const runner_tool = b.addRunArtifact(b.addExecutable(.{
        .name = "tboot-runner",
        .root_source_file = .{ .path = "src/runner.zig" },
    }));
    runner_tool.step.dependOn(&cpio_archive.step);
    runner_tool.addArg(b.makeTempPath());
    runner_tool.addFileArg(cpio_archive.source);

    var env = try std.process.getEnvMap(b.allocator);
    defer env.deinit();

    if (env.get("TINYBOOT_KERNEL")) |kernel| {
        runner_tool.addArg(kernel);
    }

    // extra args passed through to qemu
    if (b.args) |args| {
        runner_tool.addArgs(args);
    }

    const run_step = b.step("run", "Run in qemu");
    run_step.dependOn(&runner_tool.step);
}
