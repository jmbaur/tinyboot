{
  description = "A small '/init' for linuxboot";
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
          tinyboot-initramfs = prev.callPackage ./initramfs.nix {
            inherit (final) tinyboot;
          };
        })
      ];
      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          inherit (pkgs.tinyboot) CARGO_BUILD_TARGET CARGO_BUILD_RUSTFLAGS;
          buildInputs = [ pkgs.tinyboot.toolchain ];
        };
      });
      packages = forAllSystems ({ pkgs, ... }: {
        default = pkgs.tinyboot;
        initramfs = pkgs.tinyboot-initramfs;
      });
    };
}
