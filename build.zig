const std = @import("std");

// TODO(jared): Get this automatically from importing the information in
// build.zig.zon.
const version = std.SemanticVersion.parse("0.1.0") catch @compileError("invalid version");

fn tbootInitrd(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
) *std.Build.Step.Compile {
    const zstd_dependency = b.dependency("zstd", .{ .target = target, .optimize = optimize });
    const zstd = zstd_dependency.artifact("zstd");

    const clap_dependency = b.dependency("clap", .{ .target = target, .optimize = optimize });
    const clap = clap_dependency.module("clap");

    const zstd_h = b.addWriteFile(
        "zstd.h",
        \\#include <zstd.h>
        ,
    );
    const zstd_translate_c = b.addTranslateC(.{
        .root_source_file = .{ .generated = .{ .index = zstd_h.generated_directory, .sub_path = "zstd.h" } },
        .target = target,
        .optimize = optimize,
    });
    const zstd_module = b.createModule(.{
        .root_source_file = b.path("src/zstd.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zstd_module.linkLibrary(zstd);
    zstd_module.addImport("zstd_c", zstd_translate_c.createModule());

    const tboot_initrd_module = b.createModule(.{
        .root_source_file = b.path("src/tboot-initrd.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
    });
    const tboot_initrd = b.addExecutable(.{
        .name = "tboot-initrd",
        .root_module = tboot_initrd_module,
    });
    tboot_initrd.root_module.addImport("zstd", zstd_module);
    tboot_initrd.root_module.addImport("clap", clap);

    return tboot_initrd;
}

pub fn build(b: *std.Build) !void {
    const tboot_builtin = b.addOptions();
    tboot_builtin.addOption(
        []const u8,
        "version",
        try std.fmt.allocPrint(b.allocator, "{f}", .{version}),
    );

    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });

    const linux_target = b: {
        var linux_target = target.query;
        linux_target.abi = null;
        linux_target.os_tag = .linux;
        break :b b.resolveTargetQuery(linux_target);
    };

    const uefi_target = b: {
        var uefi_target = target.query;
        uefi_target.os_tag = .uefi;
        uefi_target.abi = .msvc;
        break :b b.resolveTargetQuery(uefi_target);
    };

    const optimize = b.standardOptimizeOption(.{});

    const do_strip = optimize != std.builtin.OptimizeMode.Debug;

    // For certain outputs of this project, we always use release small (if we
    // are in release mode). Smallest size is our goal in order to minimize
    // footprint on flash.
    const optimize_prefer_small = if (optimize == std.builtin.OptimizeMode.Debug)
        std.builtin.OptimizeMode.Debug
    else
        std.builtin.OptimizeMode.ReleaseSmall;

    const with_loader_efi_stub = b.option(
        bool,
        "loader-efi-stub",
        "With boot loader EFI stub (not available on all architectures)",
    ) orelse
        // We get the following error when attempting to build for armv7, so we
        // default to not building the EFI stub for this architecture.
        //
        // "error: the following command terminated unexpectedly"
        !target.result.cpu.arch.isArm();

    const firmware_directory = b.option(
        []const u8,
        "firmware-directory",
        "Firmware directory to put in /lib/firmware of the initrd",
    );

    const runner_keydir = b.option([]const u8, "keydir", "Directory of keys to use when spawning VM runner (as output by tboot-keygen)");

    const runner_kernel = b.option([]const u8, "kernel", "Kernel to use when spawning VM runner") orelse b.graph.environ_map.get("TINYBOOT_KERNEL");

    const clap_dependency = b.dependency("clap", .{});
    const clap = clap_dependency.module("clap");
    const mbedtls_dependency = b.dependency("mbedtls", .{ .target = target, .optimize = optimize });
    const mbedtls = mbedtls_dependency.artifact("mbedtls");

    const linux_h = b.addWriteFile("linux.h",
        \\#include <asm-generic/setup.h>
        \\#include <linux/kexec.h>
        \\#include <linux/keyctl.h>
        \\#include <linux/major.h>
        \\#include <sys/epoll.h>
        \\#include <sys/ioctl.h>
        \\#include <termios.h>
        \\
    ++ @embedFile("vendor/liveupdate.h"));

    const linux_headers = b.addTranslateC(.{
        .root_source_file = .{ .generated = .{ .index = linux_h.generated_directory, .sub_path = "linux.h" } },
        .target = linux_target,
        .optimize = .ReleaseSafe, // This doesn't seem to do anything when translating pure headers
    });

    const linux_headers_module = linux_headers.addModule("linux_headers");

    const mbedtls_h = b.addWriteFile("mbedtls.h",
        \\#include <mbedtls/ctr_debug.h>
        \\#include <mbedtls/entropy.h>
        \\#include <mbedtls/error.h>
        \\#include <mbedtls/pk.h>
        \\#include <mbedtls/rsa.h>
        \\#include <mbedtls/x509_crt.h>
        \\#include <time.h>
    );
    const mbedtls_translate_c = b.addTranslateC(.{
        .root_source_file = .{ .generated = .{ .index = mbedtls_h.generated_directory, .sub_path = "mbedtls.h" } },
        .target = target,
        .optimize = optimize,
    });
    const mbedtls_module = b.createModule(.{
        .root_source_file = b.path("src/mbedtls.zig"),
        .target = target,
        .optimize = optimize,
    });
    mbedtls_module.linkLibrary(mbedtls);
    mbedtls_module.addImport("mbedtls_c", mbedtls_translate_c.createModule());

    b.installArtifact(tbootInitrd(b, target, optimize, do_strip));

    const tboot_sign_module = b.createModule(.{
        .root_source_file = b.path("src/tboot-sign.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });
    const tboot_sign = b.addExecutable(.{
        .name = "tboot-sign",
        .root_module = tboot_sign_module,
    });
    tboot_sign.root_module.link_libc = true;
    tboot_sign.root_module.addImport("clap", clap);
    tboot_sign.root_module.addImport("mbedtls", mbedtls_module);
    b.installArtifact(tboot_sign);

    const tboot_keygen_module = b.createModule(.{
        .root_source_file = b.path("src/tboot-keygen.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });
    const tboot_keygen = b.addExecutable(.{
        .name = "tboot-keygen",
        .root_module = tboot_keygen_module,
    });
    tboot_keygen.root_module.link_libc = true;
    tboot_keygen.root_module.linkLibrary(mbedtls);
    tboot_keygen.root_module.addImport("clap", clap);
    tboot_keygen.root_module.addImport("mbedtls", mbedtls_module);
    b.installArtifact(tboot_keygen);

    const tboot_vpd_module = b.createModule(.{
        .root_source_file = b.path("src/vpd.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });
    const tboot_vpd = b.addExecutable(.{
        .name = "tboot-vpd",
        .root_module = tboot_vpd_module,
    });
    tboot_vpd.root_module.addImport("clap", clap);
    b.installArtifact(tboot_vpd);

    // tboot-ymodem, tboot-bless-boot, tboot-bless-boot-generator, and
    // tboot-nixos-install (for nixos machines) run on the machine using
    // tboot-loader, so it doesn't make sense to build for non-linux targets.
    if (target.result.os.tag == .linux) {
        // TODO(jared): get tboot-ymodem working on non-linux targets
        const tboot_ymodem_module = b.createModule(.{
            .root_source_file = b.path("src/ymodem.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
        });
        const tboot_ymodem = b.addExecutable(.{
            .name = "tboot-ymodem",
            .root_module = tboot_ymodem_module,
        });
        tboot_ymodem.root_module.addImport("linux_headers", linux_headers_module);
        tboot_ymodem.root_module.addImport("clap", clap);
        b.installArtifact(tboot_ymodem);

        const tboot_bless_boot_module = b.createModule(.{
            .root_source_file = b.path("src/tboot-bless-boot.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
        });
        const tboot_bless_boot = b.addExecutable(.{
            .name = "tboot-bless-boot",
            .root_module = tboot_bless_boot_module,
        });
        tboot_bless_boot.root_module.addImport("linux_headers", linux_headers_module);
        tboot_bless_boot.root_module.addImport("clap", clap);
        b.installArtifact(tboot_bless_boot);

        const tboot_bless_boot_generator_module = b.createModule(.{
            .root_source_file = b.path("src/tboot-bless-boot-generator.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
        });
        const tboot_bless_boot_generator = b.addExecutable(.{
            .name = "tboot-bless-boot-generator",
            .root_module = tboot_bless_boot_generator_module,
        });
        tboot_bless_boot_generator.root_module.addImport("clap", clap);
        b.installArtifact(tboot_bless_boot_generator);

        const tboot_nixos_install_module = b.createModule(.{
            .root_source_file = b.path("src/tboot-nixos-install.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
        });
        const tboot_nixos_install = b.addExecutable(.{
            .name = "tboot-nixos-install",
            .root_module = tboot_nixos_install_module,
        });
        tboot_nixos_install.root_module.link_libc = true;
        tboot_nixos_install.root_module.addImport("mbedtls", mbedtls_module);
        tboot_nixos_install.root_module.addImport("clap", clap);
        b.installArtifact(tboot_nixos_install);
    }

    const tboot_loader_module = b.createModule(.{
        .root_source_file = b.path("src/tboot-loader.zig"),
        .target = linux_target,
        .optimize = optimize_prefer_small,
        .strip = do_strip,
    });
    const tboot_loader = b.addExecutable(.{
        .name = "tboot-loader",
        .root_module = tboot_loader_module,
    });
    tboot_loader.root_module.addOptions("tboot_builtin", tboot_builtin);
    tboot_loader.root_module.addImport("linux_headers", linux_headers_module);

    // Use tboot-initrd built for the build host.
    var run_tboot_initrd = b.addRunArtifact(tbootInitrd(b, b.graph.host, .Debug, false));

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

    const initrd_output_file = run_tboot_initrd.addPrefixedOutputFileArg(
        "-o",
        "tboot-loader.cpio.zst",
    );

    run_tboot_initrd.expectExitCode(0);

    const initrd_file = b.addInstallFile(
        initrd_output_file,
        "tboot-loader.cpio.zst",
    );

    // install the cpio archive during "zig build install"
    b.getInstallStep().dependOn(&initrd_file.step);

    if (with_loader_efi_stub) {
        const tboot_efi_stub_module = b.createModule(.{
            .target = uefi_target,
            .root_source_file = b.path("src/tboot-efi-stub.zig"),
            .optimize = optimize_prefer_small,
            .strip = do_strip,
        });
        const tboot_efi_stub = b.addExecutable(.{
            .name = "tboot-efi-stub",
            .root_module = tboot_efi_stub_module,
        });
        const tboot_efi_stub_artifact = b.addInstallArtifact(tboot_efi_stub, .{
            .dest_dir = .{ .override = .{ .custom = "efi" } },
        });
        b.getInstallStep().dependOn(&tboot_efi_stub_artifact.step);
    }

    const tboot_runner_module = b.createModule(.{
        .target = b.graph.host,
        .root_source_file = b.path("src/runner.zig"),
    });
    const tboot_runner = b.addExecutable(.{
        .name = "tboot-runner",
        .root_module = tboot_runner_module,
    });
    tboot_runner.root_module.addImport("clap", clap);
    const runner_tool = b.addRunArtifact(tboot_runner);
    runner_tool.step.dependOn(&initrd_file.step);
    runner_tool.addArg(@tagName(target.result.cpu.arch));
    runner_tool.addArg(if (runner_keydir) |keydir| keydir else "");
    runner_tool.addFileArg(initrd_file.source);
    runner_tool.addArg(if (runner_kernel) |kernel| try std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, kernel, b.allocator) else "");

    // Extra arguments passed through to qemu. We add our own '--' since
    // zig-clap will accept variadic extra arguments only after the
    // '--', which `zig build ...` already excepts.
    runner_tool.addArg("--");
    runner_tool.addPassthruArgs();

    const run_step = b.step("run", "Run in qemu");
    run_step.dependOn(&runner_tool.step);

    const unit_tests_module = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .root_module = unit_tests_module,
    });

    unit_tests.root_module.addImport("linux_headers", linux_headers_module);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
