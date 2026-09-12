# 32-bit arm is one of the architectures whose kernel implements kexec_load(2)
# but not kexec_file_load(2), so we have to find the holes in memory and
# lay out the next kernel, initrd and devicetree itself (see src/kexec/arm.zig).
# This boots tinyboot on qemu's 32-bit arm "virt" machine and makes sure it can
# kexec into the kernel and initrd of a real NixOS system.
{
  lib,
  testers,
  pkgsCross,
}:

testers.runNixOSTest {
  name = "kexec-load";

  # The guest is cross-compiled from whatever platform the test is built on,
  # qemu-system-arm runs it under TCG.
  # mkForce because `runNixOSTest` itself pins this to the host's package set.
  node.pkgs = lib.mkForce pkgsCross.armv7l-hf-multiplatform;

  defaults.imports = [ ../module.nix ];

  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      kernel = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
      initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";

      # The kexec'd kernel needs the same command line that
      # `virtualisation.directBoot` would have passed on the qemu command line,
      # otherwise the booted system finds neither its nix store nor the test
      # driver's backdoor.
      regInfo = config.virtualisation.host.pkgs.closureInfo {
        rootPaths = [ config.system.build.toplevel ];
      };

      consoles = lib.concatMapStringsSep " " (c: "console=${c}") config.virtualisation.qemu.consoles;

      loaderConf = pkgs.writeText "loader.conf" ''
        timeout 0
        default nixos-generation-1
      '';

      # The entry filename carries no boot counter, since tinyboot only keeps
      # track of boot attempts when the kernel it runs on has liveupdate, which
      # this one doesn't.
      entry = pkgs.writeText "nixos-generation-1.conf" ''
        title NixOS
        version Generation 1
        linux /loader/nixos/kernel
        initrd /loader/nixos/initrd
        options init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams} regInfo=${regInfo}/registration ${consoles}
      '';

      # A GPT-partitioned disk holding a single EFI system partition with
      # bootloader spec entries on it, which is what our disk bootloader
      # goes looking for. This is assembled by hand instead of with
      # nixos/lib/make-disk-image.nix because that one populates the image from
      # inside a VM of the guest's architecture, which defeats the point of
      # cross-compiling the guest.
      esp =
        pkgs.runCommand "tboot-kexec-load-esp.img"
          {
            nativeBuildInputs = with pkgs.buildPackages; [
              dosfstools
              mtools
              util-linux
            ];
          }
          ''
            # Room for the kernel and initrd plus 32MiB of slack, rounded up to
            # a whole number of mebibytes.
            partSize=$(( ($(stat -Lc %s ${kernel}) + $(stat -Lc %s ${initrd}) + 33554432) / 1048576 * 1048576 ))

            truncate -s $partSize part.img
            mkfs.vfat -n ESP -i abcd1234 part.img
            mmd -i part.img ::/loader ::/loader/entries ::/loader/nixos
            echo type1 > entries.srel
            mcopy -i part.img entries.srel ::/loader/entries.srel
            mcopy -i part.img ${loaderConf} ::/loader/loader.conf
            mcopy -i part.img ${entry} ::/loader/entries/nixos-generation-1.conf
            mcopy -i part.img ${kernel} ::/loader/nixos/kernel
            mcopy -i part.img ${initrd} ::/loader/nixos/initrd

            # The partition starts at 1MiB, the spare 2MiB at the end leaves
            # room for the backup GPT header.
            truncate -s $(( partSize + 3 * 1048576 )) $out
            printf '%s\n' \
              'label: gpt' \
              'label-id: 1dcd1b1e-0000-4000-8000-000000000000' \
              "start=2048, size=$(( partSize / 512 )), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=ESP, uuid=1dcd1b1e-0000-4000-8000-000000000001" \
              | sfdisk $out
            dd if=part.img of=$out bs=1M seek=1 conv=notrunc
          '';
    in
    {
      system.build.tbootEsp = esp;

      # The NixOS kernel we kexec into reaches its root disk and nix store over
      # virtio-pci, and qemu's arm "virt" machine puts the PCIe ECAM window at
      # 0x4010000000. Only an LPAE kernel has a wide enough phys_addr_t to
      # address it, same as the bootloader kernel in tests/kernel.nix.
      boot.kernelPatches = [
        {
          name = "arm-lpae";
          patch = null;
          structuredExtraConfig.ARM_LPAE = lib.kernel.yes;
        }
      ];

      # There is no kvm for a 32-bit arm guest on the machines this gets built
      # on, so everything here runs under tcg and a full second-stage NixOS
      # boot costs several times what everything before it does. Put the test
      # driver's backdoor in the initrd instead: the boot then stops at
      # initrd.target and we make our assertions from there, which is already
      # past the point this test is about.
      testing.initrdBackdoor = true;

      # qemu (and so its guest agent) has no armv7l build in nixpkgs.
      virtualisation.qemu.guestAgent.enable = false;

      # The VM start script runs tpm2_startup on the host but takes tpm2-tools
      # from the guest's package set, so with a guest of another architecture
      # it can't execute it. We skip measured boot entirely on platforms that
      # cannot kexec_file_load(), so no worries.
      virtualisation.tpm.enable = lib.mkForce false;

      # The ESP goes on the virtio-mmio bus so that it stays apart from the
      # root disk qemu-vm.nix puts on PCIe. snapshot=on keeps the writes that
      # mounting the ESP read-write makes out of the nix store.
      virtualisation.qemu.options = [
        "-drive id=tboot-esp,file=${esp},format=raw,if=none,snapshot=on"
        "-device virtio-blk-device,drive=tboot-esp"
      ];
    };

  testScript =
    { nodes, ... }:
    ''
      machine.start()

      # Double check we aren't using kexec_file_load()
      machine.wait_for_console_text("platform does not have kexec_file_load")

      machine.wait_for_console_text("kexec loaded")

      # Stage 1 of the kexec'd system, which `testing.initrdBackdoor` above
      # parks the boot at. Getting here is the whole thing this test is after:
      # the kernel and initrd that tinyboot read off the ESP and laid out in
      # memory itself are intact enough for the kernel to have started and
      # unpacked its initrd.
      machine.wait_for_unit("initrd.target")

      # tinyboot passed along the command line from the bootloader spec entry
      # rather than anything of its own, so stage 1 is about to hand over to
      # the generation we put on the ESP.
      cmdline = machine.succeed("cat /proc/cmdline")
      assert "init=${nodes.machine.system.build.toplevel}/init" in cmdline, cmdline

      # The seed is only in the devicetree we handed this kernel if we found
      # the hwrng, and it is only non-zero if we managed to read from it.
      # Nothing on 32-bit arm consumes the property, so it survives into sysfs.
      seed = machine.succeed("od --address-radix=n --format=x8 /sys/firmware/devicetree/base/chosen/kaslr-seed").strip()
      assert seed != "0000000000000000", "KASLR seed was not filled in from the hwrng"
    '';
}
