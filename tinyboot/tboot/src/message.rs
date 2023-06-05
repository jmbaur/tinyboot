use crate::{block_device::BlockDevice, linux::LinuxBootEntry};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio_serde_cbor::Codec;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ListBootEntriesRequest {
    pub foo: u8,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ListBootEntriesResponse {
    entries: Vec<(u8, String)>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum Request {
    Boot(LinuxBootEntry),
    Ping,
    Poweroff,
    Reboot,
    UserIsPresent,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum Response {
    Pong,
    NewDevice(BlockDevice),
    TimeLeft(Duration),
    VerifiedBootFailure,
    ServerDone,
}

pub type ClientCodec = Codec<Response, Request>;
pub type ServerCodec = Codec<Request, Response>;
