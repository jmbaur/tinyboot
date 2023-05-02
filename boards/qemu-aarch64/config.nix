{ pkgs, ... }: {
  platforms = [ "aarch64-linux" ];
  coreboot = {
    configFile = ./coreboot.config;
    extraConfig = pkgs.callPackage
      ({ callPackage, buildFitImage, tinyboot-kernel, tinyboot-initramfs }:
        let
          fitimage = buildFitImage {
            boardName = "qemu-aarch64";
            kernel = tinyboot-kernel;
            initramfs = "${tinyboot-initramfs.override { tty = "ttyAMA0"; }}/initrd";
            # NOTE: See here as to why qemu needs to be in depsBuildBuild and
            # not nativeBuildInputs:
            # https://github.com/NixOS/nixpkgs/pull/146583
            dtb = callPackage
              ({ runCommand, qemu }: runCommand "qemu-aarch64.dtb" { depsBuildBuild = [ qemu ]; } ''
                qemu-system-aarch64 \
                  -M virt,secure=on,virtualization=on,dumpdtb=$out \
                  -cpu cortex-a53 -m 4096M -nographic
              '')
              { };
          };
        in
        ''
          CONFIG_PAYLOAD_FILE="${fitimage}/uImage"
        '')
      { };
  };
}
