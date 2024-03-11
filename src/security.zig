const std = @import("std");

pub const IMA_POLICY_PATH = "/sys/kernel/security/ima/policy";

// PROC_SUPER_MAGIC = 0x9fa0
pub const PROC_SUPER_MAGIC = withNewline("dont_measure fsmagic=0x9fa0");

// SYSFS_MAGIC = 0x62656572
pub const SYSFS_MAGIC = withNewline("dont_measure fsmagic=0x62656572");

// DEBUGFS_MAGIC = 0x64626720
pub const DEBUGFS_MAGIC = withNewline("dont_measure fsmagic=0x64626720");

// TMPFS_MAGIC = 0x01021994
pub const TMPFS_MAGIC = withNewline("dont_measure fsmagic=0x1021994");

// DEVPTS_SUPER_MAGIC=0x1cd1
pub const DEVPTS_SUPER_MAGIC = withNewline("dont_measure fsmagic=0x1cd1");

// BINFMTFS_MAGIC=0x42494e4d
pub const BINFMTFS_MAGIC = withNewline("dont_measure fsmagic=0x42494e4d");

// SECURITYFS_MAGIC=0x73636673
pub const SECURITYFS_MAGIC = withNewline("dont_measure fsmagic=0x73636673");

// SELINUX_MAGIC=0xf97cff8c
pub const SELINUX_MAGIC = withNewline("dont_measure fsmagic=0xf97cff8c");

// SMACK_MAGIC=0x43415d53
pub const SMACK_MAGIC = withNewline("dont_measure fsmagic=0x43415d53");

// CGROUP_SUPER_MAGIC=0x27e0eb
pub const CGROUP_SUPER_MAGIC = withNewline("dont_measure fsmagic=0x27e0eb");

// CGROUP2_SUPER_MAGIC=0x63677270
pub const CGROUP2_SUPER_MAGIC = withNewline("dont_measure fsmagic=0x63677270");

// NSFS_MAGIC=0x6e736673
pub const NSFS_MAGIC = withNewline("dont_measure fsmagic=0x6e736673");

pub const KEY_CHECK = withNewline("measure func=KEY_CHECK pcr=7");

pub const POLICY_CHECK = withNewline("measure func=POLICY_CHECK pcr=7");

pub const KEXEC_KERNEL_CHECK = withNewline("measure func=KEXEC_KERNEL_CHECK pcr=8");

pub const KEXEC_INITRAMFS_CHECK = withNewline("measure func=KEXEC_INITRAMFS_CHECK pcr=9");

pub const KEXEC_CMDLINE = withNewline("measure func=KEXEC_CMDLINE pcr=12");

pub const KEXEC_KERNEL_CHECK_APPRAISE = withNewline("appraise func=KEXEC_KERNEL_CHECK appraise_type=imasig|modsig");

pub const KEXEC_INITRAMFS_CHECK_APPRAISE = withNewline("appraise func=KEXEC_INITRAMFS_CHECK appraise_type=imasig|modsig");

pub fn install_ima_policy(allocator: std.mem.Allocator, policy_entries: []const []const u8) !void {
    const policy = try std.mem.join(allocator, "", policy_entries);
    defer allocator.free(policy);

    var policy_file = try std.fs.openFileAbsolute(IMA_POLICY_PATH, .{ .mode = .write_only });
    defer policy_file.close();

    std.log.debug("writing IMA policy", .{});

    try policy_file.writeAll(policy);
}

const Error = error{
    KeyNotFound,
};

pub fn load_verification_key() !void {
    // TODO
    return Error.KeyNotFound;
}

// Initialize the IMA subsystem in linux to perform measurements and optionally
// appraisals (verification) of boot components. We always do measured boot
// with IMA since we basically get it for free; measurements are held in memory
// and persisted across kexecs, and the measurements are extended to the
// system's TPM if one is available.
pub fn initialize_security(allocator: std.mem.Allocator) !void {
    var ima_policy = std.ArrayList([]const u8).init(allocator);
    defer ima_policy.deinit();

    try ima_policy.appendSlice(&.{
        PROC_SUPER_MAGIC,
        SYSFS_MAGIC,
        DEBUGFS_MAGIC,
        TMPFS_MAGIC,
        DEVPTS_SUPER_MAGIC,
        BINFMTFS_MAGIC,
        SECURITYFS_MAGIC,
        SELINUX_MAGIC,
        SMACK_MAGIC,
        CGROUP_SUPER_MAGIC,
        CGROUP2_SUPER_MAGIC,
        NSFS_MAGIC,
        KEY_CHECK,
        POLICY_CHECK,
        KEXEC_KERNEL_CHECK,
        KEXEC_INITRAMFS_CHECK,
        KEXEC_CMDLINE,
    });

    var do_verified_boot = true;
    load_verification_key() catch |err| {
        std.log.warn("failed to load verification key, cannot perform boot verification: {}", .{err});
        do_verified_boot = false;
    };

    if (do_verified_boot) {
        try ima_policy.appendSlice(&.{
            KEXEC_KERNEL_CHECK_APPRAISE,
            KEXEC_INITRAMFS_CHECK_APPRAISE,
        });

        std.log.info("boot verification is enabled", .{});
    }

    try install_ima_policy(allocator, ima_policy.items);
}

// Each line in an IMA policy, including the last line, needs to be terminated
// with a single line feed.
fn withNewline(comptime line: []const u8) []const u8 {
    return line ++ "\n";
}
