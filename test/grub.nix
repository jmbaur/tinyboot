{ pkgs, ... }: {
  boot.loader = {
    grub = {
      enable = true;
      device = "nodev";
      extraInstallCommands = ''
        find /boot/kernels -type f \
          -exec sh -c "${pkgs.openssl}/bin/openssl pkeyutl -sign -inkey ${./keys/privkey} -out {}.sig -rawin -in {}" \;
      '';
    };
    efi.canTouchEfiVariables = false;
  };
}
