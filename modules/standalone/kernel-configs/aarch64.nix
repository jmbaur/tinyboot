{ lib, pkgs, ... }:
{
  linux.kconfig = lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 (
    with lib.kernel;
    {
      ARM64_AMU_EXTN = yes;
      ARM64_ERRATUM_1024718 = yes;
      ARM64_ERRATUM_1165522 = yes;
      ARM64_ERRATUM_1319367 = yes;
      ARM64_ERRATUM_1463225 = yes;
      ARM64_ERRATUM_1508412 = yes;
      ARM64_ERRATUM_1530923 = yes;
      ARM64_ERRATUM_2051678 = yes;
      ARM64_ERRATUM_2054223 = yes;
      ARM64_ERRATUM_2067961 = yes;
      ARM64_ERRATUM_2077057 = yes;
      ARM64_ERRATUM_2658417 = yes;
      ARM64_ERRATUM_819472 = yes;
      ARM64_ERRATUM_824069 = yes;
      ARM64_ERRATUM_826319 = yes;
      ARM64_ERRATUM_827319 = yes;
      ARM64_ERRATUM_832075 = yes;
      ARM64_ERRATUM_843419 = yes;
      ARM_ARCH_TIMER = yes;
      ARM_PMU = yes;
      ARM_PSCI_CPUIDLE = yes;
      ARM_PSCI_FW = yes;
      ARM_SCMI_PROTOCOL = yes;
      ARM_SCMI_TRANSPORT_MAILBOX = yes;
      ARM_SCMI_TRANSPORT_SMC = yes;
      ARM_SCPI_PROTOCOL = yes;
      ARM_SMMU = yes;
      ARM_SMMU_V3 = yes;
      CMDLINE_FROM_BOOTLOADER = yes;
      CPU_FREQ = yes;
      CPU_IDLE = yes;
      CRYPTO_SHA256_ARM64 = yes;
      CRYPTO_SHA512_ARM64 = yes;
      DTC = yes;
      HW_PERF_EVENTS = yes;
      IIO = unset;
      MAILBOX = yes;
      MFD_SYSCON = yes;
      MMC_SDHCI_PLTFM = yes;
      MTD = yes;
      MTD_BLOCK = yes;
      NVMEM = yes;
      OF = yes;
      OF_ADDRESS = yes;
      OF_EARLY_FLATTREE = yes;
      OF_FLATTREE = yes;
      OF_IRQ = yes;
      OF_KOBJ = yes;
      OF_RESERVED_MEM = yes;
      PCI_ENDPOINT = yes;
      PCI_ENDPOINT_CONFIGFS = unset;
      PERF_EVENTS = yes;
      REGULATOR = yes;
      REGULATOR_FIXED_VOLTAGE = yes;
      REMOTEPROC = yes;
      RESET_CONTROLLER = yes;
      SERIAL_8250 = yes;
      SERIAL_OF_PLATFORM = yes;
      SPMI = yes;
      SRAM = unset;
    }
  );
}
