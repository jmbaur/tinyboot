# generated by zon2nix (https://github.com/nix-community/zon2nix)

{ linkFarm, fetchzip }:

linkFarm "zig-packages" [
  {
    name = "1220bbea0285a5d555320b00dde5ced378254c8be144d155d8f886ab4a4e9a855881";
    path = fetchzip {
      url = "https://github.com/r4gus/zbor/archive/refs/tags/0.12.3.tar.gz";
      hash = "sha256-q5UerAa9fvhCWv4wKUGUmdmEX9CGmxgQcE6VMB3QMhU=";
    };
  }
]
