use crate::boot_loader::{BootConfiguration, BootEntry, BootLoader, Error, MenuEntry};
use log::{debug, info, warn};
use std::{
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

pub struct Syslinux {
    path: PathBuf,
}

impl Syslinux {
    pub fn new(mount_point: &Path) -> Result<Self, Error> {
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
            let search_path = mount_point.join(path);

            debug!(
                "searching for syslinux configuration at {}",
                search_path.display()
            );

            if let Err(e) = fs::metadata(&search_path) {
                warn!("{}: {}", search_path.display(), e)
            } else {
                info!("found syslinux configuration at {}", search_path.display());
                return Ok(Self { path: search_path });
            }
        }

        Err(Error::BootConfigNotFound)
    }
}

impl BootLoader for Syslinux {
    fn get_boot_configuration(&self) -> Result<BootConfiguration, Error> {
        let contents = fs::read_to_string(&self.path)?;

        let mut entries = vec![];
        let mut p = BootEntry::default();
        let mut default = String::new();
        let mut in_entry: Option<bool> = None;
        let mut timeout = Duration::from_secs(10);

        for line in contents.lines() {
            if !in_entry.unwrap_or_default() && line.starts_with("TIMEOUT") {
                timeout = Duration::from_secs(
                    line.split_once("TIMEOUT ")
                        .expect("bad syslinux format")
                        .1
                        .parse()
                        .unwrap_or(10),
                );
                continue;
            }

            if !in_entry.unwrap_or_default() && line.starts_with("DEFAULT") {
                default = String::from(line.split_once("DEFAULT ").expect("bad syslinux format").1);
                continue;
            }

            if line.starts_with("LABEL") {
                // We have already seen at least one entry, push the previous one into boot parts
                // and start a new one.
                if in_entry.is_some() {
                    entries.push(MenuEntry::BootEntry(p));
                    p = BootEntry::default();
                }

                if default == line.split_once("LABEL ").expect("bad syslinux format").1 {
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
                        .expect("bad syslinux format")
                        .1,
                );
                continue;
            }

            if line
                .trim_start_matches(char::is_whitespace)
                .starts_with("LINUX")
            {
                p.kernel = self.path.parent().unwrap().join(PathBuf::from(
                    line.split_once("LINUX ").expect("bad syslinux format").1,
                ));
                continue;
            }

            if line
                .trim_start_matches(char::is_whitespace)
                .starts_with("INITRD")
            {
                p.initrd = self.path.parent().unwrap().join(PathBuf::from(
                    line.split_once("INITRD ").expect("bad syslinux format").1,
                ));
                continue;
            }

            if line
                .trim_start_matches(char::is_whitespace)
                .starts_with("APPEND")
            {
                p.cmdline =
                    String::from(line.split_once("APPEND ").expect("bad syslinux format").1);
                continue;
            }

            if line
                .trim_start_matches(char::is_whitespace)
                .starts_with("FDT")
            {
                p.dtb = Some(self.path.parent().unwrap().join(PathBuf::from(
                    line.split_once("FDT ").expect("bad syslinux format").1,
                )));
                continue;
            }

            if line.trim().is_empty() {
                in_entry = Some(false);
            }
        }

        // Include the last entry in boot parts.
        entries.push(MenuEntry::BootEntry(p));

        Ok(BootConfiguration { timeout, entries })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn syslinux_get_parts() {
        let config = (Syslinux {
            path: PathBuf::from("testdata/extlinux.conf"),
        })
        .get_boot_configuration()
        .unwrap();
        assert_eq!(config.timeout, Duration::from_secs(50));
        assert_eq!(config.entries.len(), 6);

        let MenuEntry::BootEntry(first) = &config.entries[0] else { panic!("first entry is not a boot entry"); };
        let MenuEntry::BootEntry(last) = &config.entries[5] else { panic!("last entry is not a boot entry"); };

        assert_eq!(first.name, "NixOS - Default");
        assert_eq!(
            first.cmdline,
            "init=/nix/store/piq69xyzwy9j6fqjl80nx1sxrnpk9zzn-nixos-system-beetroot-23.05.20221229.677ed08/init loglevel=4 zram.num_devices=1",
        );
        assert_eq!(
            last.name,
            "NixOS - Configuration 17-flashfriendly (2022-12-29 14:52 - 23.05.20221228.e182da8)",
        );
        assert_eq!(
            last.cmdline,
            "init=/nix/store/gmppv1gyqzr681n3r0yb20kqchls61gz-nixos-system-beetroot-23.05.20221228.e182da8/init iomem=relaxed loglevel=4 zram.num_devices=1",
        );
    }
}
