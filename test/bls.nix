{ pkgs, ... }: {
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.extraInstallCommands = ''
    find /boot/EFI/nixos -type f -name "*.efi" \
      -exec ${pkgs.tinyboot-client}/bin/tbootctl verified-boot sign --verbose --private-key ${./keys/privkey} --file {} \;
  '';
}
