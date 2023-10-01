use crate::linux::LinuxBootEntry;
use std::time::Duration;

pub mod bls;

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("boot config not found")]
    BootConfigNotFound,
    #[error("invalid entry")]
    InvalidEntry,
    #[error("invalid mount")]
    InvalidMountpoint,
    #[error("IO error")]
    Io(std::io::Error),
    #[error("duplicate config")]
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
