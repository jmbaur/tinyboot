# shellcheck shell=bash

cd "$PWD" || exit 1

if [[ ! -d dtbs ]] || [[ ! -f Image.lzma ]] || [[ ! -f initramfs.cpio.xz ]]; then
	echo "required files/directories not found"
	exit 2
fi

mapfile -t dtb_files < <(find -L dtbs -type f -name '*.dtb')

fdt_definition() {
	local idx=$1
	local filepath=$2
	cat <<EOF
        fdt-${idx} {
            description = "$(basename "$filepath")";
            data = /incbin/("${filepath}");
            type = "flat_dt";
            arch = "arm64";
            compression = "none";
            hash-1 {
                algo = "crc32";
            };
        };
EOF
}

fdt_reference() {
	local idx=$1
	cat <<EOF
        conf-${idx} {
            kernel = "kernel";
            fdt = "fdt-${idx}";
            ramdisk = "ramdisk";
        };
EOF
}

cat <<EOF
/dts-v1/;
/ {
    description = "kernel, dtbs, and initramfs";
    #address-cells = <1>;
    images {
        kernel {
            description = "kernel";
            data = /incbin/("Image.lzma");
            type = "kernel";
            arch = "arm64";
            os = "linux";
            compression = "lzma";
            hash-1 {
                algo = "crc32";
            };
        };
        ramdisk {
            description = "ramdisk";
            data = /incbin/("initramfs.cpio.xz");
            type = "ramdisk";
            arch = "arm64";
            os = "linux";
            compression = "none";
            hash-1 {
                algo = "sha1";
            };
        };
EOF

for index in "${!dtb_files[@]}"; do
	fdt_definition "$index" "${dtb_files[$index]}"
done

cat <<EOF
    };
    configurations {
        default = "conf-0";
EOF

for index in "${!dtb_files[@]}"; do
	fdt_reference "$index"
done

cat <<EOF
    };
};
EOF
