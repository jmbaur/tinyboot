const std = @import("std");
const log = std.log;
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});
    const tboot_loader_optimize = if (optimize == std.builtin.OptimizeMode.Debug)
        std.builtin.OptimizeMode.Debug
    else
        // Always use release small, smallest size is our goal.
        std.builtin.OptimizeMode.ReleaseSmall;

    const with_loader = b.option(bool, "loader", "With boot loader") orelse true;
    const with_tools = b.option(bool, "tools", "With tools") orelse true;

    const clap = b.dependency("clap", .{});

    const linux_headers_translated = b.addTranslateC(.{
        .root_source_file = b.path("src/linux.h"),
        .target = target,
        // TODO(jared): how much does optimization do for the translate-c stuff?
        .optimize = tboot_loader_optimize,
    });
    const linux_headers_module = linux_headers_translated.addModule("linux_headers");

    if (with_loader) {
        const tboot_loader = b.addExecutable(.{
            .name = "tboot-loader",
            .root_source_file = b.path("src/tboot-loader.zig"),
            .target = target,
            .optimize = tboot_loader_optimize,
            .strip = optimize != std.builtin.OptimizeMode.Debug,
        });
        tboot_loader.root_module.addAnonymousImport("test_key", .{
            .root_source_file = b.path("tests/keys/tboot/key.der"),
        });
        tboot_loader.root_module.addImport("linux_headers", linux_headers_module);

        const cpio_tool = b.addRunArtifact(b.addExecutable(.{
            .name = "cpio",
            .target = b.host,
            .root_source_file = b.path("src/cpio/main.zig"),
        }));
        cpio_tool.addArtifactArg(tboot_loader);
        const cpio_archive = b.addInstallFile(
            cpio_tool.addOutputFileArg("tboot-loader.cpio"),
            "tboot-loader.cpio",
        );

        // install the cpio archive during "zig build install"
        b.getInstallStep().dependOn(&cpio_archive.step);

        const runner_tool = b.addRunArtifact(b.addExecutable(.{
            .name = "tboot-runner",
            .target = b.host,
            .root_source_file = b.path("src/runner.zig"),
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

    if (with_tools) {
        const tboot_bless_boot = b.addExecutable(.{
            .name = "tboot-bless-boot",
            .root_source_file = b.path("src/tboot-bless-boot.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != std.builtin.OptimizeMode.Debug,
        });
        tboot_bless_boot.root_module.addImport("clap", clap.module("clap"));
        b.installArtifact(tboot_bless_boot);

        const tboot_bless_boot_generator = b.addExecutable(.{
            .name = "tboot-bless-boot-generator",
            .root_source_file = b.path("src/tboot-bless-boot-generator.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != std.builtin.OptimizeMode.Debug,
        });
        b.installArtifact(tboot_bless_boot_generator);

        const tboot_sign = b.addExecutable(.{
            .name = "tboot-sign",
            .root_source_file = b.path("src/tboot-sign.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != std.builtin.OptimizeMode.Debug,
        });
        tboot_sign.linkLibC();
        tboot_sign.linkSystemLibrary("libcrypto");
        tboot_sign.root_module.addImport("clap", clap.module("clap"));
        b.installArtifact(tboot_sign);

        const tboot_nixos_install = b.addExecutable(.{
            .name = "tboot-nixos-install",
            .root_source_file = b.path("src/tboot-nixos-install.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != std.builtin.OptimizeMode.Debug,
        });
        tboot_nixos_install.linkLibC();
        tboot_nixos_install.linkSystemLibrary("libcrypto");
        tboot_nixos_install.root_module.addImport("clap", clap.module("clap"));
        b.installArtifact(tboot_nixos_install);

        const tboot_ymodem = b.addExecutable(.{
            .name = "tboot-ymodem",
            .root_source_file = b.path("src/ymodem.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != std.builtin.OptimizeMode.Debug,
        });
        tboot_ymodem.root_module.addImport("linux_headers", linux_headers_module);
        tboot_ymodem.root_module.addImport("clap", clap.module("clap"));
        b.installArtifact(tboot_ymodem);
    }

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });

    unit_tests.root_module.addImport("linux_headers", linux_headers_module);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
