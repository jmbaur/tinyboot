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

#[derive(Clone, Debug, PartialEq)]
pub struct LinuxBootEntry {
    pub default: bool,
    pub display: String,
    pub linux: PathBuf,
    pub initrd: Option<PathBuf>,
    pub cmdline: Option<String>,
}

pub trait BootLoader {
    fn timeout(&self) -> Duration;

    fn boot_entries(&self) -> Result<Vec<LinuxBootEntry>, Error>;
}

pub fn kexec_load(
    kernel: impl AsRef<Path>,
    initrd: Option<impl AsRef<Path>>,
    cmdline: &str,
) -> io::Result<()> {
    debug!("loading kernel from {:?}", kernel.as_ref());
    let kernel = fs::File::open(kernel)?;
    let kernel_fd = kernel.as_raw_fd() as libc::c_int;
    debug!("kernel loaded as fd {}", kernel_fd);

    debug!("loading cmdline as {:?}", cmdline);
    let cmdline = ffi::CString::new(cmdline)?;
    let cmdline = cmdline.to_bytes_with_nul();

    let retval = if let Some(initrd) = initrd {
        debug!("loading initrd from {:?}", initrd.as_ref());
        let initrd = fs::File::open(initrd)?;
        let initrd_fd = initrd.as_raw_fd() as libc::c_int;
        debug!("initrd loaded as fd {}", initrd_fd);

        unsafe {
            syscall!(
                Sysno::kexec_file_load,
                kernel_fd,
                initrd_fd,
                cmdline.len(),
                cmdline.as_ptr(),
                0 as libc::c_ulong
            )?
        }
    } else {
        unsafe {
            syscall!(
                Sysno::kexec_file_load,
                kernel_fd,
                0 as libc::c_int, // this gets ignored when KEXEC_FILE_NO_INITRAMFS is set
                cmdline.len(),
                cmdline.as_ptr(),
                nix::libc::KEXEC_FILE_NO_INITRAMFS as libc::c_ulong
            )?
        }
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
