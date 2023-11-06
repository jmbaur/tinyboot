use crate::boot_loader::BootLoader;
use log::{debug, error, info, trace};
use nix::mount::{self, MntFlags, MsFlags};
use std::{
    cmp::Ordering,
    collections::HashMap,
    fmt::Display,
    path::{Path, PathBuf},
    str::FromStr,
    time::Duration,
};

use super::{BootDevice, BootEntry, LinuxBootParts, LoaderType};

const DISK_MNT_PATH: &str = "/mnt/disk";

#[derive(Debug, PartialEq, Clone)]
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
#[derive(Default, Clone)]
struct BlsEntry {
    entry_path: PathBuf,
    tries_left: Option<u32>,
    tries_done: Option<u32>,
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
    options: Vec<String>,
    is_default: bool,
}

impl Display for BlsEntry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.pretty_name)
    }
}

impl BootEntry for BlsEntry {
    fn is_default(&self) -> bool {
        self.is_default
    }

    fn select(&self) -> LinuxBootParts {
        // this should be checked by "impl TryInto<Box<dyn BootEntry>> for BlsEntry"
        let linux = self
            .linux
            .clone()
            .expect("path to linux kernel is not present");

        let initrd = if let Some(initrds) = self.initrd.clone() {
            if initrds.len() > 1 {
                info!("cannot use multiple initrds with KEXEC_FILE_LOAD and modsig appraisal");
                info!("using first initrd");
            }
            initrds.into_iter().next()
        } else {
            None
        };

        let mut options = self.options.clone();
        options.push(format!("tboot.bls-entry={}", self.name));
        let cmdline = Some(options.join(" "));

        self.boot_count();

        LinuxBootParts {
            linux,
            initrd,
            cmdline,
        }
    }
}

impl BlsEntry {
    fn parse_entry_conf(
        mountpoint: impl AsRef<Path>,
        conf_path: impl AsRef<Path>,
        entry_contents: &str,
    ) -> Result<BlsEntry, tboot::bls::BlsEntryError> {
        let mut entry = BlsEntry::default();

        entry.entry_path = conf_path.as_ref().to_path_buf();
        let filename = conf_path
            .as_ref()
            .file_name()
            .ok_or(tboot::bls::BlsEntryError::MissingFileName)?
            .to_str()
            .unwrap();

        let (entry_name, tries_left, tries_done) = tboot::bls::parse_entry_filename(filename)?;

        entry.name = entry_name.to_string();
        entry.tries_left = tries_left;
        entry.tries_done = tries_done;

        for line in entry_contents.lines() {
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
                "options" => {
                    entry
                        .options
                        .extend(val.trim().split_whitespace().into_iter().map(String::from));
                }
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

    fn boot_count(&self) {
        let Some(tries_left) = self.tries_left else {
            return;
        };

        let Some(entry_dir) = self.entry_path.parent() else {
            return;
        };

        let new_tries_left = tries_left.checked_sub(1).unwrap_or(tries_left);

        let new_entry_path = entry_dir.join(if let Some(tries_done) = self.tries_done {
            format!(
                "{}+{}-{}.conf",
                self.name,
                new_tries_left,
                tries_done.checked_add(1).unwrap_or(tries_done),
            )
        } else {
            format!("{}+{}.conf", self.name, new_tries_left)
        });

        info!(
            "counting boot from {} tries left to {} tries left",
            tries_left, new_tries_left
        );

        if let Err(e) = std::fs::rename(self.entry_path.as_path(), new_entry_path.as_path()) {
            error!(
                "failed to move entry file from {} to {}: {e}",
                self.entry_path.display(),
                new_entry_path.display()
            );
        }
    }
}

impl TryInto<Box<dyn BootEntry>> for BlsEntry {
    type Error = anyhow::Error;

    fn try_into(self) -> Result<Box<dyn BootEntry>, Self::Error> {
        if self.efi.is_some() {
            anyhow::bail!("cannot boot efi");
        }

        if self.linux.is_none() {
            anyhow::bail!("cannot boot without linux");
        }

        if self
            .tries_left
            .map(|tries_left| tries_left == 0)
            .unwrap_or_default()
        {
            anyhow::bail!("entry is bad");
        }

        Ok(Box::new(self) as _)
    }
}

#[derive(Clone)]
struct Disk {
    diskseq: u64,
    device_path: PathBuf,
    entries: Vec<BlsEntry>,
    mountpoint: Option<PathBuf>,
    timeout: Duration,
    removable: bool,
    vendor: Option<String>,
    model: Option<String>,
}

impl Into<BootDevice> for Disk {
    fn into(self) -> BootDevice {
        let timeout = self.timeout;

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
            entries: self
                .entries
                .into_iter()
                .filter_map(|entry| match entry.try_into() {
                    Ok(entry) => Some(entry),
                    Err(e) => {
                        info!("could not convert entry: {e}");
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
            timeout: Duration::from_secs(10),
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
            Some(
                crate::fs::detect_fs_type(std::fs::File::open(&partition_chardev_path)?)
                    .ok_or(anyhow::anyhow!("could not detect fstype"))?
                    .as_str(),
            ),
            MsFlags::MS_NOEXEC | MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
            None::<&[u8]>,
        )?;

        self.mountpoint = Some(mountpoint);

        Ok(())
    }

    fn discover_entries(&mut self, default_entry_name: Option<String>) {
        trace!("searching for BLS entries");

        let Some(mountpoint) = self.mountpoint.as_ref() else {
            error!("disk not mounted");
            return;
        };

        if let Ok(entries_srel) = std::fs::read_to_string(mountpoint.join("loader/entries.srel")) {
            if entries_srel != "type1\n" {
                debug!("/loader/entries.srel not type1, skipping disk");
                return;
            }
        }

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

            let mut parsed_entry = match BlsEntry::parse_entry_conf(
                mountpoint.as_path(),
                &entry_path,
                &entry_conf_contents,
            ) {
                Ok(entry) => entry,
                Err(e) => {
                    error!("failed to parse entry at {:?}: {e}", entry_path);
                    continue;
                }
            };

            parsed_entry.is_default =
                Some(parsed_entry.name.as_str()) == default_entry_name.as_deref();

            if self
                .entries
                .iter()
                .find(|entry| entry.name == parsed_entry.name)
                .is_none()
            {
                debug!("new entry added {}", entry_path.display());
                self.entries.push(parsed_entry);
            }
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

#[derive(Clone)]
struct LoaderConf {
    default_entry: Option<String>,
    timeout: Duration,
}

impl Default for LoaderConf {
    fn default() -> Self {
        Self {
            timeout: Duration::from_secs(10),
            default_entry: None,
        }
    }
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

impl BootLoader for BlsBootLoader {
    fn setup(&mut self) -> anyhow::Result<()> {
        debug!("setup");

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

                // add the disk if it does not already exist
                if self
                    .disks
                    .iter()
                    .find(|disk| disk.diskseq == diskseq)
                    .is_none()
                {
                    self.disks.push(disk);
                }

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

    fn probe(&mut self) -> Vec<BootDevice> {
        debug!("probe");

        let mut devs = Vec::new();

        for disk in self.disks.iter_mut() {
            if let Some(mountpoint) = &disk.mountpoint {
                let loader_conf_path = mountpoint.join("loader/loader.conf");

                let loader_conf_contents = match std::fs::read_to_string(&loader_conf_path) {
                    Ok(l) => l,
                    Err(e) => {
                        debug!(
                            "failed to read loader.conf {}, {e}",
                            loader_conf_path.display()
                        );
                        continue;
                    }
                };

                let loader_conf = LoaderConf::parse_loader_conf(&loader_conf_contents);

                disk.timeout = loader_conf.timeout;

                disk.discover_entries(loader_conf.default_entry);

                devs.push(disk.to_owned().into());
            }
        }

        devs
    }

    fn teardown(&mut self) {
        debug!("teardown");

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
        let entry = super::BlsEntry::parse_entry_conf(Path::new("/foo/bar"), Path::new("/foo/loader/entries/foo.conf"), r#"title NixOS
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
            vec!["init=/nix/store/00000000000000000000000000000000-nixos-system-beetroot-23.05.20230506.0000000/init".to_string(), "systemd.show_status=auto".to_string(), "loglevel=4".to_string()]
        );
    }
}
