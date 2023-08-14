use crate::{
    boot_loader::{BootLoader, Error},
    linux::LinuxBootEntry,
};
use log::error;
use std::{
    cmp::Ordering,
    fs,
    path::{Path, PathBuf},
    str::FromStr,
    time::Duration,
};

#[derive(Debug, PartialEq)]
pub enum EfiArch {
    Ia32,
    X64,
    Ia64,
    Arm,
    Aa64,
}

impl FromStr for EfiArch {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "ia32" => EfiArch::Ia32,
            "x64" => EfiArch::X64,
            "ia64" => EfiArch::Ia64,
            "arm" => EfiArch::Arm,
            "aa64" => EfiArch::Aa64,
            _ => anyhow::bail!("unknown EFI arch"),
        })
    }
}

// Documentation: https://uapi-group.org/specifications/specs/boot_loader_specification/#type-1-boot-loader-specification-entries
// NOTE: the `efi` entry is purposefully left out here since we cannot execute an EFI program from
// linux.
#[derive(Default)]
struct BlsEntry {
    name: String,
    pretty_name: String,
    title: Option<String>,
    version: Option<String>,
    machine_id: Option<String>,
    sort_key: Option<String>,
    linux: PathBuf,
    initrd: PathBuf,
    options: Option<String>,
    devicetree: Option<PathBuf>,
    devicetree_overlay: Option<PathBuf>,
    architecture: Option<EfiArch>,
}

// TODO(jared): implement editor?
pub struct BlsBootLoader {
    mountpoint: PathBuf,
    entries: Vec<BlsEntry>,
    default_entry: String,
    timeout: Duration,
}

impl BlsBootLoader {
    pub fn parse_loader_conf(mountpoint: &Path, loader_conf: String) -> Result<Self, Error> {
        let mut default_entry = String::new();
        let mut timeout = Duration::from_secs(5);
        let mut entries = Vec::new();

        for line in loader_conf.lines() {
            if line.starts_with("timeout") {
                let Some(found_timeout) = line.split_whitespace().last() else {
                    continue;
                };
                let Ok(timeout_secs) = found_timeout.parse::<u64>() else {
                    continue;
                };
                timeout = Duration::from_secs(timeout_secs);
            }

            if line.starts_with("default") {
                let Some(found_default) = line.split_whitespace().last() else {
                    continue;
                };
                default_entry = found_default.trim_end_matches(".conf").to_string();
            }
        }

        for entry in fs::read_dir(mountpoint.join("loader/entries"))? {
            let Ok(entry) = entry else { continue; };
            let Ok(md) = entry.metadata() else { continue; };

            if !md.is_file() {
                continue;
            }

            let Ok(entry_conf) = fs::read_to_string(entry.path()) else {
                error!("failed to read entry at {:?}", entry.path());
                continue;
            };

            let Ok(parsed_entry) = Self::parse_entry_conf(&entry.path(), entry_conf) else {
                error!("failed to parse entry at {:?}", entry.path());
                continue;
            };

            entries.push(parsed_entry);
        }

        entries.sort_by(|a, b| {
            if a.version < b.version {
                Ordering::Greater
            } else if a.version > b.version {
                Ordering::Less
            } else if a.title > b.title {
                Ordering::Greater
            } else if a.title < b.title {
                Ordering::Less
            } else if a.name > b.name {
                Ordering::Greater
            } else {
                Ordering::Less
            }
        });

        Ok(BlsBootLoader {
            entries,
            mountpoint: mountpoint.to_path_buf(),
            default_entry,
            timeout,
        })
    }

    fn parse_entry_conf(conf_path: &Path, entry_conf: String) -> Result<BlsEntry, Error> {
        let mut entry = BlsEntry::default();

        let Some(file_name) = conf_path.file_stem() else {
            error!("no file name");
            return Err(Error::InvalidEntry);
        };
        let Some(file_name) = file_name.to_str() else {
            error!("invalid UTF-8");
            return Err(Error::InvalidEntry);
        };
        entry.name = file_name.to_string();

        for line in entry_conf.lines() {
            if line.starts_with("architecture") {
                let Some(architecture) = line.split_whitespace().last() else { continue; };
                let Ok(architecture) = EfiArch::from_str(architecture) else { continue; };
                entry.architecture = Some(architecture);
            }
            if line.starts_with("title ") {
                let title = line["title ".len() - 1..].trim();
                entry.title = Some(title.to_string());
            }
            if line.starts_with("version ") {
                let version = line["version ".len() - 1..].trim();
                entry.version = Some(version.to_string());
            }
            if line.starts_with("machine-id") {
                let Some(machine_id) = line.split_whitespace().last() else { continue; };
                entry.machine_id = Some(machine_id.to_string());
            }
            if line.starts_with("sort-key") {
                let Some(sort_key) = line.split_whitespace().last() else { continue; };
                entry.sort_key = Some(sort_key.to_string());
            }
            if line.starts_with("linux") {
                let Some(linux) = line.split_whitespace().last() else { continue; };
                entry.linux = PathBuf::from(linux);
            }
            if line.starts_with("initrd") {
                let Some(initrd) = line.split_whitespace().last() else { continue; };
                entry.initrd = PathBuf::from(initrd);
            }
            if line.starts_with("options ") {
                let options = line["options ".len() - 1..].trim();
                entry.options = Some(options.to_string());
            }
            if line.starts_with("devicetree") {
                let Some(devicetree) = line.split_whitespace().last() else { continue; };
                entry.devicetree = Some(PathBuf::from(devicetree));
            }
            if line.starts_with("devicetree-overlay") {
                let Some(devicetree_overlay) = line.split_whitespace().last() else { continue; };
                entry.devicetree_overlay = Some(PathBuf::from(devicetree_overlay));
            }
        }

        entry.pretty_name = 'pretty: {
            let Some(title) = &entry.title else {
                break 'pretty entry.name.clone();
            };
            let Some(version) = &entry.version else {
                break 'pretty entry.name.clone();
            };

            format!("{} {}", title, version)
        };

        Ok(entry)
    }
}

impl BootLoader for BlsBootLoader {
    fn timeout(&self) -> std::time::Duration {
        self.timeout
    }

    fn boot_entries(&self) -> Result<Vec<LinuxBootEntry>, Error> {
        Ok(self
            .entries
            .iter()
            .map(|entry| LinuxBootEntry {
                default: entry.name == self.default_entry,
                display: entry.pretty_name.clone(),
                linux: self
                    .mountpoint
                    .join(entry.linux.strip_prefix("/").unwrap_or(&entry.linux)),
                initrd: Some(
                    self.mountpoint
                        .join(entry.initrd.strip_prefix("/").unwrap_or(&entry.initrd)),
                ),
                cmdline: entry.options.clone(),
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::path::PathBuf;

    #[test]
    fn test_parse_entry_conf() {
        let entry = super::BlsBootLoader::parse_entry_conf(Path::new("foo.conf"), String::from(r#"title NixOS
version Generation 118 NixOS 23.05.20230506.0000000, Linux Kernel 6.1.27, Built on 2023-05-07
linux /efi/nixos/00000000000000000000000000000000-linux-6.1.27-bzImage.efi
initrd /efi/nixos/00000000000000000000000000000000-initrd-linux-6.1.27-initrd.efi
options init=/nix/store/00000000000000000000000000000000-nixos-system-beetroot-23.05.20230506.0000000/init systemd.show_status=auto loglevel=4
machine-id 00000000000000000000000000000000
"#)).unwrap();
        assert_eq!(entry.name, String::from("foo"));
        assert_eq!(entry.devicetree, None);
        assert_eq!(entry.options, Some(String::from("init=/nix/store/00000000000000000000000000000000-nixos-system-beetroot-23.05.20230506.0000000/init systemd.show_status=auto loglevel=4")));
        assert_eq!(entry.devicetree_overlay, None);
        assert_eq!(entry.architecture, None);
        assert_eq!(
            entry.initrd,
            PathBuf::from(
                "/efi/nixos/00000000000000000000000000000000-initrd-linux-6.1.27-initrd.efi"
            )
        );
        assert_eq!(entry.sort_key, None);
        assert_eq!(entry.title, Some(String::from("NixOS")));
        assert_eq!(
            entry.linux,
            PathBuf::from("/efi/nixos/00000000000000000000000000000000-linux-6.1.27-bzImage.efi")
        );
        assert_eq!(entry.version, Some(String::from("Generation 118 NixOS 23.05.20230506.0000000, Linux Kernel 6.1.27, Built on 2023-05-07")));
        assert_eq!(
            entry.machine_id,
            Some(String::from("00000000000000000000000000000000"))
        );
    }
}
