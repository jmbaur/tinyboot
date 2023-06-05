use crate::{block_device::BlockDevice, linux::LinuxBootEntry};
use futures::prelude::*;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio_serde_cbor::Codec;
use tokio_util::codec::Decoder;

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

pub fn ser_request(r: &Request) -> Result<Vec<u8>, serde_cbor::Error> {
    serde_cbor::ser::to_vec(r)
}

pub fn de_request<'a>(slice: &'a [u8]) -> Result<Request, serde_cbor::Error> {
    serde_cbor::de::from_slice::<'a, Request>(slice)
}

pub type ClientCodec = Codec<Response, Request>;
pub type ServerCodec = Codec<Request, Response>;

pub async fn test() {
    let receiver_listener = tokio::net::UnixListener::bind("/tmp/tinyboot.sock").unwrap();
    let client_socket = tokio::net::UnixStream::connect("/tmp/tinyboot.sock")
        .await
        .unwrap();
    let server_socket = receiver_listener.accept().await.unwrap().0;
    let client_codec: ClientCodec = Codec::new();
    let server_codec: ServerCodec = Codec::new();
    let (mut client_sink, mut client_stream) = client_codec.framed(client_socket).split();
    let (mut server_sink, mut server_stream) = server_codec.framed(server_socket).split();

    client_sink.send(Request::Ping).await.unwrap();
    client_sink.flush().await.unwrap();
    let req = server_stream.next().await.unwrap().unwrap();
    eprintln!("REQ: {:?}", req);
    client_sink.send(Request::Ping).await.unwrap();
    client_sink.flush().await.unwrap();
    let req = server_stream.next().await.unwrap().unwrap();
    eprintln!("REQ: {:?}", req);
    match req {
        Request::Ping => {
            server_sink.send(Response::Pong).await.unwrap();
            server_sink.flush().await.unwrap();
        }
        _ => todo!(),
    }

    let res = client_stream.next().await.unwrap().unwrap();
    eprintln!("RES: {:?}", res);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serde() {
        let req = ser_request(&Request::Ping).unwrap();
        assert_eq!(de_request(&req).unwrap(), Request::Ping);
    }

    #[tokio::test]
    async fn test() {
        super::test().await;
    }
}
