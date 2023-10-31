use std::{fmt::Display, path::PathBuf, str::FromStr, time::Duration};

pub mod disk;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoaderType {
    Disk,
}

impl Display for LoaderType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}",
            match self {
                Self::Disk => "disk",
            }
        )
    }
}

impl FromStr for LoaderType {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "disk" => Ok(Self::Disk),
            _ => anyhow::bail!("invalid loader '{}'", s),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct LinuxBootEntry {
    pub display: String,
    pub linux: PathBuf,
    pub initrd: Option<PathBuf>,
    pub cmdline: Option<String>,
}

pub struct BootDevice {
    pub name: String,
    pub default_entry: usize,
    pub entries: Vec<LinuxBootEntry>,
    pub timeout: Duration,
}

pub trait LinuxBootLoader {
    fn loader_type(&mut self) -> LoaderType;

    fn startup(&mut self) -> anyhow::Result<()>;

    fn probe(&mut self) -> anyhow::Result<Vec<BootDevice>>;

    fn shutdown(&mut self);
}

pub enum LoaderState {
    Unstarted,
    Started,
    Probed,
    Shutdown,
}

pub struct Loader {
    boot_devices: Vec<BootDevice>,
    state: LoaderState,
    inner: Box<dyn LinuxBootLoader>,
}

impl From<Box<dyn LinuxBootLoader>> for Loader {
    fn from(value: Box<dyn LinuxBootLoader>) -> Self {
        Loader::new(value)
    }
}

impl Loader {
    pub fn new(loader: Box<dyn LinuxBootLoader>) -> Self {
        Self {
            state: LoaderState::Unstarted,
            boot_devices: Vec::new(),
            inner: loader,
        }
    }

    pub fn startup(&mut self) -> anyhow::Result<()> {
        match self.state {
            LoaderState::Unstarted | LoaderState::Shutdown => self.inner.startup()?,
            LoaderState::Started | LoaderState::Probed => {}
        }

        self.state = LoaderState::Started;

        Ok(())
    }

    pub fn probe(&mut self) -> anyhow::Result<()> {
        match self.state {
            LoaderState::Probed => return Ok(()),
            LoaderState::Started => {}
            LoaderState::Unstarted | LoaderState::Shutdown => self.startup()?,
        }

        self.boot_devices = self.inner.probe()?;

        self.state = LoaderState::Probed;

        Ok(())
    }

    pub fn shutdown(&mut self) {
        match self.state {
            LoaderState::Started | LoaderState::Probed => self.inner.shutdown(),
            LoaderState::Unstarted | LoaderState::Shutdown => {}
        };
        self.boot_devices = Vec::new();
        self.state = LoaderState::Shutdown;
    }

    pub fn boot_devices(&mut self) -> anyhow::Result<&[BootDevice]> {
        self.probe()?;
        Ok(&self.boot_devices)
    }

    pub fn loader_type(&mut self) -> LoaderType {
        self.inner.loader_type()
    }
}

impl Drop for Loader {
    fn drop(&mut self) {
        self.shutdown();
    }
}
