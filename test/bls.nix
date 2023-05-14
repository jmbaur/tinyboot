{ pkgs, ... }: {
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.extraInstallCommands = ''
    openssl=${pkgs.openssl}/bin/openssl
    tmp=$(mktemp -d)
    mkdir -p $tmp/boot/EFI/nixos
    find /boot/EFI/nixos -type f -name "*.efi" \
      -exec sh -c "$openssl dgst -binary -sha256 {} > $tmp/{}.hash && $openssl pkeyutl -sign -inkey ${./keys/privkey} -out {}.sig -rawin -in $tmp/{}.hash" \;
    rm -r $tmp
  '';
}
