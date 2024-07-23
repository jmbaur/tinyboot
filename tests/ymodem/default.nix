{
  lib,
  lrzsz,
  testers,
  tinybootTools,
}:

testers.runNixOSTest {
  name = "ymodem";
  extraBaseModules.imports = [ ../module.nix ];
  nodes.machine = { };
  skipTypeCheck = true; # TODO(jared): delete this
  testScript =
    { nodes, ... }:
    ''
      import os
      import re
      import shutil
      import subprocess
      import tempfile
      import time

      host_boot_dir = tempfile.TemporaryDirectory()

      linux = os.path.join(host_boot_dir.name, "linux")
      initrd = os.path.join(host_boot_dir.name, "initrd")
      params = os.path.join(host_boot_dir.name, "params")

      shutil.copyfile("${nodes.machine.system.build.kernel}/${nodes.machine.system.boot.loader.kernelFile}", linux)
      shutil.copyfile("${nodes.machine.system.build.initialRamdisk}/${nodes.machine.system.boot.loader.initrdFile}", initrd)
      with open(params, "x") as f:
          f.write("init=${nodes.machine.system.build.toplevel}/init ${toString nodes.machine.boot.kernelParams}")

      def tboot_ymodem(pty):
          subprocess.run(["${lib.getExe' tinybootTools "tboot-ymodem"}", "send", "--tty", pty, "--dir", host_boot_dir.name])

      def lrzsz(pty):
          subprocess.run(f"${lib.getExe' lrzsz "sx"} --ymodem --1k --binary {linux} {initrd} {params} > {pty} < {pty}", shell=True)

      for fn in [tboot_ymodem, lrzsz]:
          machine.start()
          chardev = machine.send_monitor_command("chardev-add pty,id=ymodem")
          machine.send_monitor_command("device_add virtconsole,chardev=ymodem")
          machine.wait_for_console_text("press ENTER to interrupt")
          machine.send_console("\n")  # interrupt boot process
          time.sleep(1)
          machine.send_console("list\n")
          machine.send_console("select 229:1\n")  # /dev/hvc1 has major:minor of 229:1
          time.sleep(1)
          machine.send_console("probe\n")

          pty = re.findall(r"/dev/pts/[0-9]+", chardev)[0]
          print(f"using pty {pty}")
          fn(pty)

          machine.send_console("boot\n")
          machine.wait_for_unit("multi-user.target")
          machine.shutdown()
          machine.wait_for_shutdown()
    '';
}
