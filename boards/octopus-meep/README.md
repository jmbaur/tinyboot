```console
$ flashrom -p internal --wp-list
flashrom 1.4.0-devel on Linux 5.15.133-20572-g7d16b3026dcc (x86_64)
flashrom is free software, get the source code at https://flashrom.org

Using clock_gettime for delay loops (clk_id: 1, resolution: 1ns).
coreboot table found at 0x79b2a000.
Found chipset "Intel Gemini Lake".
This chipset is marked as untested. If you are using an up-to-date version
of flashrom *and* were (not) able to successfully update your firmware with it,
then please email a report to flashrom@flashrom.org including a verbose (-V) log.
Thank you!
Enabling flash write... FREG0: Flash Descriptor region (0x00000000-0x00000fff) is read-only.
FREG1: BIOS region (0x00001000-0x00f7efff) is read-write.
FREG5: Device Expansion region (0x00f7f000-0x00ffffff) is locked.
Not all flash regions are freely accessible by flashrom. This is most likely
due to an active ME. Please see https://flashrom.org/ME for details.
OK.
Found GigaDevice flash chip "GD25LQ128C/GD25LQ128D/GD25LQ128E" (16384 kB, Programmer-specific) on internal.
Available protection ranges:
	start=0x00000000 length=0x00000000 (none)
	start=0x00000000 length=0x00001000 (lower 1/4096)
	start=0x00fff000 length=0x00001000 (upper 1/4096)
	start=0x00000000 length=0x00002000 (lower 1/2048)
	start=0x00ffe000 length=0x00002000 (upper 1/2048)
	start=0x00000000 length=0x00004000 (lower 1/1024)
	start=0x00ffc000 length=0x00004000 (upper 1/1024)
	start=0x00000000 length=0x00008000 (lower 1/512)
	start=0x00ff8000 length=0x00008000 (upper 1/512)
	start=0x00000000 length=0x00040000 (lower 1/64)
	start=0x00fc0000 length=0x00040000 (upper 1/64)
	start=0x00000000 length=0x00080000 (lower 1/32)
	start=0x00f80000 length=0x00080000 (upper 1/32)
	start=0x00000000 length=0x00100000 (lower 1/16)
	start=0x00f00000 length=0x00100000 (upper 1/16)
	start=0x00000000 length=0x00200000 (lower 1/8)
	start=0x00e00000 length=0x00200000 (upper 1/8)
	start=0x00000000 length=0x00400000 (lower 1/4)
	start=0x00c00000 length=0x00400000 (upper 1/4)
	start=0x00000000 length=0x00800000 (lower 1/2)
	start=0x00800000 length=0x00800000 (upper 1/2)
	start=0x00000000 length=0x00c00000 (lower 3/4)
	start=0x00400000 length=0x00c00000 (upper 3/4)
	start=0x00000000 length=0x00e00000 (lower 7/8)
	start=0x00200000 length=0x00e00000 (upper 7/8)
	start=0x00000000 length=0x00f00000 (lower 15/16)
	start=0x00100000 length=0x00f00000 (upper 15/16)
	start=0x00000000 length=0x00f80000 (lower 31/32)
	start=0x00080000 length=0x00f80000 (upper 31/32)
	start=0x00000000 length=0x00fc0000 (lower 63/64)
	start=0x00040000 length=0x00fc0000 (upper 63/64)
	start=0x00000000 length=0x00ff8000 (lower 511/512)
	start=0x00008000 length=0x00ff8000 (upper 511/512)
	start=0x00000000 length=0x00ffc000 (lower 1023/1024)
	start=0x00004000 length=0x00ffc000 (upper 1023/1024)
	start=0x00000000 length=0x00ffe000 (lower 2047/2048)
	start=0x00002000 length=0x00ffe000 (upper 2047/2048)
	start=0x00000000 length=0x00fff000 (lower 4095/4096)
	start=0x00001000 length=0x00fff000 (upper 4095/4096)
	start=0x00000000 length=0x01000000 (all)
SUCCESS
```
