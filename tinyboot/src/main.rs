use nix::{
    self,
    mount::{self, MsFlags},
};

const NONE: Option<&'static [u8]> = None;

fn mount_pseudofilesystems() -> anyhow::Result<()> {
    std::fs::create_dir_all("/sys")?;
    std::fs::create_dir_all("/tmp")?;
    std::fs::create_dir_all("/dev")?;
    std::fs::create_dir_all("/proc")?;
    mount::mount(
        NONE,
        "/sys",
        Some("sysfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC | MsFlags::MS_RELATIME,
        NONE,
    )?;
    mount::mount(
        NONE,
        "/tmp",
        Some("tmpfs"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
        NONE,
    )?;
    mount::mount(NONE, "/dev", Some("devtmpfs"), MsFlags::MS_NOSUID, NONE)?;
    mount::mount(
        NONE,
        "/proc",
        Some("proc"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
        NONE,
    )?;

    Ok(())
}

fn main() -> anyhow::Result<()> {
    println!("tinyboot started");

    mount_pseudofilesystems()?;

    _ = std::process::Command::new("/bin/sh").spawn()?.wait()?;

    Ok(())
}
