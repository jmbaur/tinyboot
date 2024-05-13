# tinyboot

tinyboot is a `kexec`-based bootloader

## Hacking

Make a directory (e.g. `/tmp/tboot`) and fill it with [Boot Loader Spec](https://uapi-group.org/specifications/specs/boot_loader_specification/#the-boot-loader-specification) compatible files.

```
zig build run -- -drive if=virtio,format=raw,file=fat:rw:/tmp/tboot
```
