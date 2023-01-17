use crate::boot::boot_loader::{BootLoader, Error, MenuEntry};
use log::{debug, info, warn};
use std::{
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

#[derive(Default)]
struct BootEntry {
    default: bool,
    name: String,
    kernel: PathBuf,
    initrd: PathBuf,
    cmdline: String,
}

pub struct SyslinuxBootLoader {
    mountpoint: PathBuf,
    config_file: PathBuf,
    entries: Vec<BootEntry>,
    timeout: Duration,
}

fn syslinux_parse(config_file: &Path) -> Result<(Vec<BootEntry>, Duration), Error> {
    let contents = fs::read_to_string(config_file)?;

    let mut entries = vec![];
    let mut p = BootEntry::default();
    let mut default = String::new();
    let mut in_entry: Option<bool> = None;
    let mut timeout = Duration::from_secs(5);

    for line in contents.lines() {
        if !in_entry.unwrap_or_default() && line.starts_with("TIMEOUT") {
            timeout = Duration::from_secs(
                // https://wiki.syslinux.org/wiki/index.php?title=Config#TIMEOUT
                line.split_once("TIMEOUT ")
                    .ok_or(Error::InvalidConfigFormat)?
                    .1
                    .parse::<i32>()
                    .map(|timeout| {
                        if timeout <= 0 {
                            0u64
                        } else {
                            (timeout as u64) / 10
                        }
                    })
                    .unwrap_or(5),
            );
            continue;
        }

        if !in_entry.unwrap_or_default() && line.starts_with("DEFAULT") {
            default = String::from(
                line.split_once("DEFAULT ")
                    .ok_or(Error::InvalidConfigFormat)?
                    .1,
            );
            continue;
        }

        if line.starts_with("LABEL") {
            // We have already seen at least one entry, push the previous one into boot parts
            // and start a new one.
            if in_entry.is_some() {
                entries.push(p);
                p = BootEntry::default();
            }

            if default
                == line
                    .split_once("LABEL ")
                    .ok_or(Error::InvalidConfigFormat)?
                    .1
            {
                p.default = true;
            }

            in_entry = Some(true);
            continue;
        }
        if !in_entry.unwrap_or_default() {
            continue;
        }
        if line
            .trim_start_matches(char::is_whitespace)
            .starts_with("MENU LABEL")
        {
            p.name = String::from(
                line.split_once("MENU LABEL ")
                    .ok_or(Error::InvalidConfigFormat)?
                    .1,
            );
            continue;
        }

        if line
            .trim_start_matches(char::is_whitespace)
            .starts_with("LINUX")
        {
            p.kernel = config_file.parent().unwrap().join(PathBuf::from(
                line.split_once("LINUX ")
                    .ok_or(Error::InvalidConfigFormat)?
                    .1,
            ));
            continue;
        }

        if line
            .trim_start_matches(char::is_whitespace)
            .starts_with("INITRD")
        {
            p.initrd = config_file.parent().unwrap().join(PathBuf::from(
                line.split_once("INITRD ")
                    .ok_or(Error::InvalidConfigFormat)?
                    .1,
            ));
            continue;
        }

        if line
            .trim_start_matches(char::is_whitespace)
            .starts_with("APPEND")
        {
            p.cmdline = String::from(
                line.split_once("APPEND ")
                    .ok_or(Error::InvalidConfigFormat)?
                    .1,
            );
            continue;
        }

        if line.trim().is_empty() {
            in_entry = Some(false);
        }
    }

    // Include the last entry in boot parts.
    entries.push(p);

    Ok((entries, timeout))
}

impl SyslinuxBootLoader {
    pub fn new(mountpoint: &Path) -> Result<Self, Error> {
        for path in [
            "boot/extlinux/extlinux.conf",
            "extlinux/extlinux.conf",
            "extlinux.conf",
            "boot/syslinux/extlinux.conf",
            "boot/syslinux/syslinux.cfg",
            "syslinux/extlinux.conf",
            "syslinux/syslinux.cfg",
            "syslinux.cfg",
        ] {
            let search_path = mountpoint.join(path);

            debug!(
                "searching for syslinux configuration at {}",
                search_path.display()
            );

            if let Err(e) = fs::metadata(&search_path) {
                warn!("{}: {}", search_path.display(), e)
            } else {
                info!("found syslinux configuration at {}", search_path.display());
                let mut s = Self {
                    mountpoint: mountpoint.to_path_buf(),
                    config_file: search_path,
                    entries: Vec::new(),
                    timeout: Duration::from_secs(10),
                };
                s.parse()?;
                return Ok(s);
            }
        }

        Err(Error::BootConfigNotFound)
    }

    fn parse(&mut self) -> Result<(), Error> {
        let (entries, timeout) = syslinux_parse(&self.config_file)?;
        self.entries = entries;
        self.timeout = timeout;
        Ok(())
    }
}

impl BootLoader for SyslinuxBootLoader {
    fn timeout(&self) -> Duration {
        self.timeout
    }

    fn mountpoint(&self) -> &Path {
        &self.mountpoint
    }

    fn menu_entries(&self) -> std::result::Result<Vec<MenuEntry>, Error> {
        Ok(self
            .entries
            .iter()
            .map(|entry| MenuEntry::BootEntry((&entry.name, &entry.name)))
            .collect())
    }

    fn boot_info(&mut self, entry_id: Option<String>) -> Result<(&Path, &Path, &str), Error> {
        if let Some(entry) = self.entries.iter().find(|entry| {
            if let Some(entry_id) = &entry_id {
                &entry.name == entry_id
            } else {
                entry.default
            }
        }) {
            Ok((&entry.kernel, &entry.initrd, &entry.cmdline))
        } else {
            Err(Error::BootEntryNotFound)
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{path::PathBuf, time::Duration};

    #[test]
    fn syslinux_parse() {
        let (entries, timeout) =
            super::syslinux_parse(&PathBuf::from("testdata/extlinux.conf")).unwrap();
        assert_eq!(timeout, Duration::from_secs(5));
        assert_eq!(entries.len(), 6);

        let first = &entries[0];
        assert_eq!(first.name, "NixOS - Default");
        assert_eq!(first.cmdline, "init=/nix/store/piq69xyzwy9j6fqjl80nx1sxrnpk9zzn-nixos-system-beetroot-23.05.20221229.677ed08/init loglevel=4 zram.num_devices=1");

        let last = &entries[5];
        assert_eq!(
            last.name,
            "NixOS - Configuration 17-flashfriendly (2022-12-29 14:52 - 23.05.20221228.e182da8)"
        );
        assert_eq!(last.cmdline, "init=/nix/store/gmppv1gyqzr681n3r0yb20kqchls61gz-nixos-system-beetroot-23.05.20221228.e182da8/init iomem=relaxed loglevel=4 zram.num_devices=1");
    }
}
