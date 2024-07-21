{ testers }:

testers.runNixOSTest {
  name = "disk";
  extraBaseModules.imports = [ ../module.nix ];
  nodes.machine = {
    virtualisation.fileSystems."/boot" = {
      device = "/dev/disk/by-label/QEMU\\x20VVFAT";
      fsType = "vfat";
    };
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
    ''
      import os
      import shutil
      import tempfile

      def populate_esp(tmpdir, title, linux, initrd, params, tries_left=None, tries_done=None):
          os.makedirs(os.path.join(tmpdir, "loader/entries"))

          entry_name = title
          if tries_left is not None:
              entry_name = entry_name + f"+{tries_left}"
          if tries_done is not None:
              entry_name = entry_name + f"-{tries_done}"
          entry_name = entry_name + ".conf"

          with open(os.path.join(tmpdir, "loader/entries", entry_name), "x") as entry:
              entry.write(f"title {title}\n")
              shutil.copyfile(linux, os.path.join(tmpdir, "linux"))
              entry.write("linux /linux\n")
              shutil.copyfile(initrd, os.path.join(tmpdir, "initrd"))
              entry.write("initrd /initrd\n")
              entry.write(f"options {params}\n")

      with subtest("simple"):
          with tempfile.TemporaryDirectory() as esp:
              os.environ["ESP"] = esp
              populate_esp(
                  esp,
                  "foo",
                  "${nodes.machine.system.build.kernel}/${nodes.machine.system.boot.loader.kernelFile}",
                  "${nodes.machine.system.build.initialRamdisk}/${nodes.machine.system.boot.loader.initrdFile}",
                  "init=${nodes.machine.system.build.toplevel}/init ${toString nodes.machine.boot.kernelParams}",
              )
              machine.wait_for_unit("multi-user.target")

      machine.shutdown()
      machine.wait_for_shutdown()

      with subtest("boot-counting"):
          with tempfile.TemporaryDirectory() as esp:
              os.environ["ESP"] = esp
              populate_esp(
                  esp,
                  "foo",
                  "${nodes.machine.system.build.kernel}/${nodes.machine.system.boot.loader.kernelFile}",
                  "${nodes.machine.system.build.initialRamdisk}/${nodes.machine.system.boot.loader.initrdFile}",
                  "init=${nodes.machine.system.build.toplevel}/init ${toString nodes.machine.boot.kernelParams}",
                  tries_left=3,
                  tries_done=0,
              )
              machine.wait_for_unit("multi-user.target")
              machine.succeed("test -e /boot/loader/entries/foo+2-1.conf")
    '';
}
