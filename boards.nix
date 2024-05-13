{ pkgs, lib }:
lib.mapAttrs' (
  board: _:
  lib.nameValuePair "tinyboot-${board}" (
    lib.makeOverridable (
      {
        config ? { },
      }:
      (lib.evalModules {
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
      }).config.build.firmware
    ) { }
  )
) (builtins.readDir ./boards)
