use kobject_uevent::UEvent;
use log::{info, LevelFilter};
use std::{
    io::prelude::*,
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
};

fn main() -> anyhow::Result<()> {
    tboot::log::setup_logging(LevelFilter::Info)?;

    let serial_ports = serialport::available_ports().unwrap();
    info!("found serial ports:");
    for port in serial_ports {
        // port_name in the form of /sys/class/tty/ttyS0
        let port_sysfs_path = Path::new(&port.port_name);

        let Ok(uevent) = UEvent::from_sysfs_path(port_sysfs_path, "/sys") else {
            continue;
        };

        let Some(devname) = uevent.env.get("DEVNAME") else { continue; };
        let mut dev_path = PathBuf::from("/dev");
        dev_path.push(devname);
        info!("{:?}", dev_path);
    }

    let mut stream = UnixStream::connect("/tmp/tinyboot.sock")?;
    stream.write_all(b"hello world")?;

    Ok(())
}
