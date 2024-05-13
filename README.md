# tinyboot

## Description

[`Tinyboot`](https://github.com/jmbaur/tinyboot) is a
[`LinuxBoot`](https://www.linuxboot.org/) `kexec` bootloader for
[`coreboot`](https://www.coreboot.org/). Boot configuration is done with the
[Boot Loader
Specification](https://uapi-group.org/specifications/specs/boot_loader_specification/).

The `nix` flake provides `coreboot` builds for a few boards. Contributions for
more configs are welcome!

## Usage

```bash
nix build github:jmbaur/tinyboot#tinyboot-<your_board>
# write ./result to your board (e.g. with flashrom)
```

## Hacking

```
zig build run
```
