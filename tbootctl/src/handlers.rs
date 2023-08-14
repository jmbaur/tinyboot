use futures::{SinkExt, StreamExt};
use tboot::message::{ClientMessage, ServerMessage};

pub(crate) async fn handle_reboot() -> Result<(), anyhow::Error> {
    let (mut sink, mut stream) = tboot::message::get_client_codec(None).await?;
    sink.send(ClientMessage::Reboot).await?;
    if matches!(stream.next().await, Some(Ok(ServerMessage::ServerDone))) {
        Ok(())
    } else {
        Err(anyhow::anyhow!("could not poweroff"))
    }
}

pub(crate) async fn handle_poweroff() -> Result<(), anyhow::Error> {
    let (mut sink, mut stream) = tboot::message::get_client_codec(None).await?;
    sink.send(ClientMessage::Poweroff).await?;
    if matches!(stream.next().await, Some(Ok(ServerMessage::ServerDone))) {
        Ok(())
    } else {
        Err(anyhow::anyhow!("could not poweroff"))
    }
}
