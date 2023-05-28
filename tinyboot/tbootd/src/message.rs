use crate::block_device::BlockDevice;
use termion::event::Key;

pub enum Msg {
    Key(Key),
    Device(BlockDevice),
    Tick,
}
