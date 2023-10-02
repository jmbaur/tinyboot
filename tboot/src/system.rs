use std::{os::unix::prelude::PermissionsExt, process::Child};

use nix::mount::MsFlags;

pub fn setup_system() -> anyhow::Result<Child> {
    std::fs::create_dir_all("/proc").expect("faield to create /proc");
    std::fs::create_dir_all("/sys").expect("faield to create /sys");
    std::fs::create_dir_all("/dev").expect("faield to create /dev");
    std::fs::create_dir_all("/run").expect("faield to create /run");
    std::fs::create_dir_all("/mnt").expect("faield to create /mnt");

    nix::mount::mount(
        None::<&str>,
        "/proc",
        Some("proc"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
        None::<&str>,
    )
    .expect("failed to mount to /proc");

    nix::mount::mount(
        None::<&str>,
        "/dev",
        Some("devtmpfs"),
        MsFlags::MS_NOSUID,
        None::<&str>,
    )
    .expect("failed to mount to /dev");

    nix::mount::mount(
        None::<&str>,
        "/sys",
        Some("sysfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC | MsFlags::MS_RELATIME,
        None::<&str>,
    )
    .expect("failed to mount to /sys");

    nix::mount::mount(
        None::<&str>,
        "/run",
        Some("tmpfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
        None::<&str>,
    )
    .expect("failed to mount to /run");

    nix::mount::mount(
        None::<&str>,
        "/sys/kernel/security",
        Some("securityfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC | MsFlags::MS_RELATIME,
        None::<&str>,
    )
    .expect("failed to mount to /sys/kernel/securityfs");

    std::os::unix::fs::symlink("/proc/self/fd/0", "/dev/stdin")
        .expect("failed to link to /dev/stdin");
    std::os::unix::fs::symlink("/proc/self/fd/1", "/dev/stdout")
        .expect("failed to link to /dev/stdout");
    std::os::unix::fs::symlink("/proc/self/fd/2", "/dev/stderr")
        .expect("failed to link to /dev/stderr");

    // set permissions on /run
    let mut perms = std::fs::metadata("/run")
        .expect("failed to get metadata on /run")
        .permissions();
    perms.set_mode(0o777);
    std::fs::set_permissions("/run", perms).expect("failed to set permissions on /run");

    // TODO(jared): don't use mdevd
    let mdev = std::process::Command::new("/bin/mdevd").spawn()?;

    Ok(mdev)
}
