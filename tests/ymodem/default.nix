{
  testers,
  lib,
  lrzsz,
}:

testers.runNixOSTest {
  name = "ymodem";
  extraBaseModules.imports = [ ../module.nix ];
  nodes.machine = { };
  testScript =
    { nodes, ... }:
    ''
      import os
      import shutil
      import tempfile
      import subprocess

      host_boot_dir = tempfile.TemporaryDirectory()

      linux = os.path.join(host_boot_dir.name, "linux")
      initrd = os.path.join(host_boot_dir.name, "initrd")
      params = os.path.join(host_boot_dir.name, "params")

      shutil.copyfile("${nodes.machine.system.build.kernel}/${nodes.machine.system.boot.loader.kernelFile}", linux)
      shutil.copyfile("${nodes.machine.system.build.initialRamdisk}/${nodes.machine.system.boot.loader.initrdFile}", initrd)
      with open(params, "x") as f:
          f.write("init=${nodes.machine.system.build.toplevel}/init ${toString nodes.machine.boot.kernelParams}")

      machine.start()
      machine.wait_for_console_text("press ENTER to interrupt")
      machine.send_console("\n")  # interrupt boot process
      machine.send_console("list\n")  # show boot loaders
      machine.send_console("select 1\n")  # show boot loaders
      machine.send_console("probe\n")  # show boot loaders

      assert machine.process is not None
      subprocess.run(["${lib.getExe' lrzsz "sx"}", "--ymodem", "-kb", linux, initrd, params], stdin=machine.process.stdin, stdout=machine.process.stdin)

      machine.wait_for_unit("multi-user.target")
    '';
}
