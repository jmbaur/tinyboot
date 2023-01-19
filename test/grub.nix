{
  boot.loader = {
    grub = {
      enable = true;
      device = "nodev";
      efiInstallAsRemovable = true;
      copyKernels = true;
      efiSupport = true;
    };
    efi.canTouchEfiVariables = false;
  };
}
