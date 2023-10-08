use crate::{block_device::BlockDevice, linux::LinuxBootEntry};
use std::time::Duration;

#[derive(Clone, Debug, PartialEq)]
pub enum ClientMessage {
    Boot(LinuxBootEntry),
    Poweroff,
    Reboot,
    UserIsPresent,
    ListBlockDevices,
    StartStreaming,
    StopStreaming,
}

#[derive(Clone, Debug)]
pub enum ServerError {
    ValidationFailed,
    Unknown,
}

#[derive(Clone, Debug)]
pub enum ServerMessage {
    NewDevice(BlockDevice),
    TimeLeft(Option<Duration>),
    VerifiedBootFailure,
    ServerDone,
    ListBlockDevices(Vec<BlockDevice>),
    ServerError(ServerError),
}
