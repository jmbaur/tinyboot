{ pkgs, lib }:
lib.mapAttrs' (
  board: _:
  lib.nameValuePair "coreboot-${board}" (
    lib.makeOverridable (
      {
        config ? { },
      }:
      lib.evalModules {
        modules = [
          ({
            _module.args = {
              inherit pkgs board;
            };
          })
          ./options.nix
          ./boards/${board}/config.nix
          config
        ];
      }
    ) { }
  )
) (builtins.readDir ./boards)
