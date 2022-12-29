{ nixosTest, lib, tinyboot-initramfs, ... }:
nixosTest {
  name = "tinyboot";
  nodes.machine = {
    virtualisation.qemu.options = lib.mkAfter [
      "-initrd ${tinyboot-initramfs}"
      "-append \"console=ttyS0 init=/init\""
    ];
  };
  testScript = ''
    machine.start()
    machine.wait_for_console_text("Hello, world!")
  '';
}
