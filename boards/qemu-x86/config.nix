{ ... }: {
  platforms = [ "x86_64-linux" ];
  coreboot.configFile = ./coreboot.config;
  tinyboot = {
    debug = true;
    tty = "ttyS0";
  };
}
