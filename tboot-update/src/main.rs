use nix::libc;
use std::{os::fd::AsRawFd, process::Stdio, thread::sleep, time::Duration};

fn update() -> anyhow::Result<()> {
    tboot::system::setup_system()?;

    let stdout = std::fs::OpenOptions::new()
        .read(true)
        .create(true)
        .open("/dev/kmsg")?;

    unsafe { libc::dup2(stdout.as_raw_fd(), libc::STDOUT_FILENO) };
    unsafe { libc::dup2(stdout.as_raw_fd(), libc::STDERR_FILENO) };

    let mut flashrom = std::process::Command::new("/bin/flashrom");
    let mut args = std::env::args();

    if let Some(programmer_arg) = args.find(|arg| arg.starts_with("flashrom.programmer=")) {
        let programmer = programmer_arg.strip_prefix("flashrom.programmer=").unwrap();
        let exit = flashrom
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .args(&[
                "--programmer",
                programmer,
                "--write",
                "/update.rom",
                "--fmap",
                "-i",
                "RW_SECTION_A",
            ])
            .spawn()?
            .wait()?;

        if exit.success() {
            println!("flashrom succeeded");
        } else {
            eprintln!("flashrom failed with status {}", exit.code().unwrap());
        }
    } else {
        eprintln!("missing flashrom.programmer arg!");
    }

    Ok(())
}

fn main() {
    if let Err(e) = update() {
        eprintln!("failed to update: {}", e);
    }

    println!("rebooting in 5 seconds");
    sleep(Duration::from_secs(5));

    unsafe {
        libc::reboot(libc::LINUX_REBOOT_CMD_RESTART);
    }
}
