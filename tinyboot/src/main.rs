use boot::booter::{BootParts, Booter};
use boot::syslinux;
use log::LevelFilter;
use log::{debug, error, info};
use nix::mount;
use std::io::{self, Read, Seek};
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::{convert, env, fs, process};

const NONE: Option<&'static [u8]> = None;

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

    {
        f.seek(io::SeekFrom::Start(3))?;
        let mut buffer = [0; 8];
        f.read_exact(&mut buffer)?;
        if let Ok("mkfs.fat") = std::str::from_utf8(&buffer) {
            return Ok(String::from("fat"));
        }
    }

    {
        f.seek(io::SeekFrom::Start(1080))?;
        let mut buffer = [0; 2];
        f.read_exact(&mut buffer)?;
        let comp_buf = &nix::sys::statfs::EXT4_SUPER_MAGIC.0.to_le_bytes()[0..2];
        if buffer == comp_buf {
            return Ok(String::from("ext4"));
        }
    }

    anyhow::bail!("unsupported fs type")
}

fn logic() -> anyhow::Result<()> {
    let parts = find_block_devices()?
        .iter()
        .filter_map(|dev| {
            let mountpoint = PathBuf::from("/mnt").join(
                dev.to_str()
                    .expect("invalid unicode")
                    .trim_start_matches('/')
                    .replace('/', "-"),
            );

            let Ok(fstype) = detect_fs_type(dev) else { return None; };
            debug!(
                "detected {} fstype on {}",
                fstype,
                dev.to_str().expect("invalid unicode")
            );

            if let Err(e) = fs::create_dir_all(&mountpoint) {
                error!("{e}");
                return None;
            }

            if let Err(e) = nix::mount::mount(
                Some(dev.as_path()),
                &mountpoint,
                Some(fstype.as_str()),
                mount::MsFlags::MS_RDONLY,
                NONE,
            ) {
                error!("{e}");
                return None;
            };

            debug!("mounted {} at {}", dev.display(), mountpoint.display());

            match syslinux::Syslinux::new(&mountpoint).map(|s| s.get_parts()) {
                Ok(Ok(p)) => Some(p),
                e => {
                    match e {
                        Ok(Err(e)) => error!("failed to get boot parts: {}", e),
                        Err(e) => error!("failed to get syslinux config: {}", e),
                        _ => unreachable!(),
                    }
                    if let Err(e) = nix::mount::umount2(&mountpoint, mount::MntFlags::MNT_DETACH) {
                        error!("umount2: {e}");
                    }
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
        match input.trim().parse::<usize>() {
            Ok(x) if 0 < x || x < parts.len() - 1 => break 'input &parts[x - 1],
            _ => {
                println!("bad selection");
                continue;
            }
        };
    };

    selected.kexec()?;

    Ok(())
}

#[derive(Debug)]
struct Config {
    log_level: LevelFilter,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            log_level: LevelFilter::Info,
        }
    }
}

impl Config {
    pub fn new(args: &[String]) -> Self {
        let mut cfg = Config::default();

        args.iter().for_each(|arg| {
            if let Some(split) = arg.split_once('=') {
                // TODO(jared): remove when more cmdline options are added
                #[allow(clippy::single_match)]
                match split.0 {
                    "tinyboot.log" => {
                        cfg.log_level = LevelFilter::from_str(split.1).unwrap_or(LevelFilter::Info)
                    }
                    _ => {}
                }
            }
        });

        cfg
    }
}

fn main() -> Result<(), convert::Infallible> {
    let args: Vec<String> = env::args().collect();

    let cfg = Config::new(args.as_slice());

    printk::init("tinyboot", cfg.log_level).expect("failed to setup logger");

    info!("started");
    debug!("args: {:?}", args);
    debug!("config: {:?}", cfg);

    if let Err(e) = logic() {
        error!("failed to boot: {e}");
        return shell(option_env!("TINYBOOT_EMERGENCY_SHELL").unwrap_or("/bin/sh"));
    };

    unreachable!();
}
