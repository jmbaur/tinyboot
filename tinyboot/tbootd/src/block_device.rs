use crate::fs::{detect_fs_type, FsType};
use crate::message::Msg;
use kobject_uevent::UEvent;
use log::{debug, error};
use netlink_sys::{protocols::NETLINK_KOBJECT_UEVENT, Socket, SocketAddr};
use nix::{libc::MSG_DONTWAIT, mount};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::{
        atomic::AtomicBool,
        mpsc::{Receiver, Sender},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

pub struct BlockDevice {
    pub name: String,
    pub removable: bool,
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

        // TODO(jared): Use fs::read_dir based on mdev.conf that will put all partitions under
        // /dev/disk/vda/N, where N is the partition number.
        let dev_partitions = find_disk_partitions(|p| {
            let Some(filename) = p.file_name() else { return false; };
            let Some(filename) = filename.to_str() else { return false; };
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

        Ok(BlockDevice {
            name,
            removable,
            partition_mounts,
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

            debug!("trying to get block device for {:?}", uevent.devpath);

            match BlockDevice::try_from(uevent) {
                Ok(bd) => Some(bd),
                Err(e) => {
                    error!("failed to get block device: {}", e);
                    None
                }
            }
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

pub enum MountMsg {
    UnmountAll,
    NewMount(PathBuf),
}

pub fn handle_unmounting(rx: Receiver<MountMsg>) -> JoinHandle<()> {
    thread::spawn(move || {
        let mut mountpoints = Vec::new();

        loop {
            if let Ok(msg) = rx.recv() {
                match msg {
                    MountMsg::NewMount(mount) => mountpoints.push(mount),
                    MountMsg::UnmountAll => {
                        debug!("unmounting all mounts");
                        if mountpoints
                            .iter()
                            .map(|mountpoint| {
                                mount::umount2(mountpoint, mount::MntFlags::MNT_DETACH)
                            })
                            .any(|result| result.is_err())
                        {
                            error!("could not unmount all partitions");
                        }

                        // quit the main thread loop so we can continue booting
                        break;
                    }
                }
            }
        }
    })
}

pub fn mount_all_devs(
    blockdev_tx: Sender<Msg>,
    mount_tx: Sender<MountMsg>,
    done: Arc<AtomicBool>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        match find_disks() {
            Err(e) => error!("failed to get initial block devices: {e}"),
            Ok(initial_devs) => {
                for bd in initial_devs {
                    bd.partition_mounts.values().for_each(|mountpoint| {
                        _ = mount_tx.send(MountMsg::NewMount(mountpoint.to_path_buf()));
                    });

                    if blockdev_tx.send(Msg::Device(bd)).is_err() {
                        break;
                    }
                }
            }
        };

        let mut socket = Socket::new(NETLINK_KOBJECT_UEVENT).unwrap();
        let sa = SocketAddr::new(0, 1 << 0);
        socket.bind(&sa).unwrap();

        let mut buf = bytes::BytesMut::with_capacity(1024 * 8);
        'outer: loop {
            if done.load(Ordering::Relaxed) {
                break;
            }

            // sleep since we are setting MSG_DONTWAIT on our recv_from call
            thread::sleep(Duration::from_millis(100));

            buf.clear();
            let Ok(_) = socket.recv_from(&mut buf, MSG_DONTWAIT) else {
                continue;
            };

            let n = buf.len();
            let Ok(uevent) = UEvent::from_netlink_packet(&buf[..n]) else {
                continue;
            };

            // Wait for mdev daemon to create device node for block device.
            if let Some(devname) = uevent.env.get("DEVNAME") {
                let mut devpath = PathBuf::from("/dev");
                devpath.push(devname);
                let mut tries = 0;
                while !devpath.exists() {
                    thread::sleep(Duration::from_millis(100));
                    tries += 1;
                    if tries >= 5 {
                        continue 'outer;
                    }
                }
            }

            let Ok(bd) = BlockDevice::try_from(uevent) else {
                continue;
            };

            bd.partition_mounts.values().for_each(|mountpoint| {
                _ = mount_tx.send(MountMsg::NewMount(mountpoint.to_path_buf()));
            });

            if blockdev_tx.send(Msg::Device(bd)).is_err() {
                break;
            }
        }
    })
}
