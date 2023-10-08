use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq)]
pub struct LinuxBootEntry {
    pub default: bool,
    pub display: String,
    pub linux: PathBuf,
    pub initrd: Option<PathBuf>,
    pub cmdline: Option<String>,
}
