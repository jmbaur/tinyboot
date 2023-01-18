# tinyboot

tinyboot is a kexec bootloader. The nix flake provides an initramfs derivation
that can be used to create a LinuxBoot implementation. The initramfs uses a
statically-built busybox along with busybox's `/init` to launch tinyboot and
find boot configurations to kexec into. Current boot configuration types include
syslinux/extlinux & grub.

## Usage

### Coreboot

1. Build the initramfs and kernel.

   ```bash
   nix build --output /tmp/initramfs github:jmbaur/tinyboot#initramfs
   nix build --output /tmp/kernel github:jmbaur/tinyboot#kernel
   ```

1. Include the output paths into your coreboot build. Note that the kernel
   filename is different for different architectures (for example x86_64 is
   `bzImage`).

   ```
   # ...
   CONFIG_PAYLOAD_LINUX=y
   CONFIG_PAYLOAD_FILE="/tmp/kernel/bzImage"
   CONFIG_LINUX_INITRD="/tmp/initramfs/initrd"
   ```
