pub mod block_device;
pub mod boot_loader;
pub mod fs;
pub mod linux;
pub mod log;
pub mod message;
pub mod verified_boot;

pub const TINYBOOT_SOCKET: &str = "/tmp/tinyboot/tboot.sock";
pub const TINYUSER_UID: u32 = 1000;
pub const TINYUSER_GID: u32 = 1000;
