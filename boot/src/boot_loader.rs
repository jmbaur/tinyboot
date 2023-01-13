use log::debug;
use std::fmt::{self, Display};
use std::os::fd::AsRawFd;
use std::path::Path;
use std::time::{self, Duration};
use std::{arch, error, ffi, fs, io, thread};

#[derive(Debug)]
pub enum Error {
    BootConfigNotFound,
    BootEntryNotFound,
    InvalidConfigFormat,
    IoError(io::Error),
    Many(Vec<Error>),
}

impl Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}

impl error::Error for Error {}

impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Error::IoError(e)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum MenuEntry<'a> {
    /// BootEntry: (ID, name)
    BootEntry((&'a str, &'a str)),
    /// SubMenu: (ID, name)
    SubMenu((&'a str, Vec<MenuEntry<'a>>)),
}

pub trait BootLoader {
    fn timeout(&self) -> Duration;

    fn menu_entries(&self) -> Result<Vec<MenuEntry>, Error>;

    fn mountpoint(&self) -> &Path;

    /// If the entry ID is None, the boot loader should choose the default boot entry.
    /// The Ok() result tuple looks like: (kernel, initrd, cmdline, Option<dtb>)
    fn boot_info(
        &self,
        entry_id: Option<&str>,
    ) -> Result<(&Path, &Path, &str, Option<&Path>), Error>;
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

    let retval: usize;

    #[cfg(target_arch = "aarch64")]
    unsafe {
        // NOTE: this is not defined in rust's libc crate for musl aarch64, see
        // https://git.musl-libc.org/cgit/musl/tree/arch/aarch64/bits/syscall.h.in#n279 for the definition
        // of aarch64's kexec_file_load.
        const SYS_KEXEC_FILE_LOAD: std::ffi::c_long = 294;

        // TODO(jared): pass dtb
        arch::asm!(
            "svc #0",
            in("w8") SYS_KEXEC_FILE_LOAD,
            inout("x0") kernel => retval,
            in("x1") initrd,
            in("x2") cmdline.len(),
            in("x3") cmdline.as_ptr(),
            in("x4") 0,
            in("x5") 0,
        );
    }

    #[cfg(target_arch = "x86_64")]
    unsafe {
        arch::asm!(
            "syscall",
            inout("rax") libc::SYS_kexec_file_load => retval,
            in("rdi") kernel,
            in("rsi") initrd,
            in("rdx") cmdline.len(),
            in("r10") cmdline.as_ptr(),
            in("r8") 0,
            in("r9") 0,
        );
    }

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
