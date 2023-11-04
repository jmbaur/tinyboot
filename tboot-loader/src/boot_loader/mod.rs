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
pub struct LinuxBootParts {
    pub linux: PathBuf,
    pub initrd: Option<PathBuf>,
    pub cmdline: Option<String>,
}

pub trait BootEntry: Display {
    fn is_default(&self) -> bool;

    fn select(&self) -> LinuxBootParts;
}

pub struct BootDevice {
    pub name: String,
    pub entries: Vec<Box<dyn BootEntry>>,
    pub timeout: Duration,
}

pub trait BootLoader {
    fn loader_type(&mut self) -> LoaderType;

    fn prepare(&mut self) -> anyhow::Result<()>;

    fn probe(&mut self) -> Vec<BootDevice>;

    fn teardown(&mut self);
}

pub enum LoaderState {
    Unstarted,
    Started,
    Probed,
    Shutdown,
}

pub struct Loader {
    /// boot_devices is expected to be ordered based on priority of usage of that device. Hence the
    /// first device in the vec will be used as the default device to boot from.
    boot_devices: Vec<BootDevice>,
    state: LoaderState,
    inner: Box<dyn BootLoader>,
}

impl Loader {
    pub fn new(loader: Box<dyn BootLoader>) -> Self {
        Self {
            state: LoaderState::Unstarted,
            boot_devices: Vec::new(),
            inner: loader,
        }
    }

    pub fn startup(&mut self) -> anyhow::Result<()> {
        match self.state {
            LoaderState::Unstarted | LoaderState::Shutdown => self.inner.prepare()?,
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

        self.boot_devices = self.inner.probe();

        self.state = LoaderState::Probed;

        Ok(())
    }

    pub fn shutdown(&mut self) {
        match self.state {
            LoaderState::Started | LoaderState::Probed => self.inner.teardown(),
            LoaderState::Unstarted | LoaderState::Shutdown => {}
        };
        self.boot_devices.clear();
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
