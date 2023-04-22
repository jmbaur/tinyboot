use std::{env, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=src/tpm.c");
    println!("cargo:rerun-if-changed=wrapper.h");

    cc::Build::new()
        .file("src/tpm.c")
        .include("wolftpm")
        .compile("tpm");

    let bindings = bindgen::Builder::default()
        .header("wrapper.h")
        .parse_callbacks(Box::new(bindgen::CargoCallbacks))
        .allowlist_function("pcr_extend")
        .generate()
        .expect("Unable to generate bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write bindings!");

    println!("cargo:rustc-link-lib=static=wolftpm");
    println!("cargo:rustc-link-lib=static=wolfssl");
}
