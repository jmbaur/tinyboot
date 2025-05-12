# zig build && \
#   ukify build --stub ./zig-out/efi/tboot-efi-stub.efi --kernel ./result/bzImage --initrd ./result/tboot-loader.cpio.zst --output uki.efi && \
#   uefi-run --boot uki.efi -- -m 2G -display none -serial mon:stdio
{
  hostPlatform = "x86_64-linux";
  platform.qemu = true;
  debug = true;
  efi = true;
  linux.consoles = [ "ttyS0,115200n8" ];
}
