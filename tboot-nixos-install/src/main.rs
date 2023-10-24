use std::{
    collections::HashMap,
    path::{Path, PathBuf},
};

use argh::FromArgs;

#[derive(FromArgs, Debug, Default)]
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

#[derive(Default)]
struct State {
    args: Args,
    known_efi_files: HashMap<PathBuf, ()>,
    known_entry_files: HashMap<PathBuf, ()>,
}

fn install_generation(
    state: &mut State,
    entry_number: u32,
    generation: &bootspec::v1::GenerationV1,
    specialisation: Option<&bootspec::SpecialisationName>,
) {
    let mut entry_contents = format!(
        "title NixOS{}",
        specialisation
            .map(|specialisation| format!(" ({})", specialisation))
            .unwrap_or_default()
    );

    entry_contents.push('\n');

    let version = &generation.bootspec.label;

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

    entry_contents.push_str(&format!("linux {}", Path::new("/").join(&linux).display()));

    std::fs::copy(
        &generation.bootspec.kernel,
        state.args.efi_sys_mount_point.join(&linux),
    )
    .unwrap();
    state
        .known_efi_files
        .insert(state.args.efi_sys_mount_point.join(&linux), ());

    std::process::Command::new(&state.args.sign_file)
        .args([
            "sha256",
            state.args.private_key.to_str().unwrap(),
            state.args.public_key.to_str().unwrap(),
            state
                .args
                .efi_sys_mount_point
                .join(&linux)
                .to_str()
                .unwrap(),
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
            state.args.efi_sys_mount_point.join(&initrd),
        )
        .unwrap();
        state
            .known_efi_files
            .insert(state.args.efi_sys_mount_point.join(&initrd), ());

        std::process::Command::new(&state.args.sign_file)
            .args([
                "sha256",
                state.args.private_key.to_str().unwrap(),
                state.args.public_key.to_str().unwrap(),
                state
                    .args
                    .efi_sys_mount_point
                    .join(&initrd)
                    .to_str()
                    .unwrap(),
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

    let entry_path = state
        .args
        .efi_sys_mount_point
        .join("loader")
        .join("entries")
        .join(format!(
            "nixos-generation-{}{}.conf",
            entry_number,
            specialisation
                .map(|specialisation| format!("-specialisation-{specialisation}"))
                .unwrap_or_default()
        ));
    std::fs::write(&entry_path, entry_contents).unwrap();

    state.known_entry_files.insert(entry_path, ());
}

fn main() {
    let args: Args = argh::from_env();

    std::fs::create_dir_all(args.efi_sys_mount_point.join("loader/entries")).unwrap();
    std::fs::create_dir_all(args.efi_sys_mount_point.join("EFI/nixos")).unwrap();

    let mut state = State::default();
    state.args = args;

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

        if nixos_system_closure == state.args.default_nixos_system_closure {
            std::fs::write(
                state.args.efi_sys_mount_point.join("loader/loader.conf"),
                format!("default nixos-generation-{}\n", entry_number),
            )
            .unwrap();
        }

        match boot_json.generation {
            bootspec::generation::Generation::V1(generation) => {
                generation
                    .specialisations
                    .iter()
                    .for_each(|(specialisation, generation)| {
                        install_generation(
                            &mut state,
                            entry_number,
                            generation,
                            Some(specialisation),
                        )
                    });

                install_generation(&mut state, entry_number, &generation, None);
            }
            _ => {}
        }
    }

    let efi_nixos_dir =
        std::fs::read_dir(state.args.efi_sys_mount_point.join("EFI/nixos")).unwrap();
    for file in efi_nixos_dir {
        let file_path = file.as_ref().unwrap().path();

        if state.known_efi_files.get(&file_path).is_none()
            && file.as_ref().unwrap().metadata().unwrap().is_file()
        {
            std::fs::remove_file(&file_path).unwrap();
        }
    }

    let entry_dir =
        std::fs::read_dir(state.args.efi_sys_mount_point.join("loader/entries")).unwrap();
    for file in entry_dir {
        let file_path = file.as_ref().unwrap().path();

        if state.known_entry_files.get(&file_path).is_none()
            && file.as_ref().unwrap().metadata().unwrap().is_file()
        {
            std::fs::remove_file(&file_path).unwrap();
        }
    }
}
