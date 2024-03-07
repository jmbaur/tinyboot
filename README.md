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

```
nix run github:jmbaur/tinyboot#coreboot-<your_board>.config.build.installScript
```

## Hacking

```
zig build run
```
