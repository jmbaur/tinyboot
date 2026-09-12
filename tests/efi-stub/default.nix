{
  testers,
  tinyboot,
}:

testers.runNixOSTest {
  name = "efi-stub";
  defaults.imports = [ ../module.nix ];
  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      # Boot tinyboot as a UEFI application with tboot-efi-stub instead of
      # having qemu load the tinyboot kernel and initrd for us.
      tinybootTest.useEfiStub = true;

      # The tboot-efi-stub ESP shows up as an additional virtio disk, so don't
      # depend on the enumeration order of the disks.
      virtualisation.fileSystems."/boot" = {
        device = "/dev/disk/by-label/ESP";
        fsType = "vfat";
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
      os.environ['NIX_DISK_IMAGE'] = tmp_disk_image.name

      machine.start()
      machine.wait_for_console_text("tinyboot ${tinyboot.version}")
      machine.wait_for_unit("boot-complete.target")
      assert "active" == machine.succeed("systemctl is-active tboot-bless-boot.service").strip()
      machine.succeed("test -e /boot/loader/entries/nixos-generation-1.conf")
    '';
}
