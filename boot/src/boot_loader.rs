use log::debug;
use std::fmt::{self, Display};
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::time::{self, Duration};
use std::{arch, error, ffi, fs, io, thread};

#[derive(Debug)]
pub enum Error {
    Many(Vec<Error>),
    BootConfigNotFound,
    IoError(io::Error),
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

pub trait BootLoader {
    fn get_boot_configuration(&self) -> Result<BootConfiguration, Error>;
}

#[derive(Debug, Default, PartialEq, Eq, Clone)]
pub struct BootEntry {
    pub default: bool,
    pub name: String,
    pub kernel: PathBuf,
    pub initrd: PathBuf,
    pub cmdline: String,
    pub dtb: Option<PathBuf>,
}

impl Display for BootEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}\n\tkernel={:?}\n\tinitrd={:?}\n\tparams={:?}\n\t{}\n",
            self.name,
            self.kernel,
            self.initrd,
            self.cmdline,
            self.dtb
                .as_ref()
                .map(|dtb| format!("dtb={:?}", dtb))
                .as_deref()
                .unwrap_or_default()
        )
    }
}

impl BootEntry {
    pub fn kexec(&self) -> io::Result<()> {
        let kernel = fs::File::open(&self.kernel)?;
        let kernel = kernel.as_raw_fd() as usize;
        let initrd = fs::File::open(&self.initrd)?;
        let initrd = initrd.as_raw_fd();
        let cmdline = ffi::CString::new(self.cmdline.as_str())?;
        let cmdline = cmdline.to_bytes_with_nul();

        debug!("kernel loaded from {}", self.kernel.display());
        debug!("initrd loaded from {}", self.initrd.display());
        debug!("cmdline loaded as {:?}", self.cmdline);

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

        let ret = unsafe { libc::reboot(libc::LINUX_REBOOT_CMD_KEXEC) };
        if ret < 0 {
            return Err(io::Error::last_os_error());
        }

        Ok(())
    }
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub enum MenuEntry {
    BootEntry(BootEntry),
    Submenu((String, Vec<MenuEntry>)),
}

#[derive(Debug)]
pub struct BootConfiguration {
    pub timeout: Duration,
    pub entries: Vec<MenuEntry>,
}
