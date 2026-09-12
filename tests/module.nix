{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.tinybootTest;

  tinybootKernel = pkgs.callPackage ./kernel.nix { };

  stub = "${pkgs.tinyboot}/efi/tboot-efi-stub.efi";
  kernel = "${tinybootKernel}/${config.system.boot.loader.kernelFile}";
  initrd = "${pkgs.tinyboot}/${pkgs.tinyboot.initrdFile}";

  # The UKI describes tinyboot, not the NixOS system that tinyboot goes on to
  # boot.
  osRelease = pkgs.writeText "tinyboot-os-release" ''
    ID=tinyboot
    NAME=tinyboot
    PRETTY_NAME="tinyboot ${pkgs.tinyboot.version}"
    VERSION_ID=${pkgs.tinyboot.version}
  '';

  # A unified kernel image containing the tinyboot EFI stub, kernel, and
  # initrd. This is what firmware without an embedded tinyboot (e.g. UEFI
  # firmware) would load in order to boot tinyboot.
  uki = pkgs.runCommand "tboot-efi-stub-uki.efi" { } ''
    ${pkgs.buildPackages.systemdUkify}/lib/systemd/ukify build \
      --stub=${stub} \
      --linux=${kernel} \
      --initrd=${initrd} \
      --os-release=@${osRelease} \
      --output=$out
  '';

  # An EFI system partition holding the unified kernel image at the removable
  # media path, so that the UEFI firmware boots it without needing any EFI
  # variables to be set.
  esp =
    pkgs.runCommand "tboot-efi-stub-esp.img"
      {
        nativeBuildInputs = with pkgs.buildPackages; [
          dosfstools
          mtools
        ];
      }
      ''
        truncate -s $(( $(stat -Lc %s ${uki}) + 16 * 1024 * 1024 )) $out
        mkfs.vfat -n TBOOT $out
        mmd -i $out ::/EFI ::/EFI/BOOT
        mcopy -i $out ${uki} ::/EFI/BOOT/BOOT${lib.toUpper pkgs.stdenv.hostPlatform.efiArch}.EFI
      '';
in
{
  imports = [ ../nixos ];

  options.tinybootTest.useEfiStub = lib.mkEnableOption ''
    booting tinyboot as a UEFI application via tboot-efi-stub, instead of
    having qemu load the tinyboot kernel and initrd directly
  '';

  config = {
    boot.kernelPackages = pkgs.linuxPackages_7_2;

    system.switch.enable = true;

    boot.loader.tinyboot.enable = true;

    # can't use this cause this doesn't let us customize our kernel
    virtualisation.directBoot.enable = false;

    system.build = {
      inherit tinybootKernel;
      tbootEfiStubUki = uki;
      tbootEfiStubEsp = esp;
    };
    virtualisation.graphics = false;
    virtualisation.tpm.enable = true;
    # TODO(jared): remove this once we have https://github.com/NixOS/nixpkgs/pull/562501
    virtualisation.tpm.deviceModel = lib.mkIf pkgs.stdenv.hostPlatform.isArmv7 "tpm-tis-device";

    # Boot tinyboot through UEFI firmware instead of pretending that the
    # platform's firmware already contains it.
    virtualisation.useEFIBoot = lib.mkIf cfg.useEfiStub true;

    virtualisation.qemu.options =
      if cfg.useEfiStub then
        [ "-drive file=${esp},format=raw,readonly=on,if=virtio" ]
      else
        [
          "-kernel ${kernel}"
          "-initrd ${initrd}"
        ];
  };
}
