{
  testers,
  buildPackages,
  runCommand,
}:

let
  tbootKeys =
    runCommand "tboot-keys"
      {
        nativeBuildInputs = [ buildPackages.tinyboot ];
      }
      ''
        tboot-keygen -n evilcorpkeys -o evilcorp -c US -s 000000 -t 0
        mkdir -p $out && mv *der *.pem $out
      '';
in
testers.runNixOSTest {
  name = "disk";
  defaults.imports = [ ../module.nix ];
  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:

    {
      virtualisation.fileSystems."/boot" = {
        device = "/dev/vda1";
        fsType = "vfat";
      };

      virtualisation.qemu.options = [
        "-fw_cfg name=opt/org.tboot/pubkey,file=${tbootKeys}/tboot-certificate.der"
      ];

      specialisation.hello.configuration.environment.systemPackages = [ pkgs.hello ];

      boot.loader.tinyboot.verifiedBoot = {
        enable = true;
        # NOTE: These are just test fixtures, actually using private keys that
        # get copied to the nix store is not secure!
        privateKey = "${tbootKeys}/tboot-private.pem";
        certificate = "${tbootKeys}/tboot-certificate.der";
      };

      system.build.diskImage = import "${pkgs.path}/nixos/lib/make-disk-image.nix" {
        inherit config lib pkgs;
        label = "nixos";
        partitionTableType = "efi";
        format = "raw";
        bootSize = "128M";
        additionalSpace = "0M";
        copyChannel = false;
      };
    };
  testScript =
    { nodes, ... }:
    ''
      import os
      import shutil
      import subprocess
      import tempfile

      for file in ["tboot-private.pem", "tboot-public.pem", "tboot-certificate.pem"]:
          with open(f"${tbootKeys}/{file}") as f:
              print(f"using {file}:\n{f.read()}")

      tmp_disk_image = tempfile.NamedTemporaryFile()
      shutil.copyfile("${nodes.machine.system.build.diskImage}/nixos.img", tmp_disk_image.name)
      subprocess.run([
        "${nodes.machine.virtualisation.qemu.package}/bin/qemu-img",
        "resize",
        "-f",
        "raw",
        tmp_disk_image.name,
        "+32M",
      ])

      # Set NIX_DISK_IMAGE so that the qemu script finds the right disk image.
      os.environ['NIX_DISK_IMAGE'] = tmp_disk_image.name

      machine.wait_for_unit("boot-complete.target")
      assert "active" == machine.succeed("systemctl is-active tboot-bless-boot.service").strip()
      machine.succeed("test -e /boot/loader/entries/nixos-generation-1.conf")
      machine.fail("hello")

      first_boot_pcrs = [machine.succeed(f"cat /sys/class/tpm/tpm0/pcr-sha256/{pcr}").strip() for pcr in range(0, 24)]

      machine.succeed("sed -i 's/nixos-generation-1/nixos-generation-1-specialisation-hello/' /boot/loader/loader.conf")
      machine.shutdown()
      machine.wait_for_shutdown()

      machine.wait_for_unit("boot-complete.target")
      assert "active" == machine.succeed("systemctl is-active tboot-bless-boot.service").strip()
      machine.succeed("test -e /boot/loader/entries/nixos-generation-1-specialisation-hello.conf")
      print(machine.succeed("hello"))

      second_boot_pcrs = [machine.succeed(f"cat /sys/class/tpm/tpm0/pcr-sha256/{pcr}").strip() for pcr in range(0, 24)]

      # PCR7, PCR8, and PCR9 should be the same
      for pcr in [7, 8, 9]:
          if first_boot_pcrs[pcr] != second_boot_pcrs[pcr]:
              raise AssertionError(f"PCR{pcr} should be equal")

      # PCR12 should _not_ be the same
      for pcr in [12]:
          if first_boot_pcrs[pcr] == second_boot_pcrs[pcr]:
              raise AssertionError(f"PCR{pcr} should not be equal")
    '';
}
