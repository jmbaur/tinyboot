use std::path::Path;

mod bindings {
    #![allow(non_upper_case_globals)]
    #![allow(non_camel_case_types)]
    #![allow(non_snake_case)]

    include!(concat!(env!("OUT_DIR"), "/bindings.rs"));
}

pub fn measure_initrd(initrd: &Path) -> anyhow::Result<()> {
    let digest = sha256::try_digest(initrd)?;

    let error =
        (unsafe { std::ffi::CStr::from_ptr(bindings::pcr_extend(digest.as_ptr())) }).to_str()?;

    if !error.is_empty() {
        anyhow::bail!(error);
    }

    Ok(())
}
