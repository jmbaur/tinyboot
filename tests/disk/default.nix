{
  testers,
}:

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

      # virtualisation.qemu.options = [ "-fw_cfg name=opt/org.tboot/pubkey,file=$TBOOT_CERT_DER" ];
      # virtualisation.qemu.drives = [
      #   {
      #     file = "fat:rw:$ESP";
      #     driveExtraOpts = {
      #       "if" = "virtio";
      #       format = "raw";
      #     };
      #   }
      # ];

      specialisation.hello.configuration = {
        environment.systemPackages = [ pkgs.hello ];
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

      machine.succeed("sed -i 's/nixos-generation-1/nixos-generation-1-specialisation-hello/' /boot/loader/loader.conf")
      machine.shutdown()
      machine.wait_for_shutdown()

      machine.wait_for_unit("boot-complete.target")
      assert "active" == machine.succeed("systemctl is-active tboot-bless-boot.service").strip()
      machine.succeed("test -e /boot/loader/entries/nixos-generation-1-specialisation-hello.conf")
      print(machine.succeed("hello"))
    '';
}
