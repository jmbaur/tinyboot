# tinyboot

Tinyboot is a linuxboot kexec bootloader for coreboot. Boot configuration is
done with the [Boot Loader Specification]
(https://uapi-group.org/specifications/specs/boot_loader_specification/). The
nix flake provides coreboot builds for a few boards, contributions for more
configs are welcome!

## Usage

```
nix run github:jmbaur/tinyboot#coreboot.<your_board>.config.build.installScript
```

## Hacking

```
just qemu
```
