{ nixosTest, lib, tinyboot-initramfs, ... }:
nixosTest {
  name = "tinyboot";
  nodes.machine = {
    virtualisation.qemu.options = lib.mkAfter [
      "-initrd ${tinyboot-initramfs}"
      "-append \"console=ttyS0\""
    ];
  };
  testScript = ''
    machine.start()
    machine.wait_for_console_text("tinyboot started")
    machine.succeed("mount -t devtmpfs | grep --silent \/dev")
    machine.succeed("mount -t tmpfs | grep --silent \/tmp")
    machine.succeed("mount -t sysfs | grep --silent \/sys")
    machine.succeed("mount -t proc | grep --silent \/proc")
  '';
}
