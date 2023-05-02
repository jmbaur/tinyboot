# tinyboot

tinyboot is a linuxboot-like kexec bootloader for coreboot. Current boot
configuration support includes syslinux/extlinux & grub. The nix flake provides
coreboot builds for a few boards, contributions for more configs are welcome!

## Usage

```bash
nix build github:jmbaur/tinyboot#coreboot.<your_board>
flashrom -w ./result/coreboot.rom -p <your_programmer>
```

## Hacking

Get started with qemu:

```bash
nix build github:jmbaur/tinyboot#coreboot.qemu-x86_64
qemu-system-x86_64 -nographic -bios ./result/coreboot.rom
```
