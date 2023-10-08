use tboot::block_device::BlockDevice;

use crate::cmd::Command;

/// InternalMsg is a message that is only used internally.
#[derive(Clone, Debug)]
pub enum InternalMsg {
    Command(Command),
    Device(BlockDevice),
    Tick,
    UserIsPresent,
}
