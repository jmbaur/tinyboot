use kobject_uevent::UEvent;
use std::io::prelude::*;
use std::{
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
};

fn main() {
    let serial_ports = serialport::available_ports().unwrap();
    eprintln!("found serial ports:");
    for port in serial_ports {
        // port_name in the form of /sys/class/tty/ttyS0
        let port_sysfs_path = Path::new(&port.port_name);

        let Ok(uevent) = UEvent::from_sysfs_path(port_sysfs_path, "/sys") else {
            continue;
        };

        let Some(devname) = uevent.env.get("DEVNAME") else { continue; };
        let mut dev_path = PathBuf::from("/dev");
        dev_path.push(devname);
        if false {
            eprintln!("{:?}", dev_path);
        }
    }

    if false {
        let mut stream = UnixStream::connect("/tmp/tinyboot.sock").unwrap();
        stream.write_all(b"hello world").unwrap();
    }
}
