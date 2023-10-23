use std::path::{Path, PathBuf};

use argh::FromArgs;

#[derive(FromArgs, Debug)]
/// Install nixos boot loader files
struct Args {
    /// the sign-file executable to use (built with the linux kernel)
    #[argh(option)]
    sign_file: PathBuf,

    /// the private key to use when signing boot files
    #[argh(option)]
    private_key: PathBuf,

    /// the public key to use when signing boot files
    #[argh(option)]
    public_key: PathBuf,

    /// the mount point of the ESP
    #[argh(option)]
    efi_sys_mount_point: PathBuf,

    /// the nixos system closure of the current activation
    #[argh(positional)]
    default_nixos_system_closure: PathBuf,
}

fn main() {
    let args: Args = argh::from_env();

    std::fs::create_dir_all(args.efi_sys_mount_point.join("loader/entries")).unwrap();
    std::fs::create_dir_all(args.efi_sys_mount_point.join("EFI/nixos")).unwrap();

    let profiles_dir = std::fs::read_dir("/nix/var/nix/profiles").unwrap();
    for entry in profiles_dir {
        let entry = entry.unwrap();

        if !entry.metadata().unwrap().is_symlink() {
            continue;
        }

        if !entry
            .path()
            .file_name()
            .unwrap()
            .to_str()
            .unwrap()
            .starts_with("system-")
        {
            continue;
        }

        let entry_number = u32::from_str_radix(
            entry
                .path()
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .trim_start_matches("system-")
                .trim_end_matches("-link"),
            10,
        )
        .unwrap();

        let nixos_system_closure = std::fs::canonicalize(entry.path()).unwrap();
        let boot_json = bootspec::BootJson::synthesize_latest(&nixos_system_closure).unwrap();

        if nixos_system_closure == args.default_nixos_system_closure {
            std::fs::write(
                args.efi_sys_mount_point.join("loader/loader.conf"),
                format!("default nixos-generation-{}\n", entry_number),
            )
            .unwrap();
        }

        match boot_json.generation {
            bootspec::generation::Generation::V1(generation) => {
                let mut entry_contents = String::from("title NixOS");

                entry_contents.push('\n');

                let version = generation.bootspec.label;

                entry_contents.push_str(&format!("version {}", version));

                entry_contents.push('\n');

                let linux = Path::new("EFI/nixos").join(format!(
                    "{}-{}",
                    generation
                        .bootspec
                        .kernel
                        .parent()
                        .unwrap()
                        .file_name()
                        .unwrap()
                        .to_str()
                        .unwrap(),
                    generation
                        .bootspec
                        .kernel
                        .file_name()
                        .unwrap()
                        .to_str()
                        .unwrap()
                ));

                entry_contents
                    .push_str(&format!("linux {}", Path::new("/").join(&linux).display()));

                std::fs::copy(
                    generation.bootspec.kernel,
                    args.efi_sys_mount_point.join(&linux),
                )
                .unwrap();
                std::process::Command::new(&args.sign_file)
                    .args([
                        "sha256",
                        args.private_key.to_str().unwrap(),
                        args.public_key.to_str().unwrap(),
                        args.efi_sys_mount_point.join(&linux).to_str().unwrap(),
                    ])
                    .spawn()
                    .unwrap()
                    .wait()
                    .unwrap();

                entry_contents.push('\n');

                let initrd = generation.bootspec.initrd.as_ref().map(|initrd| {
                    Path::new("EFI/nixos").join(format!(
                        "{}-{}",
                        initrd
                            .parent()
                            .unwrap()
                            .file_name()
                            .unwrap()
                            .to_str()
                            .unwrap(),
                        initrd.file_name().unwrap().to_str().unwrap()
                    ))
                });

                if let Some(initrd) = initrd {
                    std::fs::copy(
                        generation.bootspec.initrd.as_ref().unwrap(),
                        args.efi_sys_mount_point.join(&initrd),
                    )
                    .unwrap();
                    std::process::Command::new(&args.sign_file)
                        .args([
                            "sha256",
                            args.private_key.to_str().unwrap(),
                            args.public_key.to_str().unwrap(),
                            args.efi_sys_mount_point.join(&initrd).to_str().unwrap(),
                        ])
                        .spawn()
                        .unwrap()
                        .wait()
                        .unwrap();
                    entry_contents.push_str(&format!(
                        "initrd {}",
                        Path::new("/").join(&initrd).display()
                    ));
                }

                entry_contents.push('\n');

                entry_contents.push_str(&format!(
                    "options init={} {}",
                    generation.bootspec.init.display(),
                    generation.bootspec.kernel_params.join(" ")
                ));

                entry_contents.push('\n');

                match std::fs::read_to_string("/etc/machine-id") {
                    Ok(machine_id) => {
                        entry_contents.push_str(&format!("machine-id {}", machine_id.trim()));
                    }
                    Err(_) => {}
                }

                entry_contents.push('\n');

                std::fs::write(
                    args.efi_sys_mount_point
                        .join("loader")
                        .join("entries")
                        .join(format!("nixos-generation-{}.conf", entry_number)),
                    entry_contents,
                )
                .unwrap();
            }
            _ => {}
        }
    }
}
