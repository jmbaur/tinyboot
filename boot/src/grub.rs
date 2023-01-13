use std::{collections::HashMap, fs, path::Path};

use crate::boot_loader::{BootConfiguration, BootLoader, Error};
use crate::util::*;
use grub::{GrubEvaluator, MenuEntry};
use log::{debug, info, warn};

#[derive(Default, Debug)]
pub struct Grub {
    env: HashMap<String, String>,
}

impl Grub {
    pub fn new(mount_point: &Path) -> Result<Self, Error> {
        let search_path = mount_point.join("boot/grub/grub.cfg");

        if let Err(e) = fs::metadata(&search_path) {
            warn!("{}: {}", search_path.display(), e)
        } else {
            info!("found grub configuration at {}", search_path.display());
            return Ok(Self::default());
        }

        Err(Error::BootConfigNotFound)
    }

    /// Doesn't check if config file exists on mount path
    pub fn new_unchecked(_mount_point: &Path) -> Self {
        Self::default()
    }

    fn run_initrd(&self, _args: Vec<String>) -> u8 {
        todo!()
    }

    fn run_linux(&self, _args: Vec<String>) -> u8 {
        todo!()
    }

    fn run_save_env(&self, _args: Vec<String>) -> u8 {
        todo!()
    }

    fn run_search(&self, _args: Vec<String>) -> u8 {
        todo!()
    }

    fn run_set(&mut self, args: Vec<String>) -> u8 {
        match args.len() {
            0 | 1 => 2,
            2 => match (args[0].as_str(), args[1].as_str()) {
                (key, "=") => {
                    self.env.remove(key);
                    0
                }
                _ => 2,
            },
            3 => match (args[0].as_str(), args[1].as_str(), args[2].as_str()) {
                (key, "=", val) => {
                    self.env.insert(key.to_string(), val.to_string());
                    0
                }
                _ => 2,
            },
            _ => 2,
        }
    }

    /// Returns exit code 0 if the test evaluates to true.
    /// Returns exit code 1 if the test evaluates to false.
    /// Returns exit code 2 if the arguments are invalid.
    fn run_test(&self, args: Vec<String>) -> u8 {
        match args.len() {
            0 => 2,
            1 => string_nonzero_length(&args[0]),
            2 => match (args[0].as_str(), args[1].as_str()) {
                // file exists and is a directory
                ("-d", file) => file_exists_and_is_directory(file),
                // file exists
                ("-e", file) => file_exists(file),
                // file exists and is not a directory
                ("-f", file) => file_exists_and_is_not_directory(file),
                // file exists and has a size greater than zero
                ("-s", file) => file_exists_and_size_greater_than_zero(file),
                // the length of string is nonzero
                ("-n", string) => string_nonzero_length(string),
                // the length of string is zero
                ("-z", string) => string_zero_length(string),
                // expression is false
                ("!", _expression) => todo!(),
                _ => 2,
            },
            3 => match (args[0].as_str(), args[1].as_str(), args[2].as_str()) {
                // the strings are equal
                (string1, "=", string2) => strings_equal(string1, string2),
                // the strings are equal
                (string1, "==", string2) => strings_equal(string1, string2),
                // the strings are not equal
                (string1, "!=", string2) => strings_not_equal(string1, string2),
                // string1 is lexicographically less than string2
                (string1, "<", string2) => strings_lexographically_less_than(string1, string2),
                // string1 is lexicographically less or equal than string2
                (string1, "<=", string2) => {
                    strings_lexographically_less_than_or_equal_to(string1, string2)
                }
                // string1 is lexicographically greater than string2
                (string1, ">", string2) => strings_lexographically_greater_than(string1, string2),
                // string1 is lexicographically greater or equal than string2
                (string1, ">=", string2) => {
                    strings_lexographically_greater_than_or_equal_to(string1, string2)
                }
                // integer1 is equal to integer2
                (integer1, "-eq", integer2) => integers_equal(integer1, integer2),
                // integer1 is greater than or equal to integer2
                (integer1, "-ge", integer2) => {
                    integers_greater_than_or_equal_to(integer1, integer2)
                }
                // integer1 is greater than integer2
                (integer1, "-gt", integer2) => integers_greater_than(integer1, integer2),
                // integer1 is less than or equal to integer2
                (integer1, "-le", integer2) => integers_less_than_or_equal_to(integer1, integer2),
                // integer1 is less than integer2
                (integer1, "-lt", integer2) => integers_less_than(integer1, integer2),
                // integer1 is not equal to integer2
                (integer1, "-ne", integer2) => integers_not_equal(integer1, integer2),
                // integer1 is greater than integer2 after stripping off common non-numeric prefix.
                (prefixinteger1, "-pgt", prefixinteger2) => {
                    integers_prefix_greater_than(prefixinteger1, prefixinteger2)
                }
                // integer1 is less than integer2 after stripping off common non-numeric prefix.
                (prefixinteger1, "-plt", prefixinteger2) => {
                    integers_prefix_less_than(prefixinteger1, prefixinteger2)
                }
                // file1 is newer than file2 (modification time). Optionally numeric bias may be directly appended to -nt in which case it is added to the first file modification time.
                (file1, "-nt", file2) => file_newer_than(file1, file2),
                // file1 is older than file2 (modification time). Optionally numeric bias may be directly appended to -ot in which case it is added to the first file modification time.
                (file1, "-ot", file2) => file_older_than(file1, file2),
                // both expression1 and expression2 are true
                (_expression1, "-a", _expression2) => todo!(),
                // either expression1 or expression2 is true
                (_expression1, "-o", _expression2) => todo!(),
                // expression is true
                ("(", _expression, ")") => todo!(),
                _ => 2,
            },
            _ => 2,
        }
    }
}

impl GrubEvaluator for Grub {
    fn run_command(&mut self, command: String, args: Vec<String>) -> u8 {
        match command.as_str() {
            "initrd" => self.run_initrd(args),
            "linux" => self.run_linux(args),
            "save_env" => self.run_save_env(args),
            "search" => self.run_search(args),
            "set" => self.run_set(args),
            "test" => self.run_test(args),
            _ => {
                debug!("'{}' not implemented", command);
                0
            }
        }
    }

    fn select_menuentry(&self, _menus: HashMap<String, Vec<MenuEntry>>) -> MenuEntry {
        todo!()
    }

    fn set_env(&mut self, key: String, val: Option<String>) {
        if let Some(val) = val {
            self.env.insert(key, val);
        } else {
            self.env.remove(&key);
        }
    }

    fn get_env(&self, _key: &str) -> Option<&String> {
        self.env.get(_key)
    }
}

impl BootLoader for Grub {
    fn get_boot_configuration(&self) -> Result<BootConfiguration, Error> {
        todo!()
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    #[test]
    fn grub_run_test() {
        let g = Grub::new_unchecked(&PathBuf::from("/"));
        assert_eq!(g.run_test(vec!["-d".to_string(), "/dev".to_string()]), 0);
        assert_eq!(g.run_test(vec!["-f".to_string(), "/dev".to_string()]), 1);
        assert_eq!(g.run_test(vec!["-e".to_string(), "/dev".to_string()]), 0);
        assert_eq!(g.run_test(vec!["-n".to_string(), "foo".to_string()]), 0);
        assert_eq!(g.run_test(vec!["-z".to_string(), "foo".to_string()]), 1);
        assert_eq!(g.run_test(vec!["-z".to_string(), "".to_string()]), 0);
        assert_eq!(
            g.run_test(vec![
                "foo1".to_string(),
                "-pgt".to_string(),
                "bar0".to_string()
            ]),
            0
        );
    }
}
