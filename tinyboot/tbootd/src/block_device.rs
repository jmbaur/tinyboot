use crate::bls::BlsBootLoader;
use crate::device::BlockDevice;
use crate::fs::{detect_fs_type, FsType};
use crate::grub::GrubBootLoader;
use crate::syslinux::SyslinuxBootLoader;
use kobject_uevent::UEvent;
use log::{debug, error};
use nix::mount;
use std::fs;
use std::path::{Path, PathBuf};

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
            fs::read_to_string(removable_path)
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
            let model = fs::read_to_string(model_path).unwrap_or_else(|_| String::from("Unknown"));
            let model = model.trim();

            let mut vendor_path = PathBuf::from("/sys");
            vendor_path.push(devpath);
            vendor_path.push("device");
            vendor_path.push("vendor");
            debug!("reading vendor from {:?}", vendor_path);
            let vendor =
                fs::read_to_string(vendor_path).unwrap_or_else(|_| String::from("Unknown"));
            let vendor = vendor.trim();

            let mut device_subsystem_link_path = PathBuf::from("/sys");
            device_subsystem_link_path.push(devpath);
            device_subsystem_link_path.push("device");
            device_subsystem_link_path.push("subsystem");
            debug!("reading subsystem from {:?}", device_subsystem_link_path);
            let subsystem_path = fs::read_link(device_subsystem_link_path)?;
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

        let dev_partitions = find_disk_partitions(|p| {
            let Some(filename) = p.file_name() else { return false; };
            let Some(filename) = filename.to_str() else { return false; };
            filename.starts_with(devname)
        })?;

        debug!("discovered disk: {}", name);

        let (bootloader, boot_partition_mountpoint) = dev_partitions.iter().find_map(|part| {
            let mountpoint = match mount_block_device(part) {
                Err(e) => {
                    error!("failed to mount block device {:?}: {e}", part);
                    return None;
                }
                Ok(m) => m,
            };

            if let Ok(bls_config) = BlsBootLoader::get_config(&mountpoint) {
                let Ok(bls) = BlsBootLoader::new(&mountpoint, &bls_config) else { return None; };
                debug!("found bls bootloader");
                Some((bls, mountpoint))
            } else if let Ok(grub_config) = GrubBootLoader::get_config(&mountpoint) {
                let Ok(grub) = GrubBootLoader::new(&mountpoint, &grub_config) else { return None; };
                debug!("found grub bootloader");
                Some((grub, mountpoint))
            } else if let Ok(syslinux_config) = SyslinuxBootLoader::get_config(&mountpoint) {
                let Ok(syslinux) = SyslinuxBootLoader::new(&syslinux_config)else { return None; };
                debug!("found syslinux bootloader");
                Some((syslinux, mountpoint))
            } else {
                None
            }
        }).ok_or(anyhow::anyhow!("no bootloader"))?;

        Ok(BlockDevice {
            bootloader,
            name,
            removable,
            boot_partition_mountpoint,
        })
    }
}

pub fn find_disks() -> anyhow::Result<Vec<BlockDevice>> {
    Ok(fs::read_dir("/sys/class/block")?
        .filter_map(|blk_dev| {
            let direntry = blk_dev.ok()?;
            let path = direntry.path();

            let Ok(uevent) = UEvent::from_sysfs_path(path, "/sys") else {
                return None;
            };

            BlockDevice::try_from(uevent).ok()
        })
        .collect())
}

pub fn find_disk_partitions<F>(filter: F) -> anyhow::Result<Vec<PathBuf>>
where
    F: Fn(&Path) -> bool,
{
    Ok(fs::read_dir("/sys/class/block")?
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

    let fstype = detect_fs_type(&block_device)?;

    std::fs::create_dir_all(&mountpoint)?;

    mount::mount(
        Some(block_device.as_ref()),
        &mountpoint,
        Some(match fstype {
            FsType::Iso9660 => "iso9660",
            FsType::Ext4(..) => "ext4",
            FsType::Vfat(..) => "vfat",
        }),
        mount::MsFlags::MS_RDONLY,
        None::<&[u8]>,
    )?;

    Ok(mountpoint)
}
