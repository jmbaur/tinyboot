{
  boot.loader = {
    grub = {
      enable = true;
      device = "nodev";
    };
    efi.canTouchEfiVariables = false;
  };
}
