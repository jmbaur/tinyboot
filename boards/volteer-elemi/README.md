```console
$ sudo flashrom -p raiden_debug_spi:target=AP --wp-list
flashrom 1.4.0-devel on Linux 6.1.61 (x86_64)
flashrom is free software, get the source code at https://flashrom.org

Using clock_gettime for delay loops (clk_id: 1, resolution: 1ns).
Raiden target: 2
Found Winbond flash chip "W25Q256JV_M" (32768 kB, SPI) on raiden_debug_spi.
===
This flash part has status UNTESTED for operations: WP
The test status of this chip may have been updated in the latest development
version of flashrom. If you are running the latest development version,
please email a report to flashrom@flashrom.org if any of the above operations
work correctly for you with this flash chip. Please include the flashrom log
file for all operations you tested (see the man page for details), and mention
which mainboard or programmer you tested in the subject line.
Thanks for your help!
Available protection ranges:
        start=0x00000000 length=0x00000000 (none)
        start=0x00000000 length=0x00010000 (lower 1/512)
        start=0x01ff0000 length=0x00010000 (upper 1/512)
        start=0x00000000 length=0x00020000 (lower 1/256)
        start=0x01fe0000 length=0x00020000 (upper 1/256)
        start=0x00000000 length=0x00040000 (lower 1/128)
        start=0x01fc0000 length=0x00040000 (upper 1/128)
        start=0x00000000 length=0x00080000 (lower 1/64)
        start=0x01f80000 length=0x00080000 (upper 1/64)
        start=0x00000000 length=0x00100000 (lower 1/32)
        start=0x01f00000 length=0x00100000 (upper 1/32)
        start=0x00000000 length=0x00200000 (lower 1/16)
        start=0x01e00000 length=0x00200000 (upper 1/16)
        start=0x00000000 length=0x00400000 (lower 1/8)
        start=0x01c00000 length=0x00400000 (upper 1/8)
        start=0x00000000 length=0x00800000 (lower 1/4)
        start=0x01800000 length=0x00800000 (upper 1/4)
        start=0x00000000 length=0x01000000 (lower 1/2)
        start=0x01000000 length=0x01000000 (upper 1/2)
        start=0x00000000 length=0x01800000 (lower 3/4)
        start=0x00800000 length=0x01800000 (upper 3/4)
        start=0x00000000 length=0x01c00000 (lower 7/8)
        start=0x00400000 length=0x01c00000 (upper 7/8)
        start=0x00000000 length=0x01e00000 (lower 15/16)
        start=0x00200000 length=0x01e00000 (upper 15/16)
        start=0x00000000 length=0x01f00000 (lower 31/32)
        start=0x00100000 length=0x01f00000 (upper 31/32)
        start=0x00000000 length=0x01f80000 (lower 63/64)
        start=0x00080000 length=0x01f80000 (upper 63/64)
        start=0x00000000 length=0x01fc0000 (lower 127/128)
        start=0x00040000 length=0x01fc0000 (upper 127/128)
        start=0x00000000 length=0x01fe0000 (lower 255/256)
        start=0x00020000 length=0x01fe0000 (upper 255/256)
        start=0x00000000 length=0x01ff0000 (lower 511/512)
        start=0x00010000 length=0x01ff0000 (upper 511/512)
        start=0x00000000 length=0x02000000 (all)
SUCCESS
```
