# tinyboot

tinyboot is a kexec-based bootloader

## Hacking

Make a directory (e.g. `/tmp/tboot`) and fill it with [Boot Loader Spec](https://uapi-group.org/specifications/specs/boot_loader_specification/#the-boot-loader-specification) compatible files.

```bash
nix develop
zig build run -- -drive if=virtio,format=raw,file=fat:rw:/tmp/tboot
```

## Kernel Configuration

The Linux kernel used by tinyboot can be as big or as small as you like, though in many environments (e.g. firmware on SPI flash) the amount of space is quite small, so it is often in your best interest to minimize the size of the kernel. A good starting place, if you are starting from scratch, is the `tinyconfig` kernel defconfig.
After that, there are a set of kernel options required by tinyboot, listed [here](./doc/required.config). For more information, see [the documentation](./doc/kernel-configuration.md).
