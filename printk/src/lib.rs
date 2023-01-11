use log::{LevelFilter, Log, Metadata, Record, SetLoggerError};
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::sync::Mutex;
use std::{error, fmt};

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

        let mut buf = Vec::new();
        writeln!(
            buf,
            "{}[{}]: {}",
            self.prefix,
            record.level(),
            record.args()
        )
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

impl fmt::Display for PrintkInitError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            PrintkInitError::Io(err) => err.fmt(f),
            PrintkInitError::Log(err) => err.fmt(f),
        }
    }
}

impl error::Error for PrintkInitError {
    fn source(&self) -> Option<&(dyn error::Error + 'static)> {
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
