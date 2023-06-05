use crate::{
    boot_loader::{BootLoader, Error},
    linux::LinuxBootEntry,
};
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
    entries: Vec<BootEntry>,
    timeout: Duration,
}

/// Perform a pass over the syslinux source and expand all include statements.
fn expand_includes(
    source: impl Into<String>,
    syslinux_root: impl AsRef<Path>,
) -> Result<String, Error> {
    let source: String = source.into();

    let mut result_source = String::new();

    for line in source.lines() {
        let lower_line = line.to_lowercase();
        if lower_line.find("include ") == Some(0) {
            let include_file = PathBuf::from(line["include ".len() - 1..].trim());
            let include_file = syslinux_root.as_ref().join(include_file);
            let include_source = fs::read_to_string(include_file)?;
            result_source.push_str(&include_source);
        } else {
            result_source.push_str(line);
        }
        result_source.push('\n');
    }

    Ok(result_source)
}

fn syslinux_parse_from_source(
    source: impl Into<String>,
    syslinux_root: impl AsRef<Path>,
) -> Result<(Vec<BootEntry>, Duration), Error> {
    let source: String = source.into();

    let mut entries = vec![];
    let mut p = BootEntry::default();
    let mut default = String::new();
    let mut in_entry: Option<bool> = None;
    let mut timeout = Duration::from_secs(5);

    for line in source.lines() {
        let lower_line = line.to_lowercase();

        if !in_entry.unwrap_or_default() && lower_line.find("timeout ") == Some(0) {
            timeout = Duration::from_secs(
                line["timeout ".len() - 1..]
                    .trim()
                    .parse::<i32>()
                    .map(|timeout| {
                        if timeout <= 0 {
                            0u64
                        } else {
                            // timeout is formatted as tenths of seconds
                            // https://wiki.syslinux.org/wiki/index.php?title=Config#TIMEOUT
                            (timeout as u64) / 10
                        }
                    })
                    .unwrap_or(5),
            );
            continue;
        }

        if !in_entry.unwrap_or_default() && lower_line.find("default ") == Some(0) {
            default = String::from(line["default ".len() - 1..].trim());
            continue;
        }

        if lower_line.find("label ") == Some(0) {
            // We have already seen at least one entry, push the previous one into boot parts
            // and start a new one.
            if in_entry.is_some() {
                entries.push(p);
                p = BootEntry::default();
            }

            if default == line["label ".len() - 1..].trim() {
                p.default = true;
            }

            in_entry = Some(true);
            continue;
        }
        if !in_entry.unwrap_or_default() {
            continue;
        }

        if let Some(menu_label_start) = lower_line.find("menu label ") {
            p.name = String::from(line[menu_label_start + "menu label ".len() - 1..].trim());
            continue;
        }

        if let Some(linux_start) = lower_line.find("linux ") {
            p.kernel = syslinux_root.as_ref().join(PathBuf::from(
                line[linux_start + "linux ".len() - 1..].trim(),
            ));
            continue;
        }

        if let Some(initrd_start) = lower_line.find("initrd ") {
            p.initrd = syslinux_root.as_ref().join(PathBuf::from(
                line[initrd_start + "initrd ".len() - 1..].trim(),
            ));
            continue;
        }

        if let Some(append_start) = lower_line.find("append ") {
            p.cmdline = String::from(line[append_start + "append ".len() - 1..].trim());
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
    pub fn parse_syslinux(syslinux_root: &Path, config_source: String) -> Result<Self, Error> {
        let source = expand_includes(config_source, syslinux_root)?;
        let (entries, timeout) = syslinux_parse_from_source(source, syslinux_root)?;
        Ok(Self { entries, timeout })
    }
}

impl BootLoader for SyslinuxBootLoader {
    fn timeout(&self) -> Duration {
        self.timeout
    }

    fn boot_entries(&self) -> Result<Vec<LinuxBootEntry>, Error> {
        Ok(self
            .entries
            .iter()
            .map(|entry| LinuxBootEntry {
                default: entry.default,
                display: entry.name.clone(),
                linux: entry.kernel.clone(),
                initrd: Some(entry.initrd.clone()),
                cmdline: Some(entry.cmdline.clone()),
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use std::{path::Path, time::Duration};

    #[test]
    fn syslinux_parse() {
        let (entries, timeout) = super::syslinux_parse_from_source(
            include_str!("../testdata/extlinux.conf"),
            Path::new("/dev/null"),
        )
        .unwrap();
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
