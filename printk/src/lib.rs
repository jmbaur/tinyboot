use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::sync::Mutex;

use log::{Level, LevelFilter, Log, Metadata, Record, SetLoggerError};

/// Kernel logger implementation
pub struct Printk {
    prefix: String,
    kmsg: Mutex<File>,
    maxlevel: LevelFilter,
}

impl Printk {
    pub fn new(prefix: &str, filter: LevelFilter) -> io::Result<Printk> {
        Ok(Printk {
            prefix: prefix.to_string(),
            kmsg: Mutex::new(OpenOptions::new().write(true).open("/dev/kmsg")?),
            maxlevel: filter,
        })
    }
}

impl Log for Printk {
    fn enabled(&self, meta: &Metadata) -> bool {
        meta.level() <= self.maxlevel
    }

    fn log(&self, record: &Record) {
        if record.level() > self.maxlevel {
            return;
        }

        let level: u8 = match record.level() {
            Level::Error => 3,
            Level::Warn => 4,
            Level::Info => 5,
            Level::Debug => 6,
            Level::Trace => 7,
        };

        let mut buf = Vec::new();
        writeln!(buf, "{}[{}]: {}", self.prefix, level, record.args())
            .expect("failed to write log message");

        if let Ok(mut kmsg) = self.kmsg.lock() {
            let _ = kmsg.write(&buf);
            let _ = kmsg.flush();
        }
    }

    fn flush(&self) {}
}

#[derive(Debug)]
pub enum PrintkInitError {
    Io(io::Error),
    Log(SetLoggerError),
}

impl std::fmt::Display for PrintkInitError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            PrintkInitError::Io(err) => err.fmt(f),
            PrintkInitError::Log(err) => err.fmt(f),
        }
    }
}

impl std::error::Error for PrintkInitError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            PrintkInitError::Io(err) => Some(err),
            PrintkInitError::Log(err) => Some(err),
        }
    }
}

impl From<SetLoggerError> for PrintkInitError {
    fn from(err: SetLoggerError) -> Self {
        PrintkInitError::Log(err)
    }
}
impl From<io::Error> for PrintkInitError {
    fn from(err: io::Error) -> Self {
        PrintkInitError::Io(err)
    }
}

pub fn init(prefix: &str, filter: LevelFilter) -> Result<(), PrintkInitError> {
    let klog = Printk::new(prefix, filter)?;
    let maxlevel = klog.maxlevel;
    log::set_boxed_logger(Box::new(klog))?;
    log::set_max_level(maxlevel);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn log_to_kernel() {
        init("test", LevelFilter::Debug).unwrap();
        log::debug!("hello, world!");
    }
}
