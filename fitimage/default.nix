{
  runCommand,
  rsync,
  ubootTools,
  dtc,
  xz,
}:
{
  board ? null,
  linux,
  initrd,
  dtb ? null,
  dtbPattern ? null,
}:
let
  copyDtbs =
    if dtbPattern != null then
      ''
        find -L ${linux}/dtbs -type f -name "*.dtb" |
          grep -E "${dtbPattern}" |
          xargs -n1 basename |
          rsync -a --include="*/" --include-from=- --exclude="*" ${linux}/dtbs/ dtbs/
      ''
    else
      "cp ${dtb} dtbs";
in
runCommand "fitimage-${if (board != null) then board else "unknown"}"
  {
    nativeBuildInputs = [
      dtc
      rsync
      ubootTools
      xz
    ];
  }
  ''
    mkdir -p dtbs $out
    lzma --threads 0 <${linux}/Image >Image.lzma
    ${copyDtbs}
    bash ${./make-image-its.bash} Image.lzma ${initrd}/initrd > image.its
    mkimage -f image.its $out/uImage
  ''
