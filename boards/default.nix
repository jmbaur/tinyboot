{ pkgs, lib }: lib.mapAttrs
  (board: _: lib.makeOverridable
    ({ config ? { } }:
    let
      finalConfig = lib.evalModules {
        modules = [
          ({ inherit board; })
          (import ../options.nix { _pkgs = pkgs; _lib = lib; })
          config
        ];
      };
    in
    finalConfig.config.build.firmware)
  { })
  (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./.))
