{ linkFarm, fetchzip }:

linkFarm "zig-packages" [
  {
    name = "1220ff14a53e9a54311c9b0e665afeda2c82cfd6f57e7e1b90768bf13b85f9f29cd0";
    path = fetchzip {
      url = "https://github.com/Hejsil/zig-clap/archive/068c38f89814079635692c7d0be9f58508c86173.tar.gz";
      hash = "sha256-ZUrJfjiNcK21Cq9Gm3vYVGrkk1tUyfVhrqIGZ1fz2m4=";
    };
  }
]
