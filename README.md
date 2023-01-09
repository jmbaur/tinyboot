# tinyboot

tinyboot is a kexec bootloader. The nix flake provides an initramfs derivation
that can be used to create a LinuxBoot implementation. The initramfs uses a
statically-built busybox along with busybox's `/init` to launch tinyboot and
find boot configurations to kexec into. Current boot configuration types
include syslinux/extlinux & grub (coming soon!).
