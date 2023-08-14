use tboot::block_device::BlockDevice;

/// InternalMsg is a message that is only used internally.
#[derive(Clone, Debug)]
pub enum InternalMsg {
    Device(BlockDevice),
    Tick,
}
