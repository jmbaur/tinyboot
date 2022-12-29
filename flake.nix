{
  description = "A small '/init' for linuxboot";
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
  };
  outputs = inputs: with inputs;
    let
      forAllSystems = f: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: f {
        inherit system;
        pkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
      });
    in
    {
      overlays.default = final: prev: {
        tinyboot = prev.callPackage ./. { };
        tinyboot-initramfs = prev.callPackage ./initramfs.nix {
          inherit (final) tinyboot;
        };
      };
      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          buildInputs = with pkgs; [ rustc cargo ];
        };
      });
      packages = forAllSystems ({ pkgs, ... }: {
        default = pkgs.tinyboot;
        initramfs = pkgs.tinyboot-initramfs;
        test = pkgs.callPackage ./test.nix { };
      });
    };
}
