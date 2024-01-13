use std::{
    collections::HashMap,
    ffi::CString,
    path::PathBuf,
    str::FromStr,
    sync::mpsc::{Receiver, RecvTimeoutError, Sender},
    time::Duration,
};

use log::{debug, error, warn};
use netlink_sys::{protocols::NETLINK_KOBJECT_UEVENT, Socket, SocketAddr};
use nix::libc;

/// Listens to Kobject events from the kernel over netlink and creates character and block devices
/// under `/dev`. For block devices, aliases are created under `/dev/disk/<diskseq>` for disks and
/// `/dev/part/<diskseq>/<partnum>` for partitions.
pub fn listen_and_create_devices(tx: Sender<()>) -> std::io::Result<()> {
    let mut socket = Socket::new(NETLINK_KOBJECT_UEVENT)?;
    let sa = SocketAddr::new(std::process::id(), 1);
    socket.bind(&sa)?;

    loop {
        let bytes = match socket.recv_from_full() {
            Ok((b, _)) => b,
            Err(e) => {
                error!("failed to receive kobject uevent: {e}");
                continue;
            }
        };

        let uevent = match Uevent::parse(&bytes) {
            Ok(u) => u,
            Err(e) => {
                error!("failed to parse uevent: {e:?}");
                continue;
            }
        };

        let (Some(devname), Some(major), Some(minor)) =
            (uevent.devname, uevent.major, uevent.minor)
        else {
            continue;
        };

        debug!("{:?}->{} {},{}", uevent.event, devname, major, minor);

        _ = tx.send(());

        let path = PathBuf::from("/dev").join(devname);
        let parent = path.parent().expect("/dev should always exist");
        std::fs::create_dir_all(&parent).unwrap();

        match uevent.event {
            EventType::Add => {
                let c_path = CString::new(path.to_str().unwrap()).unwrap();

                let special: Special = uevent.devtype.into();

                let res = unsafe {
                    if path.exists() {
                        0
                    } else {
                        libc::mknod(c_path.as_ptr(), special.0, libc::makedev(major, minor))
                    }
                };

                if res < 0 {
                    error!("mknod: {}", std::io::Error::last_os_error());
                } else {
                    match uevent.devtype {
                        DevType::Character => {}
                        DevType::Disk(diskseq) => add_disk_symlink(devname, diskseq),
                        DevType::Partition(diskseq, partnum) => {
                            add_partition_symlink(devname, diskseq, partnum)
                        }
                    }
                }
            }
            EventType::Remove => {
                if let Err(e) = std::fs::remove_file(&path) {
                    error!("failed to remove device {}: {e}", path.display());
                }

                match uevent.devtype {
                    DevType::Character => {}
                    DevType::Disk(diskseq) => remove_disk_symlink(diskseq),
                    DevType::Partition(diskseq, partnum) => {
                        remove_partition_symlink(diskseq, partnum)
                    }
                }
            }
            _ => warn!(
                "unhandled kobject event: {:?} {}",
                uevent.event,
                path.display()
            ),
        }
    }
}

#[derive(PartialEq, Debug, Copy, Clone, Default)]
enum DevType {
    /// Disk contains diskseq
    Disk(u32),
    /// Partition contains diskseq and part number
    Partition(u32, u32),
    #[default]
    Character,
}

struct Special(u32);
impl Into<Special> for DevType {
    fn into(self) -> Special {
        match self {
            DevType::Disk(_) | DevType::Partition(_, _) => Special(libc::S_IFBLK),
            DevType::Character => Special(libc::S_IFCHR),
        }
    }
}

#[derive(PartialEq, Debug)]
enum EventType {
    Add,
    Remove,
    Change,
    Move,
    Online,
    Offline,
    Bind,
    Unbind,
}

impl FromStr for EventType {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "add" => Self::Add,
            "remove" => Self::Remove,
            "change" => Self::Change,
            "move" => Self::Move,
            "online" => Self::Online,
            "offline" => Self::Offline,
            "bind" => Self::Bind,
            "unbind" => Self::Unbind,
            _ => return Err(()),
        })
    }
}

#[derive(PartialEq, Debug)]
struct Uevent<'a> {
    event: EventType,
    major: Option<u32>,
    minor: Option<u32>,
    devname: Option<&'a str>,
    devtype: DevType,
}

#[derive(Debug)]
enum Error<'a> {
    InvalidUevent,
    MissingEventType,
    InvalidEventType(&'a str),
}

impl<'a> Uevent<'a> {
    fn parse(bytes: &'a [u8]) -> Result<Uevent<'a>, Error> {
        let Ok(uevent_str) = std::str::from_utf8(bytes) else {
            return Err(Error::InvalidUevent);
        };

        let mut split = uevent_str.split('\0');

        let Some(event_type) = split.next() else {
            return Err(Error::MissingEventType);
        };

        let Some((event_type, _)) = event_type.split_once('@') else {
            return Err(Error::MissingEventType);
        };

        let event =
            EventType::from_str(event_type).map_err(|_| Error::InvalidEventType(event_type))?;

        let uevent = {
            let mut uevent = HashMap::new();

            while let Some((k, v)) = split.next().map(|s| s.split_once('=')).flatten() {
                uevent.insert(k, v);
            }

            uevent
        };

        let devname = uevent.get("DEVNAME").copied();

        let major = uevent
            .get("MAJOR")
            .map(|major| u32::from_str_radix(major, 10))
            .transpose()
            .map_err(|_| Error::InvalidUevent)?;

        let minor = uevent
            .get("MINOR")
            .map(|minor| u32::from_str_radix(minor, 10))
            .transpose()
            .map_err(|_| Error::InvalidUevent)?;

        let devtype = uevent
            .get("SUBSYSTEM")
            .map(|&subsystem| match subsystem {
                "block" => {
                    if let Some(partn) = uevent.get("PARTN") {
                        // is partition
                        match (
                            uevent
                                .get("DISKSEQ")
                                .map(|diskseq| u32::from_str_radix(diskseq, 10).ok())
                                .flatten(),
                            u32::from_str_radix(partn, 10).ok(),
                        ) {
                            (Some(diskseq), Some(partn)) => {
                                Some(DevType::Partition(diskseq, partn))
                            }
                            _ => None,
                        }
                    } else {
                        // is disk
                        uevent
                            .get("DISKSEQ")
                            .map(|diskseq| {
                                u32::from_str_radix(diskseq, 10)
                                    .map(|diskseq| DevType::Disk(diskseq))
                                    .ok()
                            })
                            .flatten()
                    }
                }
                _ => Some(DevType::Character),
            })
            .flatten()
            .ok_or(Error::InvalidUevent)?;

        Ok(Self {
            event,
            major,
            minor,
            devname,
            devtype,
        })
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn parse_add() {
        const DATA: &[u8] = b"add@/devices/platform/serial8250/tty/ttyS6\0\
                              ACTION=add\0\
                              DEVPATH=/devices/platform/serial8250/tty/ttyS6\0\
                              SUBSYSTEM=tty\0\
                              SYNTH_UUID=0\0\
                              MAJOR=4\0\
                              MINOR=70\0\
                              DEVNAME=ttyS6\0\
                              SEQNUM=3469";

        let uevent = super::Uevent::parse(DATA).unwrap();

        assert_eq!(
            uevent,
            super::Uevent {
                event: super::EventType::Add,
                major: Some(4),
                minor: Some(70),
                devname: Some("ttyS6"),
                devtype: super::DevType::Character,
            }
        );
    }

    #[test]
    fn parse_remove() {
        const DATA: &[u8] = b"remove@/devices/platform/serial8250/tty/ttyS6\0\
                              ACTION=remove\0\
                              DEVPATH=/devices/platform/serial8250/tty/ttyS6\0\
                              SUBSYSTEM=tty\0\
                              SYNTH_UUID=0\0\
                              MAJOR=4\0\
                              MINOR=70\0\
                              DEVNAME=ttyS6\0\
                              SEQNUM=3471";

        let uevent = super::Uevent::parse(DATA).unwrap();

        assert_eq!(
            uevent,
            super::Uevent {
                event: super::EventType::Remove,
                major: Some(4),
                minor: Some(70),
                devname: Some("ttyS6"),
                devtype: super::DevType::Character,
            }
        );
    }

    #[test]
    fn parse_add_disk() {
        const DATA: &[u8] = b"add@/devices/platform/4010000000.pcie/pci0000:00/0000:00:02.0/usb2/2-1/2-1:1.0/host0/target0:0:0/0:0:0:0/block/sda\0\
                                ACTION=add\0\
                                DEVPATH=/devices/platform/4010000000.pcie/pci0000:00/0000:00:02.0/usb2/2-1/2-1:1.0/host0/target0:0:0/0:0:0:0/block/sda\0\
                                SUBSYSTEM=block\0\
                                MAJOR=8\0\
                                MINOR=0\0\
                                DEVNAME=sda\0\
                                DEVTYPE=disk\0\
                                DISKSEQ=3\0\
                                SEQNUM=532\0";

        let uevent = super::Uevent::parse(DATA).unwrap();
        assert_eq!(
            uevent,
            super::Uevent {
                event: super::EventType::Add,
                major: Some(8),
                minor: Some(0),
                devname: Some("sda"),
                devtype: super::DevType::Disk(3),
            }
        );
    }
}

/// This function relies on the linux kernel option `CONFIG_DEVTMPFS` being enabled, since this
/// means that any devices detected by the kernel before our code runs will be setup for us as soon
/// as /dev is mounted. This means that this function only needs to setup any symlinks that we use
/// as a convenience for accessing devices.
pub fn scan_and_create_devices() {
    if let Ok(dir) = std::fs::read_dir("/sys/class/block") {
        for entry in dir {
            let Ok(entry) = entry else {
                continue;
            };

            if let Ok(uevent) = std::fs::read_to_string(entry.path().join("uevent")) {
                let mut uevent_map = parse_uevent(uevent);

                let Some(devname) = uevent_map.remove("DEVNAME") else {
                    continue;
                };

                let Some(Ok(diskseq)) = uevent_map
                    .remove("DISKSEQ")
                    .map(|diskseq| u32::from_str_radix(&diskseq, 10))
                else {
                    continue;
                };

                let Ok(partn) = uevent_map
                    .remove("PARTN")
                    .map(|partn| u32::from_str_radix(&partn, 10))
                    .transpose()
                else {
                    continue;
                };

                match uevent_map.remove("DEVTYPE").as_deref() {
                    Some("disk") => add_disk_symlink(&devname, diskseq),
                    Some("partition") => {
                        if let Some(partn) = partn {
                            add_partition_symlink(&devname, diskseq, partn);
                        }
                    }
                    _ => {}
                }
            }
        }
    }
}

fn add_disk_symlink(devname: &str, diskseq: u32) {
    let disk_dir = PathBuf::from("/dev/disk");

    std::fs::create_dir_all(&disk_dir).unwrap();

    std::os::unix::fs::symlink(
        PathBuf::from("/dev").join(devname),
        disk_dir.join(diskseq.to_string()),
    )
    .unwrap();
}

fn remove_disk_symlink(diskseq: u32) {
    let disk_symlink = PathBuf::from("/dev/disk").join(diskseq.to_string());

    _ = std::fs::remove_file(disk_symlink);
}

fn add_partition_symlink(devname: &str, diskseq: u32, partn: u32) {
    let disk_part_dir = PathBuf::from("/dev/part").join(diskseq.to_string());

    std::fs::create_dir_all(&disk_part_dir).unwrap();

    std::os::unix::fs::symlink(
        PathBuf::from("/dev").join(devname),
        disk_part_dir.join(partn.to_string()),
    )
    .unwrap();
}

fn remove_partition_symlink(diskseq: u32, partn: u32) {
    let part_symlink = PathBuf::from("/dev/part")
        .join(diskseq.to_string())
        .join(partn.to_string());

    _ = std::fs::remove_file(part_symlink);
}

pub fn parse_uevent(contents: String) -> HashMap<String, String> {
    contents.lines().fold(HashMap::new(), |mut map, line| {
        if let Some((key, val)) = line.split_once('=') {
            map.insert(key.to_string(), val.to_string());
        }
        map
    })
}

/// Blocks until no new messages have been received in some maximum wait time
pub fn wait_for_settle(new_dev_rx: Receiver<()>, max_wait: Duration) {
    loop {
        match new_dev_rx.recv_timeout(max_wait) {
            Err(RecvTimeoutError::Timeout) => break,
            _ => {}
        }
    }
}
