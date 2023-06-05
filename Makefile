# TODO(jared): DON'T USE THIS, it is just an experimental way to have a quicker
# feedback loop while developing and is not done
# things to do to get this working:
# - nix shell with static musl toolchain so the CPIO does not need any shared libraries
# - nix derivations of the kernel, base initrd w/busybox utils, and base coreboot ROM

src := $(shell git ls-files --directory tinyboot)

.PHONY := default run clean

default: run

run: out/tinyboot-coreboot.rom
	# bash test/test.bash out/tinyboot-coreboot.rom
	echo run!

clean:
	rm -rf out

out/tinyboot-coreboot.rom: $(src) out out/initrd out/kernel out/tinyboot.cpio out/coreboot.rom
	echo concatentate tinyboot cpio to out/initrd
	echo use cbfs to create out/tinyboot-coreboot.rom

out/tinyboot.cpio: out/bin
	cargo build --manifest-path tinyboot/Cargo.toml
	cd out && find ./bin | cpio -ov > tinyboot.cpio

out/bin:
	cargo build --manifest-path tinyboot/Cargo.toml
	mkdir -p out/bin
	cp tinyboot/target/debug/{tbootd,tbootui,tbootctl} out/bin/

out/coreboot.rom:
	dd if=$(shell nix build --no-link --print-out-paths -L .\#coreboot.qemu-x86_64)/coreboot.rom of=out/coreboot.rom

out/initrd:
	echo initrd

out/kernel:
	echo kernel

out:
	mkdir -p out
