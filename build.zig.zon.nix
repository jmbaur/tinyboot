{ linkFarm, fetchzip }:

linkFarm "zig-packages" [
  {
    name = "12204387e122dd8b6828847165a7153c5d624b0a77217fd907c7f4f718ecce36e217";
    path = fetchzip {
      url = "https://github.com/Hejsil/zig-clap/archive/e47028deaefc2fb396d3d9e9f7bd776ae0b2a43a.tar.gz";
      hash = "sha256-leXnA97ITdvmBhD2YESLBZAKjBg+G4R/+PPPRslz/ec=";
    };
  }
]
