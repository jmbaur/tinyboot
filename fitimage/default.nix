{ buildPackages, ... }:
{ board, linux, initrd, dtb ? null, dtbPattern ? null, }:
let
  copyDtbs =
    if dtbPattern != null then ''
      find -L ${linux}/dtbs -type f -name "*.dtb" |
        grep -E "${dtbPattern}" |
        xargs -n1 basename |
        rsync -a --include="*/" --include-from=- --exclude="*" ${linux}/dtbs/ dtbs/
    '' else "cp ${dtb} dtbs";
in
buildPackages.runCommand "fitimage-${board}"
{ nativeBuildInputs = with buildPackages; [ rsync ubootTools dtc xz ]; }
  ''
    mkdir -p dtbs $out
    lzma --threads 0 <${linux}/Image >Image.lzma
    xz --test <${initrd}/initrd
    cp ${initrd}/initrd initramfs.cpio.xz
    ${copyDtbs}
    bash ${./make-image-its.bash} > image.its
    mkimage -f image.its $out/uImage
  ''
