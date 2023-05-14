{ pkgs, ... }: {
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.extraInstallCommands = ''
    find /boot/EFI/nixos -type f -name "*.efi" \
      -exec sh -c "${pkgs.openssl}/bin/openssl pkeyutl -sign -inkey ${./keys/privkey} -out {}.sig -rawin -in {}" \;
  '';
}
