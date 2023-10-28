{ lib, pkgs, config, ... }: {
  options.qemu.flags = with lib; mkOption {
    type = types.listOf types.str;
    default = [ ];
  };
  config = {
    qemu.flags = [ "-kernel" "${config.build.linux}/kernel" ];
    coreboot.enable = false;
    build.qemuScript = pkgs.writeShellApplication {
      name = "tinyboot-qemu";
      runtimeInputs = with pkgs.pkgsBuildBuild; [ swtpm qemu ];
      text = ''
        stop() { pkill swtpm; }
        trap stop EXIT SIGINT

        tpm_dir="''${BUILD_DIR}/mytpm1"
        mkdir -p "$tpm_dir"
        swtpm socket --tpmstate dir="$tpm_dir" \
          --ctrl type=unixio,path="''${tpm_dir}/swtpm-sock" \
          --tpm2 &

        extra_qemu_flags=()
        ${lib.optionalString (pkgs.stdenv.hostPlatform.system == pkgs.stdenv.buildPlatform.system) ''
        # we may not have kvm available if running in a VM
        if [[ -c /dev/kvm ]]; then
          extra_qemu_flags+=("-enable-kvm")
        fi
        ''}

        set -x

        qemu-system-${pkgs.hostPlatform.qemuArch} \
          -nographic \
          -smp 2 -m 2G \
          -fw_cfg name=opt/org.tboot/pubkey,file=${config.verifiedBoot.signingPublicKey} \
          -netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
          -chardev socket,id=chrtpm,path="''${tpm_dir}/swtpm-sock" -tpmdev emulator,id=tpm0,chardev=chrtpm \
          ${toString config.qemu.flags} \
          "''${extra_qemu_flags[@]}" \
          "$@"
      '';
    };
  };
}
