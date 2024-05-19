const std = @import("std");
const builtin = @import("builtin");

fn pathExists(p: []const u8) bool {
    std.fs.accessAbsolute(p, .{}) catch {
        return false;
    };

    return true;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var args = std.process.args();
    _ = args.next().?;
    const tmpdir = args.next().?;
    const initrd = args.next().?;
    const kernel = args.next().?;

    // get path to tboot key before changing directory
    const tboot_key = try std.fs.cwd().realpathAlloc(allocator, "test/keys/tboot/key.pem");

    try std.posix.chdir(tmpdir);

    var qemu_args = std.ArrayList([]const u8).init(allocator);

    try qemu_args.append(switch (builtin.target.cpu.arch) {
        .aarch64 => "qemu-system-aarch64",
        .x86_64 => "qemu-system-x86_64",
        else => @compileError("don't know how to run qemu on build system"),
    });

    if (builtin.target.os.tag == .linux and pathExists("/dev/kvm")) {
        try qemu_args.append("-enable-kvm");
    }

    try qemu_args.appendSlice(&.{ "-machine", switch (builtin.target.cpu.arch) {
        .aarch64 => "virt",
        .x86_64 => "q35",
        else => @compileError("don't know how to run qemu on build system"),
    } });

    // TODO(jared): "-drive", "if=virtio,file=TODO.raw,format=raw,media=disk"
    try qemu_args.appendSlice(&.{
        "-no-reboot",
        "-display",
        "none",
        "-serial",
        "stdio",
        "-serial",
        "pty",
        "-cpu",
        "max",
        "-smp",
        "2",
        "-m",
        "2G",
        "-netdev",
        "user,id=n1",
        "-device",
        "virtio-net-pci,netdev=n1",
        "-fw_cfg",
        try std.fmt.allocPrint(allocator, "name=opt/org.tboot/pubkey,file={s}", .{tboot_key}),
        "-initrd",
        initrd,
        "-kernel",
        kernel,
    });

    const swtpm_sock_path = try std.fs.path.join(allocator, &.{ tmpdir, "swtpm.sock" });
    try qemu_args.appendSlice(&.{
        "-chardev", try std.fmt.allocPrint(allocator, "socket,id=chrtpm,path={s}", .{swtpm_sock_path}),
        "-tpmdev",  "emulator,id=tpm0,chardev=chrtpm",
        "-device",
        switch (builtin.target.cpu.arch) {
            .aarch64 => "tpm-tis-device,tpmdev=tpm0",
            .x86_64 => "tpm-tis,tpmdev=tpm0",
            else => @compileError("don't know how to run qemu on build system"),
        },
    });

    while (args.next()) |arg| {
        try qemu_args.append(arg);
    }

    var swtpm_child = std.process.Child.init(&.{
        "swtpm",
        "socket",
        "--terminate",
        "--tpmstate",
        try std.fmt.allocPrint(allocator, "dir={s}", .{tmpdir}),
        "--ctrl",
        try std.fmt.allocPrint(allocator, "type=unixio,path={s}", .{swtpm_sock_path}),
        "--tpm2",
    }, allocator);
    try swtpm_child.spawn();
    defer _ = swtpm_child.kill() catch {};

    var qemu_child = std.process.Child.init(try qemu_args.toOwnedSlice(), allocator);
    _ = try qemu_child.spawnAndWait();
}
