use std::fmt::Display;
use std::os::fd::AsRawFd;
use std::path::PathBuf;

#[derive(Debug)]
pub enum Error {
    NotFound,
    Unknown,
}
impl Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:#?}")
    }
}
impl std::error::Error for Error {}

pub trait Booter {
    fn get_parts(&self) -> Result<Vec<BootParts>, Error>;
}

#[derive(Debug, Default)]
pub struct BootParts {
    pub default: bool,
    pub name: String,
    pub kernel: PathBuf,
    pub initrd: PathBuf,
    pub cmdline: String,
    pub dtb: Option<PathBuf>,
}

impl Display for BootParts {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.dtb.is_some() {
            write!(
                f,
                "{}\n\tkernel={:#?}\n\tinitrd={:#?}\n\tparams={:#?}\n\tdtb={:#?}\n",
                self.name, self.kernel, self.initrd, self.cmdline, self.dtb
            )
        } else {
            write!(
                f,
                "{}\n\tkernel={:#?}\n\tinitrd={:#?}\n\tparams={:#?}\n",
                self.name, self.kernel, self.initrd, self.cmdline
            )
        }
    }
}

impl BootParts {
    pub fn kexec(&self) -> std::io::Result<()> {
        println!("{self}");
        let kernel = std::fs::File::open(&self.kernel).unwrap().as_raw_fd() as usize;
        let initrd = std::fs::File::open(&self.initrd).unwrap().as_raw_fd() as usize;
        let cmdline = std::ffi::CString::new(self.cmdline.as_str()).unwrap();
        let retval: usize;

        // TODO(jared): pass dtb
        #[cfg(target_arch = "aarch64")]
        unsafe {
            asm!(
                "svc #0",
                in("w8") nix::libc::SYS_kexec_file_load,
                inout("x0") kernel => retval,
                in("x1") initrd,
                in("x2") cmdline.to_bytes_with_nul().len(),
                in("x3") cmdline.as_ptr(),
                in("x4") 0,
                in("x5") 0,
            );
        }

        #[cfg(target_arch = "x86_64")]
        unsafe {
            std::arch::asm!(
                "syscall",
                inout("rax") nix::libc::SYS_kexec_file_load => retval,
                in("rdi") kernel,
                in("rsi") initrd,
                in("rdx") cmdline.to_bytes_with_nul().len(),
                in("r10") cmdline.as_ptr(),
                in("r8") 0,
                in("r9") 0,
            );
        }

        if retval > -4096isize as usize {
            let code = -(retval as isize) as i32;
            return Err(std::io::Error::from_raw_os_error(code));
        }

        Ok(())
    }
}
