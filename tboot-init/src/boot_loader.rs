use log::debug;
use nix::libc;
use std::{ffi, io, os::fd::AsRawFd, path::Path};
use syscalls::{syscall, Sysno};

pub fn kexec_load(
    kernel: impl AsRef<Path>,
    initrd: Option<impl AsRef<Path>>,
    cmdline: &str,
) -> io::Result<()> {
    debug!("loading kernel from {:?}", kernel.as_ref());
    let kernel = std::fs::File::open(kernel)?;
    let kernel_fd = kernel.as_raw_fd() as libc::c_int;
    debug!("kernel loaded as fd {}", kernel_fd);

    debug!("loading cmdline as {:?}", cmdline);
    let cmdline = ffi::CString::new(cmdline)?;
    let cmdline = cmdline.to_bytes_with_nul();

    let retval = if let Some(initrd) = initrd {
        debug!("loading initrd from {:?}", initrd.as_ref());
        let initrd = std::fs::File::open(initrd)?;
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
        std::thread::sleep(std::time::Duration::from_millis(100));
    }

    unsafe { libc::sync() };

    Ok(())
}

pub fn kexec_execute() -> io::Result<()> {
    let ret = unsafe { libc::reboot(libc::LINUX_REBOOT_CMD_KEXEC) };
    if ret < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}
