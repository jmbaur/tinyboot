{ testers, writeText }:

testers.runNixOSTest {
  name = "disk";
  extraBaseModules.imports = [ ../module.nix ];
  nodes.machine = {
    virtualisation.qemu.drives = [
      {
        file = "fat:rw:$ESP";
        driveExtraOpts = {
          "if" = "virtio";
          format = "raw";
        };
      }
    ];
  };
  testScript =
    { nodes, ... }:
    let
      bootEntry = writeText "boot-entry" ''
        title foo
        linux /linux
        initrd /initrd
        options init=${nodes.machine.system.build.toplevel}/init ${toString nodes.machine.boot.kernelParams}
      '';
    in
    ''
      import os
      import shutil
      import tempfile

      esp = tempfile.TemporaryDirectory()
      os.environ["ESP"] = esp.name

      os.makedirs(os.path.join(esp.name, "loader/entries"))
      shutil.copyfile("${nodes.machine.system.build.kernel}/${nodes.machine.system.boot.loader.kernelFile}", os.path.join(esp.name, "linux"))
      shutil.copyfile("${nodes.machine.system.build.initialRamdisk}/${nodes.machine.system.boot.loader.initrdFile}", os.path.join(esp.name, "initrd"))
      shutil.copyfile("${bootEntry}", os.path.join(esp.name, "loader/entries/foo.conf"))

      machine.wait_for_unit("multi-user.target")
    '';
}
