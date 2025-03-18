const std = @import("std");
const zig = std.zig;

const TBOOT_INITRD_NAME = "tboot-initrd";

fn linuxHeadersForTarget(
    b: *std.Build,
    header_file: *std.Build.Step.WriteFile,
    target: std.Build.ResolvedTarget,
) *std.Build.Step.TranslateC {
    return b.addTranslateC(.{
        .root_source_file = .{ .generated = .{
            .file = &header_file.generated_directory,
            .sub_path = "linux.h",
        } },
        .target = target,
        .optimize = .ReleaseSafe, // This doesn't seem to do anything when translating pure headers
    });
}

pub fn build(b: *std.Build) !void {
    var env = try std.process.getEnvMap(b.allocator);
    defer env.deinit();

    const target = b.standardTargetOptions(
        .{ .default_target = .{ .cpu_model = .baseline } },
    );

    // tboot-loader is a fully-native Zig program, so we can statically link it
    // by setting the ABI to musl.
    var tboot_loader_target_query = target.query;
    tboot_loader_target_query.abi = .musl;

    const tboot_loader_target = b.resolveTargetQuery(tboot_loader_target_query);

    const is_native_build = b.graph.host.result.cpu.arch == target.result.cpu.arch;

    const optimize = b.standardOptimizeOption(.{});

    const do_strip = optimize != std.builtin.OptimizeMode.Debug;

    const tboot_loader_optimize = if (optimize == std.builtin.OptimizeMode.Debug)
        std.builtin.OptimizeMode.Debug
    else
        // Always use release small, smallest size is our goal.
        std.builtin.OptimizeMode.ReleaseSmall;

    const with_loader = b.option(bool, "loader", "With boot loader") orelse true;
    const with_tools = b.option(bool, "tools", "With tools") orelse false;
    const firmware_directory = b.option(
        []const u8,
        "firmware-directory",
        "Firmware directory",
    );
    const runner_keydir = b.option([]const u8, "keydir", "Directory of keys to use when spawning VM runner (as output by tboot-keygen)");
    const runner_kernel = b.option([]const u8, "kernel", "Kernel to use when spawning VM runner") orelse env.get("TINYBOOT_KERNEL");

    const clap = b.dependency("clap", .{});

    const linux_h = b.addWriteFile("linux.h",
        \\#include <asm-generic/setup.h>
        \\#include <linux/kexec.h>
        \\#include <linux/keyctl.h>
        \\#include <linux/major.h>
        \\#include <sys/epoll.h>
        \\#include <sys/ioctl.h>
        \\#include <termios.h>
    );

    const tboot_loader_linux_headers = linuxHeadersForTarget(b, linux_h, tboot_loader_target);
    const linux_headers = linuxHeadersForTarget(b, linux_h, target);
    const tboot_loader_linux_headers_module = tboot_loader_linux_headers.addModule("linux_headers");
    const linux_headers_module = linux_headers.addModule("linux_headers");

    // For re-usage with building the tboot-loader initrd, if we are also
    // building tools.
    var maybe_tboot_initrd_tool: ?*std.Build.Step.Compile = null;

    if ((with_loader and is_native_build) or with_tools) {
        maybe_tboot_initrd_tool = b.addExecutable(.{
            .name = TBOOT_INITRD_NAME,
            .root_source_file = b.path("src/tboot-initrd.zig"),
            .target = target,
            .optimize = optimize,
            .strip = do_strip,
        });
        var tboot_initrd_tool = maybe_tboot_initrd_tool.?;
        tboot_initrd_tool.linkLibC();
        tboot_initrd_tool.each_lib_rpath = true;
        tboot_initrd_tool.linkSystemLibrary("liblzma");
        tboot_initrd_tool.root_module.addImport("clap", clap.module("clap"));
    }

    if (with_tools) {
        b.installArtifact(maybe_tboot_initrd_tool.?);

        const tboot_bless_boot = b.addExecutable(.{
            .name = "tboot-bless-boot",
            .root_source_file = b.path("src/tboot-bless-boot.zig"),
            .target = target,
            .optimize = optimize,
            .strip = do_strip,
        });
        tboot_bless_boot.root_module.addImport("clap", clap.module("clap"));
        b.installArtifact(tboot_bless_boot);

        const tboot_bless_boot_generator = b.addExecutable(.{
            .name = "tboot-bless-boot-generator",
            .root_source_file = b.path("src/tboot-bless-boot-generator.zig"),
            .target = target,
            .optimize = optimize,
            .strip = do_strip,
        });
        tboot_bless_boot_generator.root_module.addImport("clap", clap.module("clap"));
        b.installArtifact(tboot_bless_boot_generator);

        const tboot_sign = b.addExecutable(.{
            .name = "tboot-sign",
            .root_source_file = b.path("src/tboot-sign.zig"),
            .target = target,
            .optimize = optimize,
            .strip = do_strip,
        });
        tboot_sign.linkLibC();
        tboot_sign.each_lib_rpath = true;
        tboot_sign.linkSystemLibrary("libcrypto");
        tboot_sign.root_module.addImport("clap", clap.module("clap"));
        b.installArtifact(tboot_sign);

        const tboot_keygen = b.addExecutable(.{
            .name = "tboot-keygen",
            .root_source_file = b.path("src/tboot-keygen.zig"),
            .target = target,
            .optimize = optimize,
            .strip = do_strip,
        });
        tboot_keygen.linkLibC();
        tboot_keygen.each_lib_rpath = true;
        tboot_keygen.linkSystemLibrary("libcrypto");
        tboot_keygen.root_module.addImport("clap", clap.module("clap"));
        b.installArtifact(tboot_keygen);

        const tboot_nixos_install = b.addExecutable(.{
            .name = "tboot-nixos-install",
            .root_source_file = b.path("src/tboot-nixos-install.zig"),
            .target = target,
            .optimize = optimize,
            .strip = do_strip,
        });
        tboot_nixos_install.linkLibC();
        tboot_nixos_install.each_lib_rpath = true;
        tboot_nixos_install.linkSystemLibrary("libcrypto");
        tboot_nixos_install.root_module.addImport("clap", clap.module("clap"));
        b.installArtifact(tboot_nixos_install);

        const tboot_ymodem = b.addExecutable(.{
            .name = "tboot-ymodem",
            .root_source_file = b.path("src/ymodem.zig"),
            .target = target,
            .optimize = optimize,
            .strip = do_strip,
        });
        tboot_ymodem.root_module.addImport("linux_headers", linux_headers_module);
        tboot_ymodem.root_module.addImport("clap", clap.module("clap"));
        b.installArtifact(tboot_ymodem);

        const tboot_vpd = b.addExecutable(.{
            .name = "tboot-vpd",
            .root_source_file = b.path("src/vpd.zig"),
            .target = target,
            .optimize = optimize,
            .strip = do_strip,
        });
        tboot_vpd.root_module.addImport("linux_headers", linux_headers_module);
        tboot_vpd.root_module.addImport("clap", clap.module("clap"));
        b.installArtifact(tboot_vpd);
    }

    if (with_loader) {
        const tboot_loader = b.addExecutable(.{
            .name = "tboot-loader",
            .root_source_file = b.path("src/tboot-loader.zig"),
            .target = tboot_loader_target,
            .optimize = tboot_loader_optimize,
            .strip = do_strip,
        });
        b.installArtifact(tboot_loader);
        tboot_loader.root_module.addImport("linux_headers", tboot_loader_linux_headers_module);

        // If we are performing a native build (i.e. the platform we are
        // building on is the same as the platform we are building to), look
        // for a local build of tboot-initrd to use, as it is helpful for
        // iteration on the tool itself. Otherwise, use the tboot-initrd that
        // exists on $PATH.
        var run_tboot_initrd = if (is_native_build)
            b.addRunArtifact(maybe_tboot_initrd_tool.?)
        else
            b.addSystemCommand(&.{TBOOT_INITRD_NAME});

        // TODO(jared): Would be nicer to have generic
        // --file=tboot_loader:/init CLI interface, but don't know how to
        // obtain path and string format it into that form. Further, would
        // be nicer to not shell-out to a separate tool at all and just do
        // the CPIO generation in here.
        run_tboot_initrd.addPrefixedFileArg("-i", tboot_loader.getEmittedBin());

        if (firmware_directory) |directory| {
            const directory_ = b.addWriteFiles().addCopyDirectory(
                .{ .cwd_relative = directory },
                "",
                .{},
            );

            run_tboot_initrd.addPrefixedDirectoryArg("-d", directory_);
        }

        const cpio_output_file = run_tboot_initrd.addPrefixedOutputFileArg(
            "-o",
            "tboot-loader.cpio",
        );

        run_tboot_initrd.expectExitCode(0);

        const cpio_archive = b.addInstallFile(
            cpio_output_file,
            "tboot-loader.cpio",
        );

        // install the cpio archive during "zig build install"
        b.getInstallStep().dependOn(&cpio_archive.step);

        const tboot_runner = b.addExecutable(.{
            .name = "tboot-runner",
            .target = b.graph.host,
            .root_source_file = b.path("src/runner.zig"),
        });
        tboot_runner.root_module.addImport("clap", clap.module("clap"));
        const runner_tool = b.addRunArtifact(tboot_runner);
        runner_tool.step.dependOn(&cpio_archive.step);
        runner_tool.addArg(@tagName(target.result.cpu.arch));
        runner_tool.addArg(b.makeTempPath());
        runner_tool.addArg(if (runner_keydir) |keydir| keydir else "");
        runner_tool.addFileArg(cpio_archive.source);
        runner_tool.addArg(if (runner_kernel) |kernel| kernel else "");

        // Extra arguments passed through to qemu. We add our own '--' since
        // zig-clap will accept variadic extra arguments only after the
        // '--', which `zig build ...` already excepts.
        if (b.args) |args| {
            runner_tool.addArg("--");
            runner_tool.addArgs(args);
        }

        const run_step = b.step("run", "Run in qemu");
        run_step.dependOn(&runner_tool.step);
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
