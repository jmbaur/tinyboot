use crate::boot_loader::LinuxBootLoader;
use log::{debug, error, info, trace};
use nix::mount::{self, MntFlags, MsFlags};
use std::{
    cmp::Ordering,
    collections::HashMap,
    path::{Path, PathBuf},
    str::FromStr,
    time::Duration,
};

use super::{BootDevice, LinuxBootEntry, LoaderType};

const DISK_MNT_PATH: &str = "/mnt/disk";

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
#[derive(Default)]
struct BlsEntry {
    name: String,
    pretty_name: String,
    title: Option<String>,
    version: Option<String>,
    machine_id: Option<String>,
    sort_key: Option<String>,
    devicetree: Option<PathBuf>,
    devicetree_overlay: Option<Vec<PathBuf>>,
    architecture: Option<EfiArch>,
    efi: Option<PathBuf>,
    linux: Option<PathBuf>,
    initrd: Option<Vec<PathBuf>>,
    options: Option<String>,
}

impl BlsEntry {
    fn parse_entry_conf(
        mountpoint: impl AsRef<Path>,
        conf_path: impl AsRef<Path>,
        entry_conf: &str,
    ) -> anyhow::Result<BlsEntry> {
        let mut entry = BlsEntry::default();

        let Some(file_name) = conf_path.as_ref().file_stem() else {
            anyhow::bail!("no file name");
        };
        let Some(file_name) = file_name.to_str() else {
            anyhow::bail!("invalid path");
        };
        entry.name = file_name.to_string();

        for line in entry_conf.lines() {
            let Some((key, val)) = line.split_once(char::is_whitespace) else {
                continue;
            };

            match key {
                "architecture" => {
                    entry.architecture = EfiArch::from_str(val).ok();
                }
                "title" => {
                    entry.title = Some(val.trim().to_string());
                }
                "version" => {
                    entry.version = Some(val.trim().to_string());
                }
                "machine-id" => {
                    entry.machine_id = Some(val.trim().to_string());
                }
                "sort-key" => {
                    entry.sort_key = Some(val.trim().to_string());
                }
                "efi" => {
                    entry.efi = Some(
                        mountpoint
                            .as_ref()
                            .join(val.trim_start_matches(std::path::MAIN_SEPARATOR)),
                    );
                }
                "linux" => {
                    entry.linux = Some(
                        mountpoint
                            .as_ref()
                            .join(val.trim_start_matches(std::path::MAIN_SEPARATOR)),
                    );
                }
                "initrd" => {
                    let new_initrds = val
                        .split_ascii_whitespace()
                        .map(|initrd| {
                            mountpoint
                                .as_ref()
                                .join(initrd.trim_start_matches(std::path::MAIN_SEPARATOR))
                        })
                        .collect();

                    match entry.initrd.iter_mut().next() {
                        Some(initrd) => initrd.extend(new_initrds),
                        None => entry.initrd = Some(new_initrds),
                    }
                }
                "options" => match entry.options.iter_mut().next() {
                    Some(opts) => {
                        opts.push(' ');
                        opts.push_str(val.trim());
                    }
                    None => entry.options = Some(val.trim().to_string()),
                },
                "devicetree" => {
                    entry.devicetree = Some(
                        mountpoint
                            .as_ref()
                            .join(val.trim_start_matches(std::path::MAIN_SEPARATOR)),
                    );
                }
                "devicetree-overlay" => {
                    let new_overlays = val
                        .split_ascii_whitespace()
                        .map(|overlay| {
                            mountpoint
                                .as_ref()
                                .join(overlay.trim_start_matches(std::path::MAIN_SEPARATOR))
                        })
                        .collect();

                    match entry.devicetree_overlay.iter_mut().next() {
                        Some(overlays) => overlays.extend(new_overlays),
                        None => entry.devicetree_overlay = Some(new_overlays),
                    }
                }
                _ => {}
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

impl TryInto<LinuxBootEntry> for &BlsEntry {
    type Error = anyhow::Error;

    fn try_into(self) -> Result<LinuxBootEntry, Self::Error> {
        if self.efi.is_some() {
            anyhow::bail!("cannot boot efi");
        }

        let Some(linux) = self.linux.clone() else {
            anyhow::bail!("cannot boot without linux");
        };

        let initrd = if let Some(initrds) = self.initrd.clone() {
            if initrds.len() > 1 {
                info!("cannot use multiple initrds with KEXEC_FILE_LOAD and modsig appraisal");
                info!("using first initrd");
            }
            initrds.first().cloned()
        } else {
            None
        };

        let cmdline = self.options.clone();

        let display = self.pretty_name.clone();

        Ok(LinuxBootEntry {
            display,
            linux,
            initrd,
            cmdline,
        })
    }
}

struct Disk {
    diskseq: u64,
    device_path: PathBuf,
    entries: Vec<BlsEntry>,
    mountpoint: Option<PathBuf>,
    loader_conf: Option<LoaderConf>,
    removable: bool,
    vendor: Option<String>,
    model: Option<String>,
}

impl Into<BootDevice> for &mut Disk {
    fn into(self) -> BootDevice {
        let (timeout, default_entry) = if let Some(conf) = &self.loader_conf {
            (
                conf.timeout,
                self.entries
                    .iter()
                    .enumerate()
                    .find_map(|(idx, entry)| {
                        if Some(entry.name.as_str()) == conf.default_entry.as_deref() {
                            Some(idx)
                        } else {
                            None
                        }
                    })
                    .unwrap_or_default(),
            )
        } else {
            (Duration::from_secs(10), 0)
        };

        BootDevice {
            name: format!(
                "{} {}",
                if let Some(vendor) = &self.vendor {
                    vendor
                } else {
                    "Unknown Vendor"
                },
                if let Some(model) = &self.model {
                    model
                } else {
                    "Unknown Model"
                },
            ),
            timeout,
            default_entry,
            entries: self
                .entries
                .iter()
                .filter_map(|entry| match entry.try_into() {
                    Ok(entry) => Some(entry),
                    Err(e) => {
                        info!("could not convert entry {}: {e}", entry.name);
                        None
                    }
                })
                .collect(),
        }
    }
}

impl Disk {
    pub fn new(diskseq: u64, device_path: PathBuf) -> Self {
        let mut disk = Self {
            entries: Vec::new(),
            diskseq,
            device_path,
            removable: false,
            vendor: None,
            model: None,
            mountpoint: None,
            loader_conf: None,
        };

        disk.removable = Self::get_attribute_bool(&disk.device_path, "removable");
        disk.vendor = Self::get_attribute_string(&disk.device_path, "vendor");
        disk.model = Self::get_attribute_string(&disk.device_path, "model");

        disk
    }

    fn get_attribute_string(device_path: impl AsRef<Path>, attribute: &str) -> Option<String> {
        Disk::get_disk_attribute(device_path, attribute).ok()
    }

    fn get_attribute_bool(device_path: impl AsRef<Path>, attribute: &str) -> bool {
        Disk::get_disk_attribute(device_path, attribute)
            .map(|val| val == "1\n")
            .unwrap_or_default()
    }

    fn get_disk_attribute(
        device_path: impl AsRef<Path>,
        attribute: &str,
    ) -> std::io::Result<String> {
        std::fs::read_to_string(device_path.as_ref().join(attribute))
            .map(|val| val.trim().to_string())
    }

    fn mount(&mut self, partition_chardev_path: PathBuf) -> anyhow::Result<()> {
        // We can use diskseq as value that is unique across all disks
        // https://github.com/torvalds/linux/blob/9c5d00cb7b6bbc5a7965d9ab7d223b5402d1f02c/block/genhd.c#L53

        let mountpoint = PathBuf::from(DISK_MNT_PATH).join(self.diskseq.to_string());
        std::fs::create_dir(&mountpoint)?;

        mount::mount(
            Some(&partition_chardev_path),
            &mountpoint,
            Some(crate::fs::detect_fs_type(&partition_chardev_path)?.as_str()),
            MsFlags::MS_NOEXEC | MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
            None::<&[u8]>,
        )?;

        self.mountpoint = Some(mountpoint);

        Ok(())
    }

    fn discover_entries(&mut self) {
        trace!("searching for BLS entries");

        let Some(mountpoint) = self.mountpoint.as_ref() else {
            error!("disk not mounted");
            return;
        };

        let entry_dir = mountpoint.join("loader/entries");
        let entries = match std::fs::read_dir(&entry_dir) {
            Ok(e) => e,
            Err(e) => {
                debug!("failed to read entries dir {}: {e}", entry_dir.display());
                return;
            }
        };

        for entry in entries {
            let only_files = entry
                .as_ref()
                .map(|entry| entry.metadata().map(|md| md.is_file()));
            if !matches!(only_files, Ok(Ok(true))) {
                debug!("skipping {:?}", entry);
                continue;
            };

            let entry_path = entry.expect("entry path exists").path();

            let entry_conf_contents = match std::fs::read_to_string(&entry_path) {
                Ok(e) => e,
                Err(e) => {
                    error!("failed to read entry {}: {e}", entry_path.display());
                    continue;
                }
            };

            let Ok(parsed_entry) =
                BlsEntry::parse_entry_conf(mountpoint.as_path(), &entry_path, &entry_conf_contents)
            else {
                error!("failed to parse entry at {:?}", entry_path);
                continue;
            };

            debug!("new entry added {}", entry_path.display());
            self.entries.push(parsed_entry);
        }

        // TODO(jared): this could be a lot better, it depends on sequential entries having the
        // same fields defined, but this isn't always necessarily the case.
        self.entries.sort_by(|a, b| {
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
    }

    fn unmount(&self) {
        if let Some(mountpoint) = &self.mountpoint {
            if let Err(e) = mount::umount2(mountpoint, MntFlags::MNT_DETACH) {
                error!("failed to unmount {}: {e}", mountpoint.display());
            }
        }
    }
}

struct LoaderConf {
    default_entry: Option<String>,
    timeout: Duration,
}

impl LoaderConf {
    fn parse_loader_conf(contents: &str) -> Self {
        let mut default_entry = None;
        let mut timeout = Duration::from_secs(5);

        for line in contents.lines() {
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
                default_entry = Some(found_default.trim_end_matches(".conf").to_string());
            }
        }

        LoaderConf {
            default_entry,
            timeout,
        }
    }
}

/// BlsBootLoader implements (a small part of) the Boot Loader Specification for booting from a
/// disk. See https://uapi-group.org/specifications/specs/boot_loader_specification/.
#[derive(Default)]
pub struct BlsBootLoader {
    disks: Vec<Disk>,
}

impl BlsBootLoader {
    pub fn new() -> Self {
        Self::default()
    }
}

impl LinuxBootLoader for BlsBootLoader {
    fn startup(&mut self) -> anyhow::Result<()> {
        debug!("startup");

        std::fs::create_dir_all(DISK_MNT_PATH).unwrap();

        let Ok(block_class_dir) = std::fs::read_dir("/sys/class/block") else {
            anyhow::bail!("/sys/class/block missing");
        };

        for block_dev in block_class_dir {
            let Ok(block_dev) = block_dev else {
                continue;
            };

            // the path under /sys/devices that /sys/class/<class>/<devname> points to
            let block_dev_path = std::fs::canonicalize(block_dev.path()).unwrap();

            // the path under /sys/devices that /sys/class/<class>/<devname>/device points to
            let device_path = {
                let device_path = block_dev_path.join("device");
                if !std::fs::metadata(&device_path).is_ok() {
                    debug!("no backing device for {}", block_dev_path.display());
                    continue;
                }
                std::fs::canonicalize(device_path).unwrap()
            };

            let diskseq = {
                let diskseq_path = block_dev_path.join("diskseq");
                let Ok(Ok(diskseq)) = std::fs::read_to_string(diskseq_path)
                    .map(|diskseq_str| u64::from_str_radix(diskseq_str.trim_end_matches('\n'), 10))
                else {
                    continue;
                };

                diskseq
            };

            let uevent = get_uevent(&block_dev_path);
            let Some(devname) = uevent.get("DEVNAME") else {
                continue;
            };

            let gpt_cfg = gpt::GptConfig::new().writable(false);
            let disk_chardev_path = get_dev_path(devname);
            let gpt_disk = match gpt_cfg.open(&disk_chardev_path) {
                Ok(disk) => disk,
                Err(e) => {
                    debug!("gpt: {}: {e}", disk_chardev_path.display());
                    continue;
                }
            };

            if let Some(esp) = gpt_disk
                .partitions()
                .iter()
                .find(|(_, part)| part.part_type_guid == gpt::partition_types::EFI)
            {
                let partition_name = format!("{}{}", devname, esp.0);
                let partition_chardev_path = get_dev_path(&partition_name);

                let mut disk = Disk::new(diskseq, device_path.clone());

                if let Err(e) = disk.mount(partition_chardev_path) {
                    debug!("failed to mount {}: {e}", disk_chardev_path.display());
                    continue;
                }

                self.disks.push(disk);

                // Assuming one ESP per disk.
                continue;
            }
        }

        // prioritize disk by removable status
        self.disks.sort_by(|a, b| {
            if a.removable && !b.removable {
                Ordering::Less
            } else if !a.removable && b.removable {
                Ordering::Greater
            } else {
                Ordering::Equal
            }
        });

        Ok(())
    }

    fn probe(&mut self) -> anyhow::Result<Vec<super::BootDevice>> {
        debug!("probe");

        let mut devs = Vec::new();

        for disk in self.disks.iter_mut() {
            if let Some(mountpoint) = &disk.mountpoint {
                let loader_conf = mountpoint.join("loader/loader.conf");

                let loader_conf_contents = match std::fs::read_to_string(&loader_conf) {
                    Ok(l) => l,
                    Err(e) => {
                        debug!("failed to read loader.conf {}, {e}", loader_conf.display());
                        continue;
                    }
                };

                disk.loader_conf = Some(LoaderConf::parse_loader_conf(&loader_conf_contents));
                disk.discover_entries();
                devs.push(disk.into());
            }
        }

        Ok(devs)
    }

    fn shutdown(&mut self) {
        debug!("shutdown");

        for disk in &self.disks {
            disk.unmount();
        }

        if let Err(e) = std::fs::remove_dir_all(DISK_MNT_PATH) {
            error!("failed to remove {}: {e}", DISK_MNT_PATH);
        }
    }

    fn loader_type(&mut self) -> super::LoaderType {
        LoaderType::Disk
    }
}

fn get_dev_path(devname: &str) -> PathBuf {
    PathBuf::from("/dev").join(devname)
}

fn get_uevent(sys_dev: &Path) -> HashMap<String, String> {
    let uevent = sys_dev.join("uevent");
    let contents = std::fs::read_to_string(uevent).unwrap();
    parse_uevent(contents)
}

fn parse_uevent(contents: String) -> HashMap<String, String> {
    contents.lines().fold(HashMap::new(), |mut map, line| {
        if let Some((key, val)) = line.split_once('=') {
            map.insert(key.to_string(), val.to_string());
        }
        map
    })
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::path::PathBuf;

    #[test]
    fn test_parse_entry_conf() {
        let entry = super::BlsEntry::parse_entry_conf(Path::new("/foo/bar"), Path::new("foo.conf"), r#"title NixOS
version Generation 118 NixOS 23.05.20230506.0000000, Linux Kernel 6.1.27, Built on 2023-05-07
linux /efi/nixos/00000000000000000000000000000000-linux-6.1.27-bzImage.efi
initrd /efi/nixos/00000000000000000000000000000000-initrd-linux-6.1.27-initrd.efi
options init=/nix/store/00000000000000000000000000000000-nixos-system-beetroot-23.05.20230506.0000000/init systemd.show_status=auto loglevel=4
machine-id 00000000000000000000000000000000
"#).unwrap();
        assert_eq!(entry.name, String::from("foo"));
        assert_eq!(entry.devicetree, None);
        assert_eq!(entry.devicetree_overlay, None);
        assert_eq!(entry.architecture, None);
        assert_eq!(entry.sort_key, None);
        assert_eq!(entry.title, Some(String::from("NixOS")));
        assert_eq!(entry.version, Some(String::from("Generation 118 NixOS 23.05.20230506.0000000, Linux Kernel 6.1.27, Built on 2023-05-07")));
        assert_eq!(
            entry.machine_id,
            Some(String::from("00000000000000000000000000000000"))
        );
        assert_eq!(
            entry.linux,
            Some(PathBuf::from(
                "/foo/bar/efi/nixos/00000000000000000000000000000000-linux-6.1.27-bzImage.efi"
            ))
        );
        assert_eq!(
            entry.initrd,
            Some(vec![PathBuf::from(
                "/foo/bar/efi/nixos/00000000000000000000000000000000-initrd-linux-6.1.27-initrd.efi"
            )])
        );
        assert_eq!(
            entry.options,
            Some(String::from("init=/nix/store/00000000000000000000000000000000-nixos-system-beetroot-23.05.20230506.0000000/init systemd.show_status=auto loglevel=4"))
        );
    }
}
