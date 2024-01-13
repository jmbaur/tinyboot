use std::ffi::{c_char, c_void, CString};

use base64::{engine::general_purpose, Engine as _};
use log::{debug, warn};
use nix::libc;
use syscalls::{syscall, Sysno};

// We are using the "_ima" keyring and not the ".ima" keyring since we do not use
// CONFIG_INTEGRITY_TRUSTED_KEYRING=y in our kernel config.
const IMA_KEYRING_NAME: &str = "_ima";

enum KeySerial {
    UserKeyring,
}

impl Into<i32> for KeySerial {
    fn into(self) -> i32 {
        match self {
            KeySerial::UserKeyring => libc::KEY_SPEC_USER_KEYRING,
        }
    }
}

// https://git.kernel.org/pub/scm/linux/kernel/git/dhowells/keyutils.git/tree/keyctl.c#n705
fn add_keyring(name: &str, key_serial: KeySerial) -> anyhow::Result<i32> {
    let key_type = CString::new("keyring")?;

    let key_desc = CString::new(name)?;

    let key_serial: i32 = key_serial.into();

    let keyring_id = unsafe {
        syscall!(
            Sysno::add_key,
            key_type.as_ptr(),
            key_desc.as_ptr(),
            std::ptr::null() as *const c_void,
            0,
            key_serial
        )?
    };

    Ok(keyring_id.try_into()?)
}

fn add_key(keyring_id: i32, key_content: &[u8]) -> anyhow::Result<i32> {
    let key_type = CString::new("asymmetric")?;

    let key_desc: *const c_char = std::ptr::null();

    // see https://github.com/torvalds/linux/blob/59f3fd30af355dc893e6df9ccb43ace0b9033faa/security/keys/keyctl.c#L74
    let key_id = unsafe {
        syscall!(
            Sysno::add_key,
            key_type.as_ptr(),
            key_desc,
            key_content.as_ptr() as *const c_void,
            key_content.len(),
            keyring_id
        )?
    };

    Ok(key_id.try_into()?)
}

// https://github.com/torvalds/linux/blob/3b517966c5616ac011081153482a5ba0e91b17ff/security/integrity/digsig.c#L193
pub fn load_verification_key() -> anyhow::Result<()> {
    let Some(pubkey) = ('pubkey: {
        if cfg!(feature = "fw_cfg") {
            debug!("searching for keys from qemu fw_cfg");

            // https://qemu-project.gitlab.io/qemu/specs/fw_cfg.html
            match std::fs::read("/sys/firmware/qemu_fw_cfg/by_name/opt/org.tboot/pubkey/raw") {
                Ok(raw) => break 'pubkey Some(raw),
                Err(e) => warn!("failed to get key from fw_cfg: {}", e),
            }
        }

        if cfg!(feature = "coreboot") {
            debug!("searching for keys from coreboot vpd");

            // The public key is held in VPD as a base64 encoded string.
            // https://github.com/torvalds/linux/blob/master/drivers/firmware/google/vpd.c#L193
            match std::fs::read("/sys/firmware/vpd/ro/pubkey")
                .map(|bytes| general_purpose::STANDARD.decode(bytes))
            {
                Ok(Ok(raw)) => break 'pubkey Some(raw),
                Ok(Err(e)) => warn!("failed to decode public key: {}", e),
                Err(e) => warn!("failed to get key from RO_VPD: {}", e),
            }
        }

        None
    }) else {
        anyhow::bail!("no public key found");
    };

    if pubkey == include_bytes!("../../test/keys/tboot/key.der") {
        warn!("test keys are in use");
    }

    let ima_keyring_id = add_keyring(IMA_KEYRING_NAME, KeySerial::UserKeyring)?;

    let key_id = add_key(ima_keyring_id, &pubkey)?;

    debug!("added ima key with id: {:?}", key_id);

    Ok(())
}
