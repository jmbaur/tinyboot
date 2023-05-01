{ runCommand, ubootTools, dtc, xz, rsync, ... }:
{ boardName, kernel, initramfs, dtb ? null, dtbPattern ? null, }:
let
  nativeBuildInputs = [ rsync ubootTools dtc xz ];
  copyDtbs =
    if dtbPattern != null then ''
      find -L ${kernel}/dtbs -type f -name "*.dtb" |
        grep -E "${dtbPattern}" |
        xargs -n1 basename |
        rsync -a --include="*/" --include-from=- --exclude="*" ${kernel}/dtbs/ dtbs/
    '' else "cp ${dtb} dtbs";
  fitimage = runCommand "fitimage-${boardName}" { inherit nativeBuildInputs; } ''
    mkdir -p dtbs $out
    lzma --threads 0 <${kernel}/Image >Image.lzma
    xz --test <${initramfs}
    cp ${initramfs} initramfs.cpio.xz
    ${copyDtbs}
    bash ${./make-image-its.bash} > image.its
    mkimage -f image.its $out/uImage
  '';
in
fitimage.overrideAttrs (old: {
  passthru = (old.passthru or { }) // { inherit boardName; };
})
