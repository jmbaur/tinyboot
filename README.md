# tinyboot

tinyboot is a linuxboot-like kexec bootloader for coreboot. Current boot
configuration support includes grub, syslinux/extlinux, and
[bls](https://uapi-group.org/specifications/specs/boot_loader_specification/).
The nix flake provides coreboot builds for a few boards, contributions for more
configs are welcome!

## Usage

```bash
nix build github:jmbaur/tinyboot#coreboot.<your_board>
flashrom -w ./result/coreboot.rom -p <your_programmer>
```

## Hacking

```bash
nix run .#disk
nix run .#default
```
