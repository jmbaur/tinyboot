{ testers, writeText }:

testers.runNixOSTest {
  name = "simple";
  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      virtualisation = {
        # The bios option wants a package with a bios.bin file in it.
        bios = pkgs.runCommand "tinyboot-bios.bin" { } ''
          install -D ${pkgs."tinyboot-qemu-${pkgs.stdenv.hostPlatform.qemuArch}"} $out/bios.bin
        '';
        qemu.options = lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [ "-machine q35" ];
        qemu.drives = [
          {
            file = "fat:rw:$ESP";
            driveExtraOpts = {
              "if" = "virtio";
              format = "raw";
            };
          }
        ];
      };
    };
  testScript =
    { nodes, ... }:
    let
      bootEntry = writeText "boot-entry" ''
        title simple
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
      shutil.copyfile("${bootEntry}", os.path.join(esp.name, "loader/entries/simple.conf"))

      machine.wait_for_unit("multi-user.target")
    '';
}
