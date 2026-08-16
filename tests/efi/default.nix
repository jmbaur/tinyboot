{ testers }:

testers.runNixOSTest {
  name = "disk";
  defaults.imports = [ ../module.nix ];
  nodes.machine =
    { config, pkgs, ... }:
    {
      virtualisation.useEFIBoot = true;

      system.build.tinybootDisk = pkgs.callPackage (
        {
          dosfstools,
          mtools,
          runCommand,
          stdenv,
          systemdUkify,
          tinyboot,
          qemu,
        }:
        runCommand "tinyboot.fat"
          {
            nativeBuildInputs = [
              dosfstools
              mtools
              systemdUkify
              tinyboot
              qemu
            ];
          }
          ''
            qemu-system-aarch64 -nographic -M virt,dumpdtb=out.dtb -cpu cortex-a53
            ukify build \
              --output=tinyboot.efi \
              --os-release="" \
              --efi-arch=${stdenv.hostPlatform.efiArch} \
              --uname=${config.system.build.tinybootKernel.modDirVersion} \
              --stub=${tinyboot}/efi/tboot-efi-stub.efi \
              --linux=${config.system.build.tinybootKernel}/${config.system.boot.loader.kernelFile} \
              --devicetree=out.dtb \
              --initrd=${pkgs.tinyboot}/${pkgs.tinyboot.initrdFile}
            truncate -s 64M $out
            mkfs.vfat -F32 -nTINYBOOT $out
            mmd -i $out "::efi"
            mmd -i $out "::efi/boot"
            mcopy -pvm -i $out tinyboot.efi "::efi/boot/boot${pkgs.stdenv.hostPlatform.efiArch}.efi"
          ''
      ) { };
    };
  testScript = ''
    #
  '';
}
