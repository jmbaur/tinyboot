use nix::libc;
use std::{os::fd::AsRawFd, process::Stdio, thread::sleep, time::Duration};

fn update() -> anyhow::Result<()> {
    _ = tboot::system::setup_system();

    let stdout = std::fs::OpenOptions::new().append(true).open("/dev/kmsg")?;

    unsafe { libc::dup2(stdout.as_raw_fd(), libc::STDOUT_FILENO) };
    unsafe { libc::dup2(stdout.as_raw_fd(), libc::STDERR_FILENO) };

    let mut flashrom = std::process::Command::new("/bin/flashrom");
    let mut args = std::env::args();

    if let Some(programmer_arg) = args.find(|arg| arg.starts_with("flashrom.programmer=")) {
        let programmer = programmer_arg.strip_prefix("flashrom.programmer=").unwrap();

        println!("using flashrom programmer {}", programmer);

        let output = flashrom
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .args(&[
                "-p",
                programmer,
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
