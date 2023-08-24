use std::{io, path::Path};

pub const TBOOTD_LOG_FILE: &str = "/run/tbootd.log";
pub const TBOOTUI_LOG_FILE: &str = "/run/tbootui.log";

#[derive(thiserror::Error, Debug)]
pub enum LogError {
    #[error("failed to setup logging")]
    FailedSetup,
    #[error("failed to open log file")]
    LogFileFailed,
}

pub fn setup_logging(
    level: log::LevelFilter,
    log_file: Option<impl AsRef<Path>>,
) -> Result<(), LogError> {
    let mut dispatch = fern::Dispatch::new()
        .format(|out, message, record| {
            out.finish(format_args!(
                "[{}][{}] {}",
                record.target(),
                record.level(),
                message
            ))
        })
        .level(level);

    if let Some(file) = log_file {
        dispatch = dispatch.chain(fern::log_file(file).map_err(|_| LogError::LogFileFailed)?);
    } else {
        dispatch = dispatch.chain(io::stderr());
    }

    dispatch.apply().map_err(|_| LogError::FailedSetup)
}
