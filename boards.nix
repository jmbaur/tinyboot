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
            inherit board;
            _module.args.pkgs = pkgs;
          })
          ./options.nix
          config
        ];
      }).config.build.firmware
    ) { }
  )
) (builtins.readDir ./boards)
