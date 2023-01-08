#[allow(dead_code)]
pub type ExitCode = u8;

#[allow(dead_code)]
pub type ReturnValue = String;

#[allow(dead_code)]
pub type CommandReturn = (ExitCode, ReturnValue);

pub trait GrubEval {
    /// Load ACPI tables
    fn command_acpi() -> CommandReturn;
    /// Check whether user is in user list
    fn command_authenticate() -> CommandReturn;
    /// Set background color for active terminal
    fn command_background_color() -> CommandReturn;
    /// Load background image for active terminal
    fn command_background_image() -> CommandReturn;
    /// Filter out bad regions of RAM
    fn command_badram() -> CommandReturn;
    /// Print a block list
    fn command_blocklist() -> CommandReturn;
    /// Start up your operating system
    fn command_boot() -> CommandReturn;
    /// Show the contents of a file
    fn command_cat() -> CommandReturn;
    /// Chain-load another boot loader
    fn command_chainloader() -> CommandReturn;
    /// Clear the screen
    fn command_clear() -> CommandReturn;
    /// Clear bit in CMOS
    fn command_cmosclean() -> CommandReturn;
    /// Dump CMOS contents
    fn command_cmosdump() -> CommandReturn;
    /// Test bit in CMOS
    fn command_cmostest() -> CommandReturn;
    /// Compare two files
    fn command_cmp() -> CommandReturn;
    /// Load a configuration file
    fn command_configfile() -> CommandReturn;
    /// Check for CPU features
    fn command_cpuid() -> CommandReturn;
    /// Compute or check CRC32 checksums
    fn command_crc() -> CommandReturn;
    /// Mount a crypto device
    fn command_cryptomount() -> CommandReturn;
    /// Remove memory regions
    fn command_cutmem() -> CommandReturn;
    /// Display or set current date and time
    fn command_date() -> CommandReturn;
    /// Load a device tree blob
    fn command_devicetree() -> CommandReturn;
    /// Remove a pubkey from trusted keys
    fn command_distrust() -> CommandReturn;
    /// Map a drive to another
    fn command_drivemap() -> CommandReturn;
    /// Display a line of text
    fn command_echo() -> CommandReturn;
    /// Evaluate agruments as GRUB commands
    fn command_eval() -> CommandReturn;
    /// Export an environment variable
    fn command_export() -> CommandReturn;
    /// Do nothing, unsuccessfully
    fn command_false() -> CommandReturn;
    /// Translate a string
    fn command_gettext() -> CommandReturn;
    /// Fill an MBR based on GPT entries
    fn command_gptsync() -> CommandReturn;
    /// Shut down your computer
    fn command_halt() -> CommandReturn;
    /// Compute or check hash checksum
    fn command_hashsum() -> CommandReturn;
    /// Show help messages
    fn command_help() -> CommandReturn;
    /// Load a Linux initrd
    fn command_initrd() -> CommandReturn;
    /// Load a Linux initrd (16-bit mode)
    fn command_initrd16() -> CommandReturn;
    /// Insert a module
    fn command_insmod() -> CommandReturn;
    /// Check key modifier status
    fn command_keystatus() -> CommandReturn;
    /// Load a Linux kernel
    fn command_linux() -> CommandReturn;
    /// Load a Linux kernel (16-bit mode)
    fn command_linux16() -> CommandReturn;
    /// List variables in environment block
    fn command_listenv() -> CommandReturn;
    /// List trusted public keys
    fn command_list_trusted() -> CommandReturn;
    /// Load variables from environment block
    fn command_load_env() -> CommandReturn;
    /// Load font files
    fn command_loadfont() -> CommandReturn;
    /// Make a device from a filesystem image
    fn command_loopback() -> CommandReturn;
    /// List devices or files
    fn command_ls() -> CommandReturn;
    /// List loaded fonts
    fn command_lsfonts() -> CommandReturn;
    /// Show loaded modules
    fn command_lsmod() -> CommandReturn;
    /// Compute or check MD5 hash
    fn command_md5sum() -> CommandReturn;
    /// Start a menu entry
    fn command_menuentry() -> CommandReturn;
    /// Load module for multiboot kernel
    fn command_module() -> CommandReturn;
    /// Load multiboot compliant kernel
    fn command_multiboot() -> CommandReturn;
    /// Switch to native disk drivers
    fn command_nativedisk() -> CommandReturn;
    /// Enter normal mode
    fn command_normal() -> CommandReturn;
    /// Exit from normal mode
    fn command_normal_exit() -> CommandReturn;
    /// Modify partition table entries
    fn command_parttool() -> CommandReturn;
    /// Set a clear-text password
    fn command_password() -> CommandReturn;
    /// Set a hashed password
    fn command_password_pbkdf2() -> CommandReturn;
    /// Play a tune
    fn command_play() -> CommandReturn;
    /// Retrieve device info
    fn command_probe() -> CommandReturn;
    /// Read values from model-specific registers
    fn command_rdmsr() -> CommandReturn;
    /// Read user input
    fn command_read() -> CommandReturn;
    /// Reboot your computer
    fn command_reboot() -> CommandReturn;
    /// Test if regular expression matches string
    fn command_regexp() -> CommandReturn;
    /// Remove a module
    fn command_rmmod() -> CommandReturn;
    /// Save variables to environment block
    fn command_save_env() -> CommandReturn;
    /// Search devices by file, label, or UUID
    fn command_search() -> CommandReturn;
    /// Emulate keystrokes
    fn command_sendkey() -> CommandReturn;
    /// Set up a serial device
    fn command_serial() -> CommandReturn;
    /// Set an environment variable
    fn command_set() -> CommandReturn;
    /// Compute or check SHA1 hash
    fn command_sha1sum() -> CommandReturn;
    /// Compute or check SHA256 hash
    fn command_sha256sum() -> CommandReturn;
    /// Compute or check SHA512 hash
    fn command_sha512sum() -> CommandReturn;
    /// Wait for a specified number of seconds
    fn command_sleep() -> CommandReturn;
    /// Retrieve SMBIOS information
    fn command_smbios() -> CommandReturn;
    /// Read a configuration file in same context
    fn command_source() -> CommandReturn;
    /// Group menu entries
    fn command_submenu() -> CommandReturn;
    /// Manage input terminals
    fn command_terminal_input() -> CommandReturn;
    /// Manage output terminals
    fn command_terminal_output() -> CommandReturn;
    /// Define terminal type
    fn command_terminfo() -> CommandReturn;
    /// Check file types and compare values
    fn command_test() -> CommandReturn;
    /// Check file types and compare values '['
    fn command_test_alias() -> CommandReturn;
    /// Do nothing, successfully
    fn command_true() -> CommandReturn;
    /// Add public key to list of trusted keys
    fn command_trust() -> CommandReturn;
    /// Unset an environment variable
    fn command_unset() -> CommandReturn;
    /// Verify detached digital signature
    fn command_verify_detached() -> CommandReturn;
    /// List available video modes
    fn command_videoinfo() -> CommandReturn;
    /// Write values to model-specific registers
    fn command_wrmsr() -> CommandReturn;
    /// Load xen hypervisor binary (only on AArch64)
    fn command_xen_hypervisor() -> CommandReturn;
    /// Load xen modules for xen hypervisor (only on AArch64)
    fn command_xen_module() -> CommandReturn;
}
