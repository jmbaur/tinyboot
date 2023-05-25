use std::path::PathBuf;

use crate::boot_loader::BootLoader;

pub struct BlockDevice {
    pub name: String,
    pub removable: bool,
    pub bootloader: Box<dyn BootLoader + Send>,
    pub boot_partition_mountpoint: PathBuf,
}
