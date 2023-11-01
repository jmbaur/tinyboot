use std::{ffi::CString, path::PathBuf, str::FromStr};

use log::{error, warn};
use netlink_sys::{protocols::NETLINK_KOBJECT_UEVENT, Socket, SocketAddr};
use nix::libc;

pub fn listen_and_create_devices() -> std::io::Result<()> {
    let mut socket = Socket::new(NETLINK_KOBJECT_UEVENT).unwrap();
    let sa = SocketAddr::new(std::process::id(), 1);
    let mut buf = vec![0; 1024 * 8];
    socket.bind(&sa).unwrap();

    loop {
        let n = socket.recv(&mut buf, 0).unwrap();

        let Ok(uevent) = Uevent::parse(&buf[..n]) else {
            continue;
        };

        let path = PathBuf::from("/dev").join(uevent.devname);
        let parent = path.parent().expect("/dev should always exist");
        std::fs::create_dir_all(&parent).unwrap();

        match uevent.event {
            EventType::Add => {
                let path = CString::new(path.to_str().unwrap()).unwrap();
                unsafe {
                    libc::mknod(
                        path.as_ptr(),
                        uevent.devtype.into(),
                        libc::makedev(uevent.major, uevent.minor),
                    )
                };
            }
            EventType::Remove => {
                if let Err(e) = std::fs::remove_file(&path) {
                    error!("failed to remove device {}: {e}", path.display());
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

#[derive(PartialEq, Debug, Default)]
enum DevType {
    Disk,
    #[default]
    Character,
}

impl Into<u32> for DevType {
    fn into(self) -> u32 {
        match self {
            DevType::Disk => libc::S_IFBLK,
            DevType::Character => libc::S_IFCHR,
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
    major: u32,
    minor: u32,
    devname: &'a str,
    devtype: DevType,
}

impl<'a> Uevent<'a> {
    fn parse(bytes: &'a [u8]) -> Result<Uevent<'a>, ()> {
        let uevent_str = std::str::from_utf8(bytes).unwrap();

        let mut split = uevent_str.split('\0');

        let Some(event_type) = dbg!(split.next()) else {
            return Err(());
        };

        let Some((event_type, _)) = dbg!(event_type.split_once('@')) else {
            return Err(());
        };

        let event_type = dbg!(EventType::from_str(event_type)?);

        let mut major = None;
        let mut minor = None;
        let mut devname = None;
        let mut devtype = None;

        loop {
            match dbg!(split.next().map(|s| s.split_once('=')).flatten()) {
                Some(("DEVNAME", name)) => devname = Some(name),
                Some(("DEVTYPE", "disk")) => devtype = Some(DevType::Disk),
                Some(("MAJOR", maj)) => {
                    if let Ok(maj) = u32::from_str_radix(maj, 10) {
                        major = Some(maj);
                    }
                }
                Some(("MINOR", min)) => {
                    if let Ok(min) = u32::from_str_radix(min, 10) {
                        minor = Some(min);
                    }
                }
                None => break,
                _ => {}
            }
        }

        Ok(Self {
            event: event_type,
            major: major.ok_or(())?,
            minor: minor.ok_or(())?,
            devname: devname.ok_or(())?,
            devtype: devtype.unwrap_or_default(),
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
                major: 4,
                minor: 70,
                devname: "ttyS6",
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
                major: 4,
                minor: 70,
                devname: "ttyS6",
                devtype: super::DevType::Character,
            }
        );
    }
}
