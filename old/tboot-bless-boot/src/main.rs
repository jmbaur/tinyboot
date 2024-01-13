use std::{
    fmt::Display,
    path::{Path, PathBuf},
    str::FromStr,
};

use argh::FromArgs;
use tboot::bls::BlsEntryMetadata;

#[derive(Debug)]
enum Error {
    Io(std::io::Error),
    MissingBlsEntry,
    InvalidArgs,
    MissingEntry,
}

impl Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self)
    }
}

impl From<std::io::Error> for Error {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

#[derive(Debug)]
enum Commands {
    Good,
    Bad,
    Status,
}

impl FromStr for Commands {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "good" => Self::Good,
            "bad" => Self::Bad,
            "status" => Self::Status,
            _ => return Err(Error::InvalidArgs),
        })
    }
}

#[derive(FromArgs, Debug)]
/// Mark the boot process as good or bad
struct Args {
    /// the mount point of the ESP
    #[argh(option)]
    efi_sys_mount_point: PathBuf,
    /// the action for tboot-bless-boot to take
    #[argh(positional)]
    command: Commands,
}

fn main() -> Result<(), Error> {
    let args: Args = argh::from_env();

    let kernel_cmdline = std::fs::read_to_string("/proc/cmdline")?;

    let tboot_bls_entry = kernel_cmdline
        .trim()
        .split_whitespace()
        .into_iter()
        .find_map(|cmdline_part| cmdline_part.strip_prefix("tboot.bls-entry="))
        .ok_or(Error::MissingBlsEntry)?;

    let entry = find_entry(args.efi_sys_mount_point.as_path(), tboot_bls_entry)
        .ok_or(Error::MissingEntry)?;

    match args.command {
        Commands::Good => mark_as_good(entry)?,
        Commands::Bad => mark_as_bad(entry)?,
        Commands::Status => print_status(entry),
    }

    Ok(())
}

fn find_entry(esp: impl AsRef<Path>, entry_name: &str) -> Option<(PathBuf, BlsEntryMetadata)> {
    let entries_dir = std::fs::read_dir(esp.as_ref().join("loader/entries")).ok()?;

    for entry in entries_dir {
        let Ok(entry) = entry else {
            continue;
        };

        if !entry.metadata().map(|md| md.is_file()).unwrap_or_default() {
            continue;
        }

        let filename = entry.file_name();
        let filename = filename.to_str().expect("invalid UTF-8");

        if let Ok(bls_entry) = tboot::bls::parse_entry_filename(filename) {
            if bls_entry.0 == entry_name {
                return Some((entry.path(), bls_entry));
            }
        }
    }

    None
}

fn mark_as_good(
    (entry_path, (name, tries_left, _tries_done)): (PathBuf, BlsEntryMetadata),
) -> Result<(), Error> {
    let Some(parent) = entry_path.parent() else {
        return Ok(());
    };

    let new_entry_path = parent.join(format!("{}.conf", name));
    if tries_left.is_some() {
        std::fs::rename(entry_path, new_entry_path)?;
    }

    Ok(())
}

fn mark_as_bad(
    (entry_path, (name, _tries_left, tries_done)): (PathBuf, BlsEntryMetadata),
) -> Result<(), Error> {
    let Some(parent) = entry_path.parent() else {
        return Ok(());
    };

    let new_entry_path = parent.join(if let Some(tries_done) = tries_done {
        format!("{}+0-{}.conf", name, tries_done)
    } else {
        format!("{}+0.conf", name)
    });
    std::fs::rename(entry_path, new_entry_path)?;

    Ok(())
}

fn print_status((entry_path, (_name, tries_left, _tries_done)): (PathBuf, BlsEntryMetadata)) {
    println!("{}:", entry_path.display());

    if let Some(tries_left) = tries_left {
        if tries_left > 0 {
            println!("\t{} tries left until entry is bad", tries_left);
        } else {
            println!("\tentry is bad");
        }
    } else {
        println!("\tentry is good");
    }
}
