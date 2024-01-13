use log::{debug, trace};
use nix::libc;
use std::{ffi, os::fd::AsRawFd};
use syscalls::{syscall, Sysno};

use crate::boot_loader::LinuxBootParts;

pub fn kexec_load(boot_entry: LinuxBootParts) -> std::io::Result<()> {
    let kernel = &boot_entry.linux;
    let initrd = &boot_entry.initrd;
    let cmdline = boot_entry
        .cmdline
        .as_ref()
        .map(|s| s.as_str())
        .unwrap_or_default();

    debug!("loading kernel from {}", kernel.display());
    let kernel = std::fs::File::open(kernel)?;
    let kernel_fd = kernel.as_raw_fd() as libc::c_int;
    trace!("kernel loaded as fd {}", kernel_fd);

    debug!("loading cmdline as {}", cmdline);
    let cmdline = ffi::CString::new(cmdline)?;
    let cmdline = cmdline.to_bytes_with_nul();

    let retval = if let Some(initrd) = initrd {
        debug!("loading initrd from {}", initrd.display());
        let initrd = std::fs::File::open(initrd)?;
        let initrd_fd = initrd.as_raw_fd() as libc::c_int;
        trace!("initrd loaded as fd {}", initrd_fd);

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
        return Err(std::io::Error::from_raw_os_error(code));
    }

    while std::fs::read("/sys/kernel/kexec_loaded")? != [b'1', b'\n'] {
        debug!("waiting for kexec_loaded");
        std::thread::sleep(std::time::Duration::from_millis(100));
    }

    Ok(())
}

pub fn kexec_execute() -> std::io::Result<()> {
    let ret = unsafe { libc::reboot(libc::LINUX_REBOOT_CMD_KEXEC) };
    if ret < 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}
