use log::debug;
use nix::libc;
use std::fmt::{self, Display};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::{self, Duration};
use std::{error, ffi, fs, io, thread};
use syscalls::{syscall, Sysno};

#[derive(Debug)]
pub enum Error {
    BootConfigNotFound,
    BootEntryNotFound,
    Eval(grub::EvalError),
    InvalidEntry,
    InvalidMountpoint,
    Io(io::Error),
}

impl Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}

impl error::Error for Error {}

impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Error::Io(e)
    }
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub enum MenuEntry<'a> {
    /// BootEntry: (ID, name)
    BootEntry((&'a str, &'a str)),
    /// SubMenu: (ID, name, entries)
    SubMenu((&'a str, &'a str, Vec<MenuEntry<'a>>)),
}

pub trait BootLoader {
    fn timeout(&self) -> Duration;

    fn mountpoint(&self) -> &Path;

    fn menu_entries(&self) -> Result<Vec<MenuEntry>, Error>;

    /// If the entry ID is None, the boot loader should choose the default boot entry.
    /// The Ok() result tuple looks like: (kernel, initrd, cmdline)
    fn boot_info(&mut self, entry_id: Option<String>) -> Result<(PathBuf, PathBuf, String), Error>;
}

pub fn kexec_load(kernel: &Path, initrd: &Path, cmdline: &str) -> io::Result<()> {
    debug!("loading kernel from {:?}", kernel);
    let kernel = fs::File::open(kernel)?;
    let kernel = kernel.as_raw_fd() as usize;

    debug!("loading initrd from {:?}", initrd);
    let initrd = fs::File::open(initrd)?;
    let initrd = initrd.as_raw_fd();

    debug!("loading cmdline as {:?}", cmdline);
    let cmdline = ffi::CString::new(cmdline)?;
    let cmdline = cmdline.to_bytes_with_nul();

    let retval = unsafe {
        syscall!(
            Sysno::kexec_file_load,
            kernel,
            initrd,
            cmdline.len(),
            cmdline.as_ptr(),
            0
        )?
    };

    if retval > -4096isize as usize {
        let code = -(retval as isize) as i32;
        return Err(io::Error::from_raw_os_error(code));
    }

    while std::fs::read("/sys/kernel/kexec_loaded")? != [b'1', b'\n'] {
        debug!("waiting for kexec_loaded");
        thread::sleep(time::Duration::from_millis(100));
    }

    unsafe { libc::sync() };

    Ok(())
}

pub fn kexec_execute() -> io::Result<()> {
    let ret = unsafe { libc::reboot(libc::LINUX_REBOOT_CMD_KEXEC) };
    if ret < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
