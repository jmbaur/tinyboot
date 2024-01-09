const std = @import("std");
const builtin = @import("builtin");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const coreboot_support = b.option(bool, "coreboot", "Support for coreboot integration") orelse true;
    const tboot_loader_options = b.addOptions();
    tboot_loader_options.addOption(bool, "coreboot_support", coreboot_support);

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    var optimize = b.standardOptimizeOption(.{});

    const tboot_loader = b.addExecutable(.{
        .name = "tboot-loader",
        .root_source_file = .{ .path = "src/tboot-loader.zig" },
        .target = target,
        .optimize = if (optimize == std.builtin.OptimizeMode.Debug)
            std.builtin.OptimizeMode.Debug
        else
            std.builtin.OptimizeMode.ReleaseSmall,
    });

    tboot_loader.addOptions("build_options", tboot_loader_options);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(tboot_loader);

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

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const qemu_system_cmd = switch (builtin.target.cpu.arch) {
        .aarch64 => "qemu-system-aarch64",
        .x86_64 => "qemu-system-x86_64",
        else => @compileError("don't know how to run qemu on build system"),
    };

    const run_cmd = b.addSystemCommand(&.{
        qemu_system_cmd,
        "-nographic",
        "smp",
        "2",
        "-m",
        "2G",
        "fw_cfg",
        "name=opt/org.tboot/pubkey,file=TODO",
        "-netdev",
        "user,id=n1",
        "-device",
        "virtio-net-pci,netdev=n1",
        "-chardev",
        "socket,id=chrtpm,path=TODO",
        "-tpmdev",
        "emulator,id=tpm0,chardev=chrtpm",
    });

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app in qemu");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/test.zig" },
        .target = target,
        .optimize = optimize,
    });
    unit_tests.addOptions("build_options", tboot_loader_options);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
