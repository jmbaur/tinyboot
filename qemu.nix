{ lib, pkgs, config, ... }: {
  options.qemu.flags = with lib; mkOption {
    type = types.listOf types.str;
    default = [ ];
  };
  config = {
    qemu.flags = [ "-kernel" "${config.build.linux}/kernel" ] ++
      lib.optional (pkgs.stdenv.hostPlatform.system == pkgs.stdenv.buildPlatform.system) "-enable-kvm";
    build.qemuScript = pkgs.writeShellApplication {
      name = "tinyboot-qemu";
      runtimeInputs = with pkgs.buildPackages; [ swtpm qemu ];
      text = ''
        stop() { pkill swtpm; }
        trap stop EXIT SIGINT

        tpm_dir="''${BUILD_DIR}/mytpm1"
        mkdir -p "$tpm_dir"
        swtpm socket --tpmstate dir="$tpm_dir" \
          --ctrl type=unixio,path="''${tpm_dir}/swtpm-sock" \
          --tpm2 &

        qemu-system-${pkgs.hostPlatform.qemuArch} \
          -nographic \
          -smp 2 -m 2G \
          -netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
          -chardev socket,id=chrtpm,path="''${tpm_dir}/swtpm-sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
          ${toString config.qemu.flags} \
          "$@"
      '';
    };
  };
}
