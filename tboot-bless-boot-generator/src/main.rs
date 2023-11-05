use std::path::PathBuf;

use log::debug;

#[derive(Debug)]
enum Error {
    InvalidArgs,
    InvalidGeneratorPath,
    Io(std::io::Error),
}

impl From<std::io::Error> for Error {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

// TODO(jared): systemd's bless-boot-generator exits early if it detects it is running in a
// container
fn main() -> Result<(), Error> {
    let mut args = std::env::args().into_iter();

    let _normal_dir = args.next().ok_or(Error::InvalidArgs)?;
    let early_dir = args.next().ok_or(Error::InvalidArgs)?;
    let _late_dir = args.next().ok_or(Error::InvalidArgs)?;

    // https://www.freedesktop.org/software/systemd/man/latest/systemd.generator.html#%24SYSTEMD_IN_INITRD
    if std::env::var("SYSTEMD_IN_INITRD")
        .map(|systemd_in_initrd| systemd_in_initrd.as_str() == "1")
        .unwrap_or_default()
    {
        debug!("Skipping generator, running in the initrd.");
        return Ok(());
    }

    if !std::fs::read_to_string("/proc/cmdline")?.contains("tboot.bls-entry") {
        debug!("Skipping generator, not booted with boot counting in effect.");
        return Ok(());
    }

    let unit_path = PathBuf::from(early_dir)
        .join("basic.target.wants")
        .join("tboot-bless-boot.service");

    std::fs::create_dir_all(unit_path.parent().ok_or(Error::InvalidGeneratorPath)?)?;

    std::os::unix::fs::symlink("/etc/systemd/system/tboot-bless-boot.service", unit_path)?;

    Ok(())
}
