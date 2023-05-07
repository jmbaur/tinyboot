use crate::boot_loader::{BootLoader, Error, MenuEntry};
use log::{debug, error};
use std::{
    fs,
    path::{Path, PathBuf},
    str::FromStr,
    time::Duration,
};

enum EfiArch {
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
    pub fn get_config(mountpoint: &Path) -> Result<PathBuf, Error> {
        let path = "loader/loader.conf";
        let search_path = mountpoint.join(path);

        debug!(
            "searching for BootLoaderSpecification configuration at {}",
            search_path.display()
        );

        if fs::metadata(search_path).is_ok() {
            Ok(PathBuf::from(path))
        } else {
            Err(Error::BootConfigNotFound)
        }
    }

    pub fn new(mountpoint: &Path, config_file: &Path) -> Result<Self, Error> {
        let source = fs::read_to_string(mountpoint.join(config_file))?;
        Self::parse_loader_conf(mountpoint, source)
    }

    fn parse_loader_conf(mountpoint: &Path, loader_conf: String) -> Result<Self, Error> {
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
            if line.starts_with("title") {
                let Some(title) = line.split_whitespace().last() else { continue; };
                entry.title = Some(title.to_string());
            }
            if line.starts_with("version") {
                let Some(version) = line.split_whitespace().last() else { continue; };
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
            if line.starts_with("options") {
                let Some(options) = line.split_whitespace().last() else { continue; };
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

        Ok(entry)
    }
}

impl BootLoader for BlsBootLoader {
    fn timeout(&self) -> std::time::Duration {
        self.timeout
    }

    fn mountpoint(&self) -> &std::path::Path {
        &self.mountpoint
    }

    fn menu_entries(&self) -> Result<Vec<MenuEntry>, Error> {
        Ok(self
            .entries
            .iter()
            .map(|entry| MenuEntry::BootEntry((entry.name.as_str(), entry.name.as_str())))
            .collect())
    }

    fn boot_info(
        &mut self,
        entry_id: Option<String>,
    ) -> Result<(std::path::PathBuf, std::path::PathBuf, String), Error> {
        let entry_to_find = entry_id.unwrap_or(self.default_entry.to_string());

        if let Some(entry) = self
            .entries
            .iter()
            .find(|entry| entry.name == entry_to_find)
        {
            Ok((
                self.mountpoint
                    .join(entry.linux.strip_prefix("/").unwrap_or(&entry.linux)),
                self.mountpoint
                    .join(entry.initrd.strip_prefix("/").unwrap_or(&entry.initrd)),
                entry.options.to_owned().unwrap_or_default(),
            ))
        } else {
            Err(Error::BootConfigNotFound)
        }
    }
}
