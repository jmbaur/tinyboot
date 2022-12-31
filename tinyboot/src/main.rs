use boot::booter::{BootParts, Booter};
use boot::syslinux;
use log::{debug, error, info};
use nix::mount::{self, MsFlags};
use simplelog::{Config, LevelFilter, SimpleLogger};
use std::io::{self, Read, Seek};
use std::path::{Path, PathBuf};
use std::{convert, fs, process};

const NONE: Option<&'static [u8]> = None;

fn mount_pseudofilesystems() -> anyhow::Result<()> {
    fs::create_dir_all("/mnt")?;
    fs::create_dir_all("/sys")?;
    fs::create_dir_all("/tmp")?;
    fs::create_dir_all("/dev")?;
    fs::create_dir_all("/proc")?;
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
    Ok(fs::read_dir("/sys/class/block")?
        .into_iter()
        .filter_map(|blk_dev| {
            if blk_dev.is_err() {
                return None;
            }
            let direntry = blk_dev.expect("not err");
            let mut path = direntry.path();
            path.push("uevent");
            match fs::read_to_string(path).map(|uevent| {
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

fn shell(sh: &str) -> Result<(), convert::Infallible> {
    _ = process::Command::new(sh)
        .spawn()
        .expect("emergency shell failed to run")
        .wait()
        .expect("emergency shell was not running");
    Ok(())
}

fn detect_fs_type(p: &Path) -> anyhow::Result<String> {
    let mut f = fs::File::open(p)?;
    f.seek(io::SeekFrom::Start(1080))?;
    let mut buffer = [0; 2];
    f.read_exact(&mut buffer)?;
    let comp_buf = &nix::sys::statfs::EXT4_SUPER_MAGIC.0.to_le_bytes()[0..2];

    if buffer == comp_buf {
        return Ok(String::from("ext4"));
    }

    anyhow::bail!("unsupported fs type")
}

fn logic() -> anyhow::Result<()> {
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

            if let Err(e) = fs::create_dir_all(&mountpoint) {
                error!("{e}");
                return None;
            }

            let Ok(fstype) = detect_fs_type(dev) else { return None; };
            debug!(
                "detected {} fstype on {}",
                fstype,
                dev.to_str().expect("invalid unicode")
            );

            if let Err(e) = nix::mount::mount(
                Some(dev.as_path()),
                &mountpoint,
                Some(fstype.as_str()),
                nix::mount::MsFlags::MS_RDONLY,
                NONE,
            ) {
                error!("{e}");
                return None;
            };

            match syslinux::Syslinux::new(&mountpoint).map(|s| s.get_parts()) {
                Ok(Ok(p)) => Some(p),
                e => {
                    error!("{e:#?}");
                    None
                }
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
        _ = io::stdin().read_line(&mut input)?;
        let selection = match input.trim().parse::<usize>() {
            Ok(x) if 0 < x || x < parts.len() - 1 => x,
            _ => {
                println!("bad selection");
                continue;
            }
        };

        break 'input &parts[selection + 1];
    };

    debug!("{selected}");
    selected.kexec()?;

    Ok(())
}

fn main() -> Result<(), convert::Infallible> {
    SimpleLogger::init(LevelFilter::Info, Config::default()).expect("failed to configure logger");
    info!("tinyboot started");
    if let Err(e) = logic() {
        error!("{e}");
        return shell(option_env!("TINYBOOT_EMERGENCY_SHELL").unwrap_or("/bin/sh"));
    };
    unreachable!();
}
