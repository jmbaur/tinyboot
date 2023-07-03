use crate::{block_device::BlockDevice, linux::LinuxBootEntry};
use futures::{
    stream::{SplitSink, SplitStream},
    StreamExt,
};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio::{io, net::UnixStream};
use tokio_serde_cbor::Codec;
use tokio_util::codec::{Decoder, Framed};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ListBootEntriesRequest {
    pub foo: u8,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ListBootEntriesResponse {
    entries: Vec<(u8, String)>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum ClientMessage {
    Boot(LinuxBootEntry),
    Ping,
    Poweroff,
    Reboot,
    UserIsPresent,
    ListBlockDevices,
    StartStreaming,
    StopStreaming,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum ServerError {
    ValidationFailed,
    Unknown,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum ServerMessage {
    Pong,
    NewDevice(BlockDevice),
    TimeLeft(Option<Duration>),
    VerifiedBootFailure,
    ServerDone,
    ListBlockDevices(Vec<BlockDevice>),
    ServerError(ServerError),
}

pub type ClientCodec = Codec<ServerMessage, ClientMessage>;
pub type ServerCodec = Codec<ClientMessage, ServerMessage>;

pub async fn get_client_codec(
    unix_stream: Option<UnixStream>,
) -> io::Result<(
    SplitSink<Framed<UnixStream, ClientCodec>, ClientMessage>,
    SplitStream<Framed<UnixStream, ClientCodec>>,
)> {
    let stream = if let Some(stream) = unix_stream {
        stream
    } else {
        UnixStream::connect(crate::TINYBOOT_SOCKET).await?
    };
    let codec: ClientCodec = Codec::new();
    Ok(codec.framed(stream).split())
}
