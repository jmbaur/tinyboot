use std::path::Path;

mod bindings {
    #![allow(clippy::all)]
    #![allow(non_camel_case_types)]
    #![allow(non_snake_case)]
    #![allow(non_upper_case_globals)]
    #![allow(unused)]
    include!(concat!(env!("OUT_DIR"), "/bindings.rs"));
}

pub const TPM_VERIFIED_PCR: u32 = 7;
pub const TPM_CMDLINE_PCR: u32 = 8;
pub const TPM_INITRD_PCR: u32 = 9;
pub const TPM_KERNEL_PCR: u32 = 11;

fn get_rc_string(rc: i32) -> String {
    (unsafe { std::ffi::CStr::from_ptr(bindings::TPM2_GetRCString(rc)) })
        .to_str()
        .expect("bad rc string")
        .to_string()
}

fn bail_on_non_success(msg: &str, rc: i32) -> anyhow::Result<()> {
    if rc != bindings::TPM_RC_T_TPM_RC_SUCCESS {
        anyhow::bail!("{msg}: {}", get_rc_string(rc));
    }

    Ok(())
}

pub fn measure_boot(
    verified: (bool, &[u8]),
    kernel: (impl AsRef<Path>, &[u8]),
    initrd: (impl AsRef<Path>, &[u8]),
    cmdline: (impl AsRef<str>, &[u8]),
) -> anyhow::Result<()> {
    let mut dev: std::mem::MaybeUninit<bindings::WOLFTPM2_DEV> = std::mem::MaybeUninit::uninit();

    bail_on_non_success("wolfTPM2_Init", unsafe {
        bindings::wolfTPM2_Init(dev.as_mut_ptr(), None, std::ptr::null_mut())
    })?;

    let mut dev = unsafe { dev.assume_init() };

    let mut digests = Vec::from([
        (TPM_KERNEL_PCR, kernel.1),
        (TPM_INITRD_PCR, initrd.1),
        (TPM_CMDLINE_PCR, cmdline.1),
    ]);

    if verified.0 {
        digests.push((TPM_VERIFIED_PCR, verified.1));
    }

    for (pcr, digest) in digests {
        let mut pcr_extend = unsafe { std::mem::zeroed::<bindings::PCR_Extend_In>() };
        pcr_extend.pcrHandle = pcr;
        pcr_extend.digests.count = 1;
        pcr_extend.digests.digests[0].hashAlg =
            u16::try_from(bindings::TPM_ALG_ID_T_TPM_ALG_SHA256)
                .expect("constant value fits into u16");

        let mut digest_bytes = [0u8; 64];
        if digest.len() != digest_bytes.len() {
            anyhow::bail!("invalid sha256 length")
        }

        digest
            .iter()
            .zip(digest_bytes.iter_mut())
            .for_each(|(b, ptr)| *ptr = *b);
        pcr_extend.digests.digests[0].digest.H = digest_bytes;

        bail_on_non_success("TPM2_PCR_Extend", unsafe {
            bindings::TPM2_PCR_Extend(&mut pcr_extend)
        })?;
    }

    bail_on_non_success("wolfTPM2_Cleanup", unsafe {
        bindings::wolfTPM2_Cleanup(&mut dev)
    })?;

    Ok(())
}
