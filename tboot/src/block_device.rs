use crate::{
    boot_loader::{bls::BlsBootLoader, BootLoader, Error},
    linux::LinuxBootEntry,
};
use crc::{Crc, CRC_32_ISCSI};
use kobject_uevent::UEvent;
use log::{debug, error};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    time::Duration,
};

pub const CASTAGNOLI: Crc<u32> = Crc::<u32>::new(&CRC_32_ISCSI);

#[derive(Clone, Debug)]
pub struct BlockDevice {
    pub timeout: Duration,
    pub name: String,
    pub removable: bool,
    pub boot_entries: Vec<LinuxBootEntry>,
    pub partition_mounts: HashMap<PathBuf, PathBuf>,
}

impl TryFrom<UEvent> for BlockDevice {
    type Error = anyhow::Error;

    fn try_from(uevent: UEvent) -> Result<Self, Self::Error> {
        if &uevent.subsystem != "block" {
            anyhow::bail!("not block subsystem");
        }

        let devtype = uevent
            .env
            .get("DEVTYPE")
            .ok_or(anyhow::anyhow!("no devtype"))?;

        if devtype != "disk" {
            anyhow::bail!("not a disk");
        }

        let devname = uevent
            .env
            .get("DEVNAME")
            .ok_or(anyhow::anyhow!("no devname"))?;

        // devpath is of the form "/devices/blah/blah"
        let devpath = uevent.devpath.strip_prefix("/")?;

        let removable = {
            let mut removable_path = PathBuf::from("/sys/class");
            removable_path.push(uevent.subsystem);
            removable_path.push(devname);
            removable_path.push("removable");
            debug!("reading removable path {:?}", removable_path);
            std::fs::read_to_string(removable_path)
                .unwrap_or_else(|_| String::from("1"))
                .trim()
                .parse::<u8>()
                .unwrap_or(1)
                == 1
        };

        let name = {
            let mut model_path = PathBuf::from("/sys");
            model_path.push(devpath);
            model_path.push("device");
            model_path.push("model");
            debug!("reading model from {:?}", model_path);
            let model =
                std::fs::read_to_string(model_path).unwrap_or_else(|_| String::from("Unknown"));
            let model = model.trim();

            let mut vendor_path = PathBuf::from("/sys");
            vendor_path.push(devpath);
            vendor_path.push("device");
            vendor_path.push("vendor");
            debug!("reading vendor from {:?}", vendor_path);
            let vendor =
                std::fs::read_to_string(vendor_path).unwrap_or_else(|_| String::from("Unknown"));
            let vendor = vendor.trim();

            let mut device_subsystem_link_path = PathBuf::from("/sys");
            device_subsystem_link_path.push(devpath);
            device_subsystem_link_path.push("device");
            device_subsystem_link_path.push("subsystem");
            debug!("reading subsystem from {:?}", device_subsystem_link_path);
            let subsystem_path = std::fs::read_link(device_subsystem_link_path)?;
            let subsystem = subsystem_path
                .file_name()
                .and_then(|file_name| file_name.to_str())
                .unwrap_or("disk")
                .trim();

            if removable {
                format!("[{subsystem}]: {model} {vendor} (removable)")
            } else {
                format!("[{subsystem}]: {model} {vendor}")
            }
        };

        // TODO(jared): Use fs::read_dir based on mdev.conf that will put all partitions under
        // /dev/disk/vda/N, where N is the partition number.
        let dev_partitions = find_disk_partitions(|p| {
            let Some(filename) = p.file_name() else {
                return false;
            };
            let Some(filename) = filename.to_str() else {
                return false;
            };
            filename.starts_with(devname)
        })?;

        debug!("discovered disk: {}", name);

        let partition_mounts =
            dev_partitions
                .into_iter()
                .fold(HashMap::new(), |mut hmap, partition| {
                    match mount_block_device(&partition) {
                        Err(e) => {
                            error!("failed to mount block device {:?}: {e}", partition);
                        }
                        Ok(mount) => {
                            hmap.insert(partition, mount);
                        }
                    };

                    hmap
                });

        let mut seen_config_files = HashMap::new();

        let mut timeout = Duration::from_secs(0);

        let boot_entries =
            partition_mounts
                .iter()
                .fold(Vec::new(), |mut boot_entries, (_, mount)| {
                    if let Some((Ok(entries), new_timeout)) =
                        if let Ok(bls) = find_bls(&mut seen_config_files, mount) {
                            Some((bls.boot_entries(), bls.timeout()))
                        } else {
                            None
                        }
                    {
                        boot_entries.extend(entries);
                        if new_timeout > timeout {
                            timeout = new_timeout;
                        }
                    }

                    boot_entries
                });

        if boot_entries.is_empty() {
            anyhow::bail!("no boot entries");
        } else {
            Ok(BlockDevice {
                name,
                removable,
                partition_mounts,
                boot_entries,
                timeout,
            })
        }
    }
}

pub fn find_disk_partitions<F>(filter: F) -> anyhow::Result<Vec<PathBuf>>
where
    F: Fn(&Path) -> bool,
{
    Ok(std::fs::read_dir("/sys/class/block")?
        .filter_map(|blk_dev| {
            let direntry = blk_dev.ok()?;
            let path = direntry.path();

            let Ok(uevent) = UEvent::from_sysfs_path(path, Path::new("/sys")) else {
                return None;
            };

            if &uevent.subsystem != "block" {
                return None;
            }

            let Some(devtype) = uevent.env.get("DEVTYPE") else {
                return None;
            };

            if devtype.as_str() != "partition" {
                return None;
            }

            let Some(devname) = uevent.env.get("DEVNAME") else {
                return None;
            };

            let mut dev_path = PathBuf::from("/dev");
            dev_path.push(devname);

            debug!("found partition at {dev_path:?}");

            if filter(&dev_path) {
                Some(dev_path)
            } else {
                None
            }
        })
        .collect::<Vec<PathBuf>>())
}

pub fn mount_block_device(block_device: impl AsRef<Path>) -> anyhow::Result<PathBuf> {
    let mountpoint = PathBuf::from("/mnt").join(
        block_device
            .as_ref()
            .to_str()
            .ok_or(anyhow::anyhow!("invalid UTF-8"))?
            .trim_start_matches('/')
            .replace('/', "-"),
    );

    let fstype = crate::fs::detect_fs_type(&block_device)?;

    std::fs::create_dir_all(&mountpoint)?;

    nix::mount::mount(
        Some(block_device.as_ref()),
        &mountpoint,
        Some(match fstype {
            crate::fs::FsType::Iso9660 => "iso9660",
            crate::fs::FsType::Ext4(..) => "ext4",
            crate::fs::FsType::Vfat(..) => "vfat",
        }),
        nix::mount::MsFlags::MS_RDONLY,
        None::<&[u8]>,
    )?;

    Ok(mountpoint)
}

pub fn find_bls(
    seen_config_files: &mut HashMap<u32, Option<()>>,
    mount: &Path,
) -> Result<impl BootLoader, Error> {
    let config_file = 'config: {
        for path in ["loader/loader.conf", "boot/loader/loader.conf"] {
            let search_path = mount.join(path);

            debug!(
                "searching for BLS configuration at {}",
                search_path.display()
            );

            if search_path.exists() {
                break 'config Some(search_path);
            }
        }

        None
    };

    let Some(config_file) = config_file else {
        return Err(Error::BootConfigNotFound);
    };

    let source = std::fs::read_to_string(config_file)?;

    let checksum = CASTAGNOLI.checksum(source.as_bytes());
    if seen_config_files.get(&checksum).is_some() {
        return Err(Error::DuplicateConfig);
    }

    seen_config_files.insert(checksum, Some(()));

    BlsBootLoader::parse_loader_conf(mount, source)
}
