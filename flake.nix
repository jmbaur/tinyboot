{
  description = "A small initramfs for linuxboot";
  inputs = {
    crane.inputs.nixpkgs.follows = "nixpkgs";
    crane.url = "github:ipetkov/crane";
    nixpkgs.url = "nixpkgs/nixos-unstable";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };
  outputs = inputs: with inputs;
    let
      forAllSystems = f: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: f {
        inherit system;
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
      });
    in
    {
      overlays.default = nixpkgs.lib.composeManyExtensions [
        rust-overlay.overlays.default
        (final: prev: {
          tinyboot = prev.callPackage ./. { inherit crane; };
          tinyboot-initramfs = prev.callPackage ./initramfs.nix { inherit (final) tinyboot; };
        })
      ];
      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell ({
          inputsFrom = [ pkgs.tinyboot ];
          nativeBuildInputs = [ pkgs.cargo-watch ];
        } // pkgs.tinyboot.env);
      });
      packages = forAllSystems ({ pkgs, ... }: {
        default = pkgs.tinyboot;
        initramfs = pkgs.tinyboot-initramfs;
      });
      apps = forAllSystems ({ pkgs, system, ... }: {
        default = {
          type = "app";
          program =
            let
              console = if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then "ttyAMA0" else "ttyS0";
              initrd = pkgs.tinyboot-initramfs.override { tty = console; };
            in
            toString (pkgs.substituteAll {
              src = ./run.bash;
              isExecutable = true;
              path = [ pkgs.zstd pkgs.qemu ];
              qemu = "${pkgs.qemu}/bin/qemu-system-${pkgs.stdenv.hostPlatform.qemuArch}";
              inherit (pkgs) bash;
              inherit console;
              kernel = "${pkgs.linuxPackages_latest.kernel}/${pkgs.stdenv.hostPlatform.linux-kernel.target}";
              initrd = "${initrd}/initrd";
              drive = toString (
                (nixpkgs.lib.nixosSystem {
                  inherit system;
                  modules = [
                    ({ modulesPath, ... }: {
                      imports = [
                        (if system == "aarch64-linux" then
                          "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
                        else if system == "x86_64-linux" then
                          "${modulesPath}/installer/sd-card/sd-image-x86_64.nix"
                        else throw "unsupported system")
                      ];
                      system.stateVersion = "23.05";
                    })
                  ];
                }).config.system.build.sdImage
              );
            });
        };
      });
    };
}
