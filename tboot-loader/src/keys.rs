use std::ffi::{c_char, c_void, CString};

use log::{info, warn};
use syscalls::{syscall, Sysno};

// https://github.com/torvalds/linux/blob/3b517966c5616ac011081153482a5ba0e91b17ff/security/integrity/digsig.c#L193
pub fn load_x509_key() -> anyhow::Result<()> {
    let Some(pubkey) = ('pubkey: {
        if cfg!(fw_cfg) {
            // https://qemu-project.gitlab.io/qemu/specs/fw_cfg.html
            match std::fs::read("/sys/firmware/qemu_fw_cfg/by_name/opt/org.tboot/pubkey/raw") {
                Ok(raw) => break 'pubkey Some(raw),
                Err(e) => {
                    warn!("failed to get key from fw_cfg: {}", e);
                }
            }
        }

        std::fs::read("/etc/keys/x509_ima.der").ok()
    }) else {
        anyhow::bail!("no public key found");
    };

    let all_keys = std::fs::read_to_string("/proc/keys")?;
    let all_keys = parse_proc_keys(&all_keys);
    let ima_keyring_id = all_keys
        .into_iter()
        .find_map(|(key_id, key_type, keyring)| {
            if key_type != "keyring" {
                return None;
            }

            if keyring != ".ima" {
                return None;
            }

            Some(key_id)
        });

    let Some(ima_keyring_id) = ima_keyring_id else {
        anyhow::bail!(".ima keyring not found");
    };

    let key_type = CString::new("asymmetric")?;
    let key_desc: *const c_char = std::ptr::null();

    // see https://github.com/torvalds/linux/blob/59f3fd30af355dc893e6df9ccb43ace0b9033faa/security/keys/keyctl.c#L74
    let key_id = unsafe {
        syscall!(
            Sysno::add_key,
            key_type.as_ptr(),
            key_desc,
            pubkey.as_ptr() as *const c_void,
            pubkey.len(),
            ima_keyring_id
        )?
    };

    info!("added ima key with id: {:?}", key_id);

    // only install the IMA policy after we have loaded the key
    std::fs::copy("/etc/ima/policy.conf", "/sys/kernel/security/ima/policy")?;

    Ok(())
}

// columns:
// keyring_id . . . . . . . keyring_name .
fn parse_proc_keys(contents: &str) -> Vec<(i32, &str, &str)> {
    contents
        .lines()
        .filter_map(|key| {
            let mut iter = key.split_ascii_whitespace();
            let Some(key_id) = iter.next() else {
                return None;
            };

            let Ok(key_id) = i32::from_str_radix(key_id, 16) else {
                return None;
            };

            // skip the next 7 columns
            for _ in 0..6 {
                _ = iter.next();
            }

            let Some(key_type) = iter.next() else {
                return None;
            };

            let Some(keyring) = iter.next().and_then(|keyring| keyring.strip_suffix(":")) else {
                return None;
            };

            Some((key_id, key_type, keyring))
        })
        .collect()
}

#[cfg(test)]
mod tests {

    #[test]
    fn parse_proc_keys() {
        let proc_keys = r#"
3b7511b0 I--Q---     1 perm 0b0b0000     0     0 user      invocation_id: 16
"#;
        assert_eq!(
            super::parse_proc_keys(proc_keys),
            vec![(997527984, "user", "invocation_id")]
        );
    }
}
