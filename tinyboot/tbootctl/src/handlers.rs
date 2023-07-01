use futures::{SinkExt, StreamExt};
use tboot::message::{Request, Response};

pub(crate) async fn handle_reboot() -> Result<(), anyhow::Error> {
    let (mut sink, mut stream) = tboot::message::get_client_codec(None).await?;
    sink.send(Request::Reboot).await?;
    if matches!(stream.next().await, Some(Ok(Response::ServerDone))) {
        Ok(())
    } else {
        Err(anyhow::anyhow!("could not poweroff"))
    }
}

pub(crate) async fn handle_poweroff() -> Result<(), anyhow::Error> {
    let (mut sink, mut stream) = tboot::message::get_client_codec(None).await?;
    sink.send(Request::Poweroff).await?;
    if matches!(stream.next().await, Some(Ok(Response::ServerDone))) {
        Ok(())
    } else {
        Err(anyhow::anyhow!("could not poweroff"))
    }
}
