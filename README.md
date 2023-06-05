# tinyboot

Tinyboot is a linuxboot kexec bootloader for coreboot. Current boot
configuration support includes
[bls](https://uapi-group.org/specifications/specs/boot_loader_specification/),
grub, and syslinux/extlinux. The nix flake provides coreboot builds for a few
boards, contributions for more configs are welcome!

## Usage

```
nix build github:jmbaur/tinyboot#coreboot.<your_board>
flashrom -w ./result/coreboot.rom -p <your_programmer>
```

## Hacking

```
nix run .#disk
nix run .#default
```
