use crate::linux::LinuxBootEntry;
use std::time::Duration;

pub mod bls;

#[derive(Debug)]
pub enum Error {
    BootConfigNotFound,
    InvalidEntry,
    InvalidMountpoint,
    Io(std::io::Error),
    DuplicateConfig,
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

pub trait BootLoader {
    fn timeout(&self) -> Duration;

    fn boot_entries(&self) -> Result<Vec<LinuxBootEntry>, Error>;
}
