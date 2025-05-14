{
  testers,
  tinyboot,
  runCommand,
}:

testers.runNixOSTest {
  name = "disk";
  defaults.imports = [ ../module.nix ];
  nodes.machine = {
    virtualisation.fileSystems."/boot" = {
      device = "/dev/disk/by-label/QEMU\\x20VVFAT";
      fsType = "vfat";
    };
    virtualisation.qemu.options = [ "-fw_cfg name=opt/org.tboot/pubkey,file=$TBOOT_CERT_DER" ];
    virtualisation.qemu.drives = [
      {
        file = "fat:rw:$ESP";
        driveExtraOpts = {
          "if" = "virtio";
          format = "raw";
        };
      }
    ];
  };
  testScript =
    { nodes, ... }:
    let
      testArtifacts = runCommand "tinyboot-test-artifacts" { nativeBuildInputs = [ tinyboot ]; } ''
        tboot-keygen --common-name test --organization org.tboot --country US
        tboot-sign --private-key tboot-private.pem --certificate tboot-certificate.pem ${nodes.machine.system.build.kernel}/${nodes.machine.system.boot.loader.kernelFile} kernel.signed
        tboot-sign --private-key tboot-private.pem --certificate tboot-certificate.pem ${nodes.machine.system.build.initialRamdisk}/${nodes.machine.system.boot.loader.initrdFile} initrd.signed
        install -Dm0444 -t $out *.der *.pem *.signed
      '';
    in
    ''
      import os
      import shutil
      import tempfile

      os.environ["TBOOT_CERT_DER"] = "${testArtifacts}/tboot-certificate.der"

      def populate_esp(tmpdir, title, tries_left=None, tries_done=None):
          os.makedirs(os.path.join(tmpdir, "loader/entries"))

          entry_name = title
          if tries_left is not None:
              entry_name = entry_name + f"+{tries_left}"
          if tries_done is not None:
              entry_name = entry_name + f"-{tries_done}"
          entry_name = entry_name + ".conf"

          with open(os.path.join(tmpdir, "loader/entries", entry_name), "x") as entry:
              entry.write(f"title {title}\n")
              shutil.copyfile("${testArtifacts}/kernel.signed", os.path.join(tmpdir, "linux"))
              entry.write("linux /linux\n")
              shutil.copyfile("${testArtifacts}/initrd.signed", os.path.join(tmpdir, "initrd"))
              entry.write("initrd /initrd\n")
              entry.write("options init=${nodes.machine.system.build.toplevel}/init ${toString nodes.machine.boot.kernelParams}\n")

      with subtest("simple"):
          with tempfile.TemporaryDirectory() as esp:
              os.environ["ESP"] = esp
              populate_esp(
                  esp,
                  "foo",
              )
              machine.wait_for_unit("multi-user.target")

      machine.shutdown()
      machine.wait_for_shutdown()

      with subtest("boot-counting"):
          # TODO(jared): qemu bug: https://gitlab.com/qemu-project/qemu/-/issues/2786
          if False:
              with tempfile.TemporaryDirectory() as esp:
                  os.environ["ESP"] = esp
                  populate_esp(
                      esp,
                      "foo",
                      tries_left=3,
                      tries_done=0,
                  )
                  machine.wait_for_unit("boot-complete.target")
                  assert "active" == machine.succeed("systemctl is-active tboot-bless-boot.service").strip()
                  machine.succeed("test -e /boot/loader/entries/foo.conf")
    '';
}
