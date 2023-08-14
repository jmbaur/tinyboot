use crate::message::InternalMsg;
use kobject_uevent::UEvent;
use log::{debug, error};
use netlink_sys::{protocols::NETLINK_KOBJECT_UEVENT, Socket, SocketAddr};
use nix::{libc::MSG_DONTWAIT, mount};
use std::{
    fs,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use tboot::block_device::BlockDevice;
use tokio::{sync::mpsc, task::JoinHandle};

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

pub enum MountMsg {
    UnmountAll,
    NewMount(PathBuf),
}

pub fn handle_unmounting(mut rx: mpsc::Receiver<MountMsg>) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut mountpoints = Vec::new();

        loop {
            if let Some(msg) = rx.recv().await {
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
    internal_tx: mpsc::Sender<InternalMsg>,
    mount_tx: mpsc::Sender<MountMsg>,
    done: Arc<AtomicBool>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        match find_disks() {
            Err(e) => error!("failed to get initial block devices: {e}"),
            Ok(initial_devs) => {
                for bd in initial_devs {
                    for mountpoint in bd.partition_mounts.values() {
                        _ = mount_tx
                            .send(MountMsg::NewMount(mountpoint.to_path_buf()))
                            .await;
                    }

                    if internal_tx.send(InternalMsg::Device(bd)).await.is_err() {
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
            tokio::time::sleep(Duration::from_millis(100)).await;

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
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    tries += 1;
                    if tries >= 5 {
                        continue 'outer;
                    }
                }
            }

            let Ok(bd) = BlockDevice::try_from(uevent) else {
                continue;
            };

            for mountpoint in bd.partition_mounts.values() {
                _ = mount_tx
                    .send(MountMsg::NewMount(mountpoint.to_path_buf()))
                    .await;
            }

            if internal_tx.send(InternalMsg::Device(bd)).await.is_err() {
                break;
            }
        }
    })
}
