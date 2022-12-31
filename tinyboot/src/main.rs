use boot::booter::{BootParts, Booter};
use nix::mount::{self, MsFlags};
use std::io::{Read, Seek};
use std::path::{Path, PathBuf};

const NONE: Option<&'static [u8]> = None;

fn mount_pseudofilesystems() -> anyhow::Result<()> {
    std::fs::create_dir_all("/mnt")?;
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

fn find_block_devices() -> anyhow::Result<Vec<PathBuf>> {
    Ok(std::fs::read_dir("/sys/class/block")?
        .into_iter()
        .filter_map(|blk_dev| {
            if blk_dev.is_err() {
                return None;
            }
            let direntry = blk_dev.expect("not err");
            let mut path = direntry.path();
            path.push("uevent");
            match std::fs::read_to_string(path).map(|uevent| {
                let mut is_partition = false;
                let mut dev_path = PathBuf::from("/dev");
                for line in uevent.lines() {
                    if line == "DEVTYPE=partition" {
                        is_partition = true;
                    }
                    if line.starts_with("DEVNAME") {
                        dev_path.push(line.split_once('=').expect("invalid DEVNAME").1);
                    }
                }
                (is_partition, dev_path)
            }) {
                Ok((true, dev_path)) => Some(dev_path),
                _ => None,
            }
        })
        .collect::<Vec<PathBuf>>())
}

fn shell(sh: &str) -> Result<(), std::convert::Infallible> {
    _ = std::process::Command::new(sh)
        .spawn()
        .expect("emergency shell failed to run")
        .wait()
        .expect("emergency shell was not running");
    Ok(())
}

fn detect_fs_type(p: &Path) -> anyhow::Result<String> {
    let mut f = std::fs::File::open(p)?;
    f.seek(std::io::SeekFrom::Start(1080))?;
    let mut buffer = [0; 2];
    f.read_exact(&mut buffer)?;
    let comp_buf = &nix::sys::statfs::EXT4_SUPER_MAGIC.0.to_le_bytes()[0..2];

    if buffer == comp_buf {
        return Ok(String::from("ext4"));
    }

    anyhow::bail!("unsupported fs type")
}

fn logic() -> anyhow::Result<()> {
    println!("tinyboot started");

    mount_pseudofilesystems()?;

    let parts = find_block_devices()?
        .iter()
        .filter_map(|dev| {
            let mountpoint = PathBuf::from("/mnt").join(
                dev.to_str()
                    .expect("invalid unicode")
                    .trim_start_matches('/')
                    .replace('/', "-"),
            );

            if let Err(e) = std::fs::create_dir_all(&mountpoint) {
                eprintln!("{e}");
                return None;
            }

            let Ok(fstype) = detect_fs_type(dev) else { return None; };

            if let Err(e) = nix::mount::mount(
                Some(dev.as_path()),
                &mountpoint,
                Some(fstype.as_str()),
                nix::mount::MsFlags::MS_RDONLY,
                NONE,
            ) {
                eprintln!("{e}");
                return None;
            };

            match boot::syslinux::Syslinux::new(&mountpoint)
                .map(|s| s.get_parts().ok())
                .ok()
            {
                Some(p) => p,
                _ => None,
            }
        })
        .flatten()
        .collect::<Vec<BootParts>>();

    if parts.is_empty() {
        anyhow::bail!("no bootable partitions found");
    }

    parts
        .iter()
        .enumerate()
        .for_each(|(i, part)| println!("{}: {part}\n", i + 1));

    let selected = 'input: loop {
        print!("choose a boot option: ");
        let mut input = String::new();
        _ = std::io::stdin().read_line(&mut input)?;
        let selection = match input.trim().parse::<usize>() {
            Ok(x) if 0 < x || x < parts.len() - 1 => x,
            _ => {
                println!("bad selection");
                continue;
            }
        };

        break 'input &parts[selection + 1];
    };

    selected.kexec()?;

    Ok(())
}

fn main() -> Result<(), std::convert::Infallible> {
    if let Err(e) = logic() {
        println!("{e}");
        return shell(std::option_env!("TINYBOOT_EMERGENCY_SHELL").unwrap_or("/bin/sh"));
    };
    unreachable!();
}
