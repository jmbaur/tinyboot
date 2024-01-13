pub const IMA_POLICY_PATH: &str = "/sys/kernel/security/ima/policy";

// PROC_SUPER_MAGIC = 0x9fa0
pub const PROC_SUPER_MAGIC: &str = "dont_measure fsmagic=0x9fa0";

// SYSFS_MAGIC = 0x62656572
pub const SYSFS_MAGIC: &str = "dont_measure fsmagic=0x62656572";

// DEBUGFS_MAGIC = 0x64626720
pub const DEBUGFS_MAGIC: &str = "dont_measure fsmagic=0x64626720";

// TMPFS_MAGIC = 0x01021994
pub const TMPFS_MAGIC: &str = "dont_measure fsmagic=0x1021994";

// DEVPTS_SUPER_MAGIC=0x1cd1
pub const DEVPTS_SUPER_MAGIC: &str = "dont_measure fsmagic=0x1cd1";

// BINFMTFS_MAGIC=0x42494e4d
pub const BINFMTFS_MAGIC: &str = "dont_measure fsmagic=0x42494e4d";

// SECURITYFS_MAGIC=0x73636673
pub const SECURITYFS_MAGIC: &str = "dont_measure fsmagic=0x73636673";

// SELINUX_MAGIC=0xf97cff8c
pub const SELINUX_MAGIC: &str = "dont_measure fsmagic=0xf97cff8c";

// SMACK_MAGIC=0x43415d53
pub const SMACK_MAGIC: &str = "dont_measure fsmagic=0x43415d53";

// CGROUP_SUPER_MAGIC=0x27e0eb
pub const CGROUP_SUPER_MAGIC: &str = "dont_measure fsmagic=0x27e0eb";

// CGROUP2_SUPER_MAGIC=0x63677270
pub const CGROUP2_SUPER_MAGIC: &str = "dont_measure fsmagic=0x63677270";

// NSFS_MAGIC=0x6e736673
pub const NSFS_MAGIC: &str = "dont_measure fsmagic=0x6e736673";

pub const KEY_CHECK: &str = "measure func=KEY_CHECK pcr=7";

pub const POLICY_CHECK: &str = "measure func=POLICY_CHECK pcr=7";

pub const KEXEC_KERNEL_CHECK: &str = "measure func=KEXEC_KERNEL_CHECK pcr=8";

pub const KEXEC_INITRAMFS_CHECK: &str = "measure func=KEXEC_INITRAMFS_CHECK pcr=9";

pub const KEXEC_CMDLINE: &str = "measure func=KEXEC_CMDLINE pcr=12";

pub const KEXEC_KERNEL_CHECK_APPRAISE: &str =
    "appraise func=KEXEC_KERNEL_CHECK appraise_type=imasig|modsig";

pub const KEXEC_INITRAMFS_CHECK_APPRAISE: &str =
    "appraise func=KEXEC_INITRAMFS_CHECK appraise_type=imasig|modsig";
