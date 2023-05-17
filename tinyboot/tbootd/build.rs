use std::{env, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=wrapper.h");

    let mut builder = bindgen::Builder::default();

    if let Ok(nix_cflags) = env::var("NIX_CFLAGS_COMPILE") {
        builder = builder.clang_args(nix_cflags.split(' '));
    }

    let bindings = builder
        .header("wrapper.h")
        .parse_callbacks(Box::new(bindgen::CargoCallbacks))
        .allowlist_function("TPM2_GetRCString")
        .allowlist_function("TPM2_PCR_Extend")
        .allowlist_function("TPM2_PCR_Reset")
        .allowlist_function("wolfTPM2_Cleanup")
        .allowlist_function("wolfTPM2_Init")
        .allowlist_type("PCR_Extend_In")
        .allowlist_type("PCR_Reset_In")
        .allowlist_type("TPM_ALG_ID_T")
        .allowlist_type("TPM_RC_T")
        .allowlist_type("WOLFTPM2_DEV")
        .allowlist_var("TPM_SHA256_DIGEST_SIZE")
        .generate()
        .expect("Unable to generate bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());

    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write bindings!");

    println!("cargo:rustc-link-lib=wolftpm");
    println!("cargo:rustc-link-lib=wolfssl");
}
