{ pkgs, ... }: {
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "nodev";
  boot.loader.grub.extraInstallCommands = ''
    find /boot/kernels -type f \
      -exec ${pkgs.tinyboot}/bin/tbootctl verified-boot sign --verbose --private-key ${./keys/privkey} --file {} \;
  '';
}
