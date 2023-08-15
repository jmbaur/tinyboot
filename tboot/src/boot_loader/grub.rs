use crate::{
    block_device::find_disk_partitions,
    boot_loader::{BootLoader, Error},
    fs::FsType,
    linux::LinuxBootEntry,
};
use clap::{ArgAction, Parser};
use grub::GrubEnvironment;
use log::{debug, error};
use std::str::FromStr;
use std::{
    collections::HashMap,
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
    time::Duration,
};

const GRUB_ENVIRONMENT_BLOCK_LENGTH: i32 = 1024;
const GRUB_ENVIRONMENT_BLOCK_HEADER: &str = r#"# GRUB Environment Block
# WARNING: Do not edit this file by tools other than grub-editenv!!!"#;

fn grub_environment_block(env: Vec<(String, String)>) -> Result<String, String> {
    let mut block = String::new();
    block.push_str(GRUB_ENVIRONMENT_BLOCK_HEADER);
    block.push('\n');
    for (name, value) in env {
        let line = format!("{name}={value}\n");
        block.push_str(line.as_str());
    }
    let fill_len = GRUB_ENVIRONMENT_BLOCK_LENGTH - block.len() as i32;
    if fill_len < 0 {
        Err("environment block too large".to_string())
    } else {
        block.push_str("#".repeat(fill_len.try_into().unwrap()).as_str());
        Ok(block)
    }
}

fn load_env(contents: impl Into<String>, whitelisted_vars: Vec<String>) -> Vec<(String, String)> {
    contents
        .into()
        .lines()
        .filter(|line| !line.starts_with('#'))
        .fold(Vec::new(), |mut acc, curr| {
            if let Some(split) = curr.split_once('=') {
                if whitelisted_vars.is_empty() || whitelisted_vars.iter().any(|a| a == split.0) {
                    acc.push((split.0.to_string(), split.1.to_string()));
                }
            }
            acc
        })
}

#[derive(Debug, PartialEq, Eq)]
pub enum GrubEnvironmentError {
    EnvironmentBlock,
    False,
    InvalidArgs,
    Io(String),
    MissingEnvironmentVariable,
    Nix(String),
    NotImplemented,
    ParseInt,
}

impl From<nix::errno::Errno> for GrubEnvironmentError {
    fn from(value: nix::errno::Errno) -> Self {
        Self::Nix(value.to_string())
    }
}

impl From<io::Error> for GrubEnvironmentError {
    fn from(value: io::Error) -> Self {
        Self::Io(value.to_string())
    }
}

impl From<clap::error::Error> for GrubEnvironmentError {
    fn from(_value: clap::error::Error) -> Self {
        Self::InvalidArgs
    }
}

pub struct TinybootGrubEnvironment {
    env: HashMap<String, String>,
    scope: Option<HashMap<String, String>>,
}

// https://www.gnu.org/software/grub/manual/grub/grub.html#search
#[derive(Parser, Debug, PartialEq, Eq)]
struct SearchArgs {
    #[arg(short = 'f', long, conflicts_with_all = ["label", "fs_uuid"])]
    file: bool,
    #[arg(short = 'l', long, conflicts_with_all = ["file", "fs_uuid"])]
    label: bool,
    #[arg(short = 'u', long, conflicts_with_all = ["file", "label"])]
    fs_uuid: bool,
    #[arg(long)]
    no_floppy: bool,
    #[arg(long)]
    set: String,
    name: String,
}

#[derive(Parser, Debug)]
struct LoadEnvArgs {
    #[arg(long, value_parser, default_value = "grubenv")]
    file: PathBuf,
    #[arg(default_value_t = false)]
    skip_sig: bool,
    #[arg(action = ArgAction::Append)]
    whitelisted_variables: Vec<String>,
}

#[derive(Parser, Debug)]
struct SaveEnvArgs {
    #[arg(long, value_parser, default_value = "grubenv")]
    file: PathBuf,
    #[arg(action = ArgAction::Append)]
    variables: Vec<String>,
}

impl TinybootGrubEnvironment {
    pub fn new(root: impl Into<String>, prefix: impl Into<String>) -> Self {
        let env = HashMap::from([
            ("?".to_string(), 0.to_string()),
            ("prefix".to_string(), prefix.into()),
            ("root".to_string(), root.into()),
            ("grub_platform".to_string(), "tinyboot".to_string()),
        ]);

        debug!("creating new tinyboot grub environment: {env:?}");

        Self { env, scope: None }
    }

    // TODO(jared): the docs mention being able to load multiple initrds, we need to support that
    // (by concatenate the extracted cpios?).
    // https://www.gnu.org/software/grub/manual/grub/html_node/initrd.html#initrd
    fn run_initrd(&mut self, args: Vec<String>) -> Result<(), GrubEnvironmentError> {
        let mut args = args.iter();

        // remove command name
        if args.next().is_none() {
            return Err(GrubEnvironmentError::InvalidArgs);
        }

        let Some(initrd) = args.next() else {
            return Err(GrubEnvironmentError::InvalidArgs);
        };

        let initrd = initrd.replace(|c| matches!(c, '(' | ')'), "");

        debug!("setting 'initrd' to '{}'", initrd);
        if let Some(scope) = &mut self.scope {
            scope.insert("initrd".to_string(), initrd);
        } else {
            self.env.insert("initrd".to_string(), initrd);
        }

        Ok(())
    }

    fn run_linux(&mut self, args: Vec<String>) -> Result<(), GrubEnvironmentError> {
        let mut args = args.iter();

        // remove command name
        if args.next().is_none() {
            return Err(GrubEnvironmentError::InvalidArgs);
        }

        let Some(kernel) = args.next() else {
            return Err(GrubEnvironmentError::InvalidArgs);
        };

        debug!("setting 'linux' to '{}'", kernel);
        if let Some(scope) = &mut self.scope {
            scope.insert("linux".to_string(), kernel.to_string());
        } else {
            self.env.insert("linux".to_string(), kernel.to_string());
        }

        let mut cmdline = Vec::new();
        for next in args {
            cmdline.push(next.to_string());
        }
        let cmdline = cmdline.join(" ");

        debug!("setting 'linux_cmdline' to '{}'", cmdline);
        if let Some(scope) = &mut self.scope {
            scope.insert("linux_cmdline".to_string(), cmdline);
        } else {
            self.env.insert("linux_cmdline".to_string(), cmdline);
        }

        Ok(())
    }

    fn run_load_env(&mut self, args: Vec<String>) -> Result<(), GrubEnvironmentError> {
        let args = LoadEnvArgs::try_parse_from(args)?;

        let Some(prefix) = self.env.get("prefix") else {
            return Err(GrubEnvironmentError::MissingEnvironmentVariable);
        };

        let prefix = PathBuf::from(prefix);
        let mut file = fs::File::open(prefix.join(args.file))?;

        let mut contents = String::new();
        file.read_to_string(&mut contents)?;

        let env = load_env(contents, args.whitelisted_variables);
        self.env.extend(env);

        Ok(())
    }

    fn run_save_env(&self, args: Vec<String>) -> Result<(), GrubEnvironmentError> {
        let args = SaveEnvArgs::try_parse_from(args)?;

        if args.variables.is_empty() {
            return Err(GrubEnvironmentError::InvalidArgs);
        }

        let Some(prefix) = self.env.get("prefix") else {
            error!("no prefix environment variable");
            return Err(GrubEnvironmentError::MissingEnvironmentVariable);
        };
        let prefix = PathBuf::from(prefix);
        let file = prefix.join(args.file);

        let existing_env_block_contents = fs::read_to_string(&file)?;

        let mut envs = load_env(existing_env_block_contents, vec![]);

        for var in args.variables {
            if let Some(value) = self.env.get(&var) {
                envs.push((var.to_string(), value.to_string()));
            }
        }

        let Ok(block) = grub_environment_block(envs) else {
            return Err(GrubEnvironmentError::EnvironmentBlock);
        };

        fs::write(file, block)?;

        Ok(())
    }

    fn run_search(&mut self, args: Vec<String>) -> Result<(), GrubEnvironmentError> {
        let args = SearchArgs::try_parse_from(args)?;

        let var = args.set;
        let found = match (args.file, args.fs_uuid, args.label) {
            // search for block device where filepath exists
            (true, false, false) => {
                debug!("searching for block device with file {}", args.name);
                find_disk_partitions(|p| {
                    let Ok(Some(mountpoint)) = mountinfo(p) else {
                        debug!("did not find existing mountpoint");
                        return false;
                    };

                    let mut filepath = PathBuf::from(mountpoint);
                    filepath.push(args.name.strip_prefix('/').unwrap_or(&args.name));

                    filepath.exists()
                })
            }
            // search for block device where filesystem UUID matches
            (false, true, false) => {
                debug!(
                    "searching for block device with filesystem uuid {}",
                    args.name
                );
                find_disk_partitions(|p| match crate::fs::detect_fs_type(p) {
                    Ok(FsType::Ext4(uuid, _)) => uuid == args.name,
                    Ok(FsType::Vfat(uuid, _)) => uuid == args.name,
                    _ => false,
                })
            }
            // search for block device where filesystem label matches
            (false, false, true) => {
                debug!(
                    "searching for block device with filesystem label {}",
                    args.name
                );
                find_disk_partitions(|p| match crate::fs::detect_fs_type(p) {
                    Ok(FsType::Ext4(_, label)) => label == args.name,
                    Ok(FsType::Vfat(_, label)) => label == args.name,
                    _ => false,
                })
            }
            _ => unreachable!("clap parsing failed us"),
        };

        let found = found.map_err(|e| GrubEnvironmentError::Io(e.to_string()))?;
        debug!("grub search command found block devices {:?}", found);

        let Some(found) = found.get(0) else {
            return Err(GrubEnvironmentError::Io("file not found".to_string()));
        };

        if let Ok(Some(mountpoint)) = mountinfo(found) {
            self.env.insert(var, mountpoint);
        } else {
            debug!("did not find existing mountpoint");
        }

        Ok(())
    }

    fn run_set(&mut self, args: Vec<String>) -> Result<(), GrubEnvironmentError> {
        let Some(set) = args.get(1).and_then(|arg| arg.split_once('=')) else {
            return Err(GrubEnvironmentError::InvalidArgs);
        };

        match set {
            (var, "") => self.env.remove(var),
            (var, val) => self.env.insert(var.to_string(), val.to_string()),
        };

        Ok(())
    }

    fn run_test(&self, args: Vec<String>) -> Result<(), GrubEnvironmentError> {
        if args.is_empty() {
            return Err(GrubEnvironmentError::InvalidArgs);
        }

        let args = &args[1..];

        let result = match args.len() {
            0 => return Err(GrubEnvironmentError::InvalidArgs),
            1 => string_nonzero_length(&args[0]),
            2 => match (args[0].as_str(), args[1].as_str()) {
                // file exists and is a directory
                ("-d", file) => file_exists_and_is_directory(file)?,
                // file exists
                ("-e", file) => file_exists(file)?,
                // file exists and is not a directory
                ("-f", file) => file_exists_and_is_not_directory(file)?,
                // file exists and has a size greater than zero
                ("-s", file) => file_exists_and_size_greater_than_zero(file)?,
                // the length of string is nonzero
                ("-n", string) => string_nonzero_length(string),
                // the length of string is zero
                ("-z", string) => string_zero_length(string),
                // expression is false
                ("!", _expression) => todo!("implement 'expression is false'"),
                _ => return Err(GrubEnvironmentError::InvalidArgs),
            },
            3 => match (args[0].as_str(), args[1].as_str(), args[2].as_str()) {
                // the strings are equal
                (string1, "=", string2) | (string1, "==", string2) => {
                    strings_equal(string1, string2)
                }
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
                (integer1, "-eq", integer2) => integers_equal(integer1, integer2)
                    .map_err(|_| GrubEnvironmentError::ParseInt)?,
                // integer1 is greater than or equal to integer2
                (integer1, "-ge", integer2) => {
                    integers_greater_than_or_equal_to(integer1, integer2)
                        .map_err(|_| GrubEnvironmentError::ParseInt)?
                }
                // integer1 is greater than integer2
                (integer1, "-gt", integer2) => integers_greater_than(integer1, integer2)
                    .map_err(|_| GrubEnvironmentError::ParseInt)?,
                // integer1 is less than or equal to integer2
                (integer1, "-le", integer2) => integers_less_than_or_equal_to(integer1, integer2)
                    .map_err(|_| GrubEnvironmentError::ParseInt)?,
                // integer1 is less than integer2
                (integer1, "-lt", integer2) => integers_less_than(integer1, integer2)
                    .map_err(|_| GrubEnvironmentError::ParseInt)?,
                // integer1 is not equal to integer2
                (integer1, "-ne", integer2) => integers_not_equal(integer1, integer2)
                    .map_err(|_| GrubEnvironmentError::ParseInt)?,
                // integer1 is greater than integer2 after stripping off common non-numeric prefix.
                (prefixinteger1, "-pgt", prefixinteger2) => {
                    integers_prefix_greater_than(prefixinteger1, prefixinteger2)
                        .map_err(|_| GrubEnvironmentError::ParseInt)?
                }
                // integer1 is less than integer2 after stripping off common non-numeric prefix.
                (prefixinteger1, "-plt", prefixinteger2) => {
                    integers_prefix_less_than(prefixinteger1, prefixinteger2)
                        .map_err(|_| GrubEnvironmentError::ParseInt)?
                }
                // file1 is newer than file2 (modification time). Optionally numeric bias may be directly appended to -nt in which case it is added to the first file modification time.
                (file1, "-nt", file2) => file_newer_than(file1, file2)?,
                // file1 is older than file2 (modification time). Optionally numeric bias may be directly appended to -ot in which case it is added to the first file modification time.
                (file1, "-ot", file2) => file_older_than(file1, file2)?,
                // both expression1 and expression2 are true
                (_expression1, "-a", _expression2) => {
                    todo!("implement 'both expression1 and expression2 are true'")
                }
                // either expression1 or expression2 is true
                (_expression1, "-o", _expression2) => {
                    todo!("implement 'either expression1 or expression2 is true'")
                }
                // expression is true
                ("(", _expression, ")") => todo!("implement 'expression is true'"),
                _ => {
                    error!("unknown argument pattern {:?}", args);
                    return Err(GrubEnvironmentError::InvalidArgs);
                }
            },
            _ => return Err(GrubEnvironmentError::InvalidArgs),
        };

        match result {
            false => Err(GrubEnvironmentError::False),
            true => Ok(()),
        }
    }
}

impl GrubEnvironment for TinybootGrubEnvironment {
    fn set_env(&mut self, key: String, val: Option<String>) {
        debug!(
            "setting env '{key}' to '{}'",
            val.as_deref().unwrap_or_default()
        );

        if let Some(scope_env) = &mut self.scope {
            if let Some(val) = val {
                scope_env.insert(key, val);
            } else {
                scope_env.remove(&key);
            }
        } else if let Some(val) = val {
            self.env.insert(key, val);
        } else {
            self.env.remove(&key);
        }
    }

    fn get_env(&self, key: &str) -> Option<&String> {
        if let Some(scope_env) = &self.scope {
            scope_env.get(key)
        } else {
            self.env.get(key)
        }
    }

    fn run_command(&mut self, command: String, args_wo_command: Vec<String>) -> u8 {
        // clap requires the command name to be the first argument, just as std::env::args_os().
        let mut args = vec![command.clone()];
        args.extend(args_wo_command);

        let result: Result<(), GrubEnvironmentError> = match command.as_str() {
            "initrd" => self.run_initrd(args),
            "linux" => self.run_linux(args),
            "load_env" => self.run_load_env(args),
            "save_env" => self.run_save_env(args),
            "search" => self.run_search(args),
            "set" => self.run_set(args),
            "test" => self.run_test(args),
            _ => {
                debug!("'{}' not implemented", command);
                Err(GrubEnvironmentError::NotImplemented)
            }
        };

        let exit_code = match result {
            Ok(_) | Err(GrubEnvironmentError::NotImplemented) => 0,
            Err(GrubEnvironmentError::False) => 1,
            Err(e) => {
                error!("command '{command}' error: {e:?}");
                2
            }
        };

        debug!("command '{command}' exited with code {exit_code}");
        exit_code
    }

    fn make_scope(&mut self) {
        self.scope = Some(self.env.clone());
    }

    fn delete_scope(&mut self) {
        self.scope = None;
    }
}

pub struct GrubBootLoader {
    pub timeout: Duration,
    pub entries: Vec<LinuxBootEntry>,
}

impl BootLoader for GrubBootLoader {
    fn timeout(&self) -> std::time::Duration {
        self.timeout
    }

    fn boot_entries(&self) -> Result<Vec<LinuxBootEntry>, Error> {
        Ok(self.entries.to_vec())
    }
}

fn mountinfo_from_source(source: impl Into<String>, dev: impl AsRef<Path>) -> Option<String> {
    for line in source.into().lines() {
        let mut split = line.split_ascii_whitespace();
        _ = split.next();
        _ = split.next();
        _ = split.next();
        _ = split.next();
        let mountpoint = split.next();
        _ = split.next();
        _ = split.next();
        _ = split.next();
        if let Some(device) = split.next() {
            if device == dev.as_ref().to_str().unwrap_or("") {
                if let Some(mountpoint) = mountpoint {
                    return Some(mountpoint.to_string());
                }
            }
        }
    }
    None
}

/// Returns the mountpoint of a device
fn mountinfo(dev: impl AsRef<Path>) -> io::Result<Option<String>> {
    Ok(mountinfo_from_source(
        fs::read_to_string("/proc/self/mountinfo")?,
        dev,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grub_run_test() {
        let g = TinybootGrubEnvironment::new("/dev/null", "/dev/null");
        assert!(g
            .run_test(vec![
                "test".to_string(),
                "-d".to_string(),
                "/dev".to_string()
            ])
            .is_ok(),);
        assert!(
            g.run_test(vec![
                "test".to_string(),
                "-f".to_string(),
                "/dev".to_string()
            ])
            .err()
            .unwrap()
                == GrubEnvironmentError::False,
        );
        assert!(g
            .run_test(vec![
                "test".to_string(),
                "-e".to_string(),
                "/dev".to_string()
            ])
            .is_ok(),);
        assert!(g
            .run_test(vec![
                "test".to_string(),
                "-n".to_string(),
                "foo".to_string()
            ])
            .is_ok(),);
        assert!(
            g.run_test(vec![
                "test".to_string(),
                "-z".to_string(),
                "foo".to_string()
            ])
            .err()
            .unwrap()
                == GrubEnvironmentError::False,
        );
        assert!(g
            .run_test(vec!["test".to_string(), "-z".to_string(), "".to_string()])
            .is_ok(),);
        assert!(g
            .run_test(vec![
                "test".to_string(),
                "foo1".to_string(),
                "-pgt".to_string(),
                "bar0".to_string()
            ])
            .is_ok(),);
    }

    #[test]
    fn grub_environment_block() {
        let testdata_env_block = include_str!("../testdata/grubenv");

        let expected = vec![
            ("foo".to_string(), "bar".to_string()),
            ("bar".to_string(), "baz".to_string()),
        ];

        let block = super::grub_environment_block(expected.clone()).unwrap();
        assert_eq!(block, testdata_env_block);

        let env = super::load_env(testdata_env_block, vec![]);
        assert_eq!(env, expected);
    }

    #[test]
    fn search_args() {
        let args =
            SearchArgs::try_parse_from(vec!["search", "--set=drive1", "--fs-uuid", "BB22-99EC"])
                .unwrap();
        assert_eq!(
            args,
            SearchArgs {
                file: false,
                label: false,
                fs_uuid: true,
                no_floppy: false,
                set: "drive1".to_string(),
                name: "BB22-99EC".to_string(),
            }
        );
    }

    #[test]
    fn mountinfo() {
        let mountinfo_source = r#"1 1 0:2 / / rw - rootfs rootfs rw
11 1 0:10 / /proc rw,relatime - proc proc rw
12 1 0:11 / /sys rw,relatime - sysfs sysfs rw
13 1 0:12 / /tmp rw,relatime - tmpfs tmpfs rw
14 1 0:13 / /dev/pts rw,relatime - devpts devpts rw,mode=600,ptmxmode=000
15 1 254:1 / /mnt/dev-vda1 ro,relatime - ext4 /dev/vda1 ro
"#;

        assert!(
            super::mountinfo_from_source(mountinfo_source, Path::new("/dev/vda1")).unwrap()
                == *"/mnt/dev-vda1"
        );
    }
}

pub fn strings_equal(string1: &str, string2: &str) -> bool {
    string1 == string2
}

pub fn strings_not_equal(string1: &str, string2: &str) -> bool {
    string1 != string2
}

pub fn strings_lexographically_less_than(string1: &str, string2: &str) -> bool {
    string1 < string2
}

pub fn strings_lexographically_less_than_or_equal_to(string1: &str, string2: &str) -> bool {
    string1 <= string2
}

pub fn strings_lexographically_greater_than(string1: &str, string2: &str) -> bool {
    string1 > string2
}

pub fn strings_lexographically_greater_than_or_equal_to(string1: &str, string2: &str) -> bool {
    string1 >= string2
}

type TestParseResult = Result<bool, <i64 as FromStr>::Err>;

pub fn integers_equal(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 == integer2)
}

pub fn integers_greater_than_or_equal_to(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 >= integer2)
}

pub fn integers_greater_than(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 > integer2)
}

pub fn integers_less_than_or_equal_to(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 <= integer2)
}

pub fn integers_less_than(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 < integer2)
}

pub fn integers_not_equal(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 != integer2)
}

pub fn integers_prefix_greater_than(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.trim_start_matches(char::is_alphabetic);
    let integer2 = integer2.trim_start_matches(char::is_alphabetic);
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 > integer2)
}

pub fn integers_prefix_less_than(integer1: &str, integer2: &str) -> TestParseResult {
    let integer1 = integer1.trim_start_matches(char::is_alphabetic);
    let integer2 = integer2.trim_start_matches(char::is_alphabetic);
    let integer1 = integer1.parse::<i64>()?;
    let integer2 = integer2.parse::<i64>()?;
    Ok(integer1 < integer2)
}

type TestIoResult = Result<bool, io::Error>;

pub fn file_exists(file: &str) -> TestIoResult {
    _ = fs::metadata(file)?;
    Ok(true)
}

pub fn file_newer_than(file1: &str, file2: &str) -> TestIoResult {
    let file1_metadata = fs::metadata(file1)?;
    let file2_metadata = fs::metadata(file2)?;
    let file1_modified = file1_metadata.modified()?;
    let file2_modified = file2_metadata.modified()?;
    Ok(file1_modified > file2_modified)
}

pub fn file_older_than(file1: &str, file2: &str) -> TestIoResult {
    let file1_metadata = fs::metadata(file1)?;
    let file2_metadata = fs::metadata(file2)?;
    let file1_modified = file1_metadata.modified()?;
    let file2_modified = file2_metadata.modified()?;
    Ok(file1_modified < file2_modified)
}

pub fn file_exists_and_is_directory(file: &str) -> TestIoResult {
    let metadata = fs::metadata(file)?;
    Ok(metadata.is_dir())
}

pub fn file_exists_and_is_not_directory(file: &str) -> TestIoResult {
    let metadata = fs::metadata(file)?;
    Ok(!metadata.is_dir())
}

pub fn file_exists_and_size_greater_than_zero(file: &str) -> TestIoResult {
    let metadata = fs::metadata(file)?;
    Ok(metadata.len() > 0)
}

pub fn string_nonzero_length(string: &str) -> bool {
    !string.is_empty()
}

pub fn string_zero_length(string: &str) -> bool {
    string.is_empty()
}