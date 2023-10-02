use nix::libc;
use std::{os::fd::AsRawFd, process::Stdio, thread::sleep, time::Duration};

fn update() -> anyhow::Result<()> {
    _ = tboot::system::setup_system();

    let args: Vec<String> = std::env::args().collect();
    let cfg = tboot::config::Config::parse_from(&args)?;

    if let Ok(tty) = std::fs::OpenOptions::new().write(true).open(cfg.tty) {
        let fd = tty.as_raw_fd();
        unsafe { libc::dup2(fd, libc::STDOUT_FILENO) };
        unsafe { libc::dup2(fd, libc::STDERR_FILENO) };
        _ = tboot::system::setup_tty(fd);
    }

    let mut flashrom = std::process::Command::new("/bin/flashrom");

    println!("using flashrom programmer {}", cfg.programmer);

    let output = flashrom
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .args(&[
            "-p",
            cfg.programmer,
            "-w",
            "/update.rom",
            "--fmap",
            "-i",
            "RW_SECTION_A",
        ])
        .spawn()?
        .wait_with_output()?;

    if output.status.success() {
        println!("flashrom succeeded");
    } else {
        eprintln!(
            "flashrom failed with status {}",
            output.status.code().unwrap()
        );
        eprintln!(
            "flashrom error output:\n{}",
            String::from_utf8(output.stderr).expect("stderr not utf8")
        );
    }

    Ok(())
}

fn main() {
    if let Err(e) = update() {
        eprintln!("failed to update: {}", e);
    }

    for i in 0..6 {
        println!("rebooting in {} seconds", 5 - i);
        sleep(Duration::from_secs(1));
    }

    unsafe {
        libc::reboot(libc::LINUX_REBOOT_CMD_RESTART);
    }
}
