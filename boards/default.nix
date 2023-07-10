{ pkgs, lib }: lib.mapAttrs
  (board: _: lib.makeOverridable
    ({ config ? { } }:
    lib.evalModules {
      modules = [
        ({ inherit board; })
        (import ../options.nix { _pkgs = pkgs; _lib = lib; })
        config
      ];
    })
  { })
  (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./.))
