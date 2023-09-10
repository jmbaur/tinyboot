pkgs:
let
  inherit (pkgs) lib;
in
lib.mapAttrs
  (board: _: lib.makeOverridable
    ({ config ? { } }:
    lib.evalModules {
      modules = [
        ({ _module.args = { inherit pkgs lib; }; })
        ./options.nix
        ({ inherit board; })
        config
      ];
    })
  { })
  (builtins.readDir ./boards)
