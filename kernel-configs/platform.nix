{ config, lib, ... }:
{
  linux.kconfig = lib.mkIf (config.platform != null) (
    with lib.kernel;
    {
      "qemu" = {
        "9P_FS" = yes;
        BLK_MQ_VIRTIO = yes;
        E1000 = yes;
        FW_CFG_SYSFS = yes;
        I2C_VIRTIO = yes;
        NETWORK_FILESYSTEMS = yes;
        NET_9P = yes;
        NET_9P_VIRTIO = yes;
        NET_VENDOR_INTEL = yes;
        SCSI_VIRTIO = yes;
        VIRTIO = yes;
        VIRTIO_ANCHOR = yes;
        VIRTIO_BLK = yes;
        VIRTIO_CONSOLE = yes;
        VIRTIO_INPUT = yes;
        VIRTIO_MENU = yes;
        VIRTIO_MMIO = yes;
        VIRTIO_NET = yes;
        VIRTIO_PCI = yes;
        VIRTIO_PCI_LIB = yes;
      };
      "tigerlake" = {
        PINCTRL_TIGERLAKE = yes;
      };
      "alderlake" = {
        PINCTRL_ALDERLAKE = yes;
      };
      "qualcomm" = {
        ARCH_QCOM = yes;
        ARM_QCOM_CPUFREQ_HW = unset;
        ARM_SMMU_QCOM = yes;
        BACKLIGHT_QCOM_WLED = unset;
        COMMON_CLK_QCOM = yes;
        CRYPTO_DEV_QCOM_RNG = yes;
        HWSPINLOCK = unset;
        HWSPINLOCK_QCOM = unset;
        I2C_QCOM_CCI = yes;
        I2C_QCOM_GENI = yes;
        I2C_QUP = yes;
        INTERCONNECT = unset;
        INTERCONNECT_QCOM = unset;
        INTERCONNECT_QCOM_SC7180 = yes;
        LEDS_QCOM_FLASH = unset;
        MMC_SDHCI_MSM = yes;
        NVMEM_QCOM_QFPROM = yes;
        PHY_ATH79_USB = yes;
        PHY_QCOM_APQ8064_SATA = unset;
        PHY_QCOM_EDP = unset;
        PHY_QCOM_EUSB2_REPEATER = yes;
        PHY_QCOM_IPQ4019_USB = unset;
        PHY_QCOM_IPQ806X_SATA = unset;
        PHY_QCOM_IPQ806X_USB = unset;
        PHY_QCOM_PCIE2 = yes;
        PHY_QCOM_QMP = yes;
        PHY_QCOM_QMP_COMBO = yes;
        PHY_QCOM_QMP_PCIE = yes;
        PHY_QCOM_QMP_PCIE_8996 = yes;
        PHY_QCOM_QMP_UFS = unset;
        PHY_QCOM_QMP_USB = unset;
        PHY_QCOM_QUSB2 = unset;
        PHY_QCOM_SGMII_ETH = unset;
        PHY_QCOM_SNPS_EUSB2 = unset;
        PHY_QCOM_USB_HS = unset;
        PHY_QCOM_USB_HSIC = unset;
        PHY_QCOM_USB_HS_28NM = unset;
        PHY_QCOM_USB_SNPS_FEMTO_V2 = unset;
        PHY_QCOM_USB_SS = unset;
        PINCTRL_MSM = yes;
        PINCTRL_QCOM_SPMI_PMIC = unset;
        PINCTRL_SC7180 = yes;
        POWER_RESET_QCOM_PON = yes;
        PWM_CROS_EC = unset;
        QCOM_AOSS_QMP = yes;
        QCOM_APCS_IPC = yes;
        QCOM_APR = yes;
        QCOM_BAM_DMA = yes;
        QCOM_CLK_RPMH = yes;
        QCOM_CLK_SMD_RPM = yes;
        QCOM_COMMAND_DB = yes;
        QCOM_CPR = unset;
        QCOM_GDSC = yes;
        QCOM_GENI_SE = yes;
        QCOM_GPI_DMA = yes;
        QCOM_HFPLL = yes;
        QCOM_HIDMA = yes;
        QCOM_HIDMA_MGMT = yes;
        QCOM_ICC_BWMON = yes;
        QCOM_IOMMU = yes;
        QCOM_IPCC = yes;
        QCOM_L2_PMU = yes;
        QCOM_L3_PMU = yes;
        QCOM_LLCC = yes;
        QCOM_MPM = unset;
        QCOM_OCMEM = unset;
        QCOM_PDC = unset;
        QCOM_PIL_INFO = yes;
        QCOM_PMIC_GLINK = yes;
        QCOM_RMTFS_MEM = yes;
        QCOM_RPMH = unset;
        QCOM_RPMHPD = unset;
        QCOM_RPMPD = unset;
        QCOM_RPROC_COMMON = yes;
        QCOM_SMD_RPM = yes;
        QCOM_SMEM = yes;
        QCOM_SMP2P = yes;
        QCOM_SMSM = yes;
        QCOM_SPM = yes;
        QCOM_SPMI_ADC5 = unset;
        QCOM_SPMI_ADC_TM5 = unset;
        QCOM_SPMI_TEMP_ALARM = unset;
        QCOM_STATS = yes;
        QCOM_TSENS = yes;
        QCOM_WCNSS_CTRL = yes;
        QCOM_WDT = yes;
        REGULATOR_QCOM_RPMH = yes;
        REGULATOR_QCOM_SMD_RPM = yes;
        REGULATOR_QCOM_SPMI = unset;
        RESET_QCOM_AOSS = yes;
        RESET_QCOM_PDC = yes;
        RPMSG_NS = yes;
        RPMSG_QCOM_GLINK = yes;
        RPMSG_QCOM_GLINK_RPM = yes;
        RPMSG_QCOM_GLINK_SMEM = yes;
        RPMSG_QCOM_SMD = yes;
        SC_DISPCC_7180 = yes;
        SC_GCC_7180 = yes;
        SC_GPUCC_7180 = yes;
        SC_LPASS_CORECC_7180 = yes;
        SERIAL_MSM = yes;
        SERIAL_MSM_CONSOLE = yes;
        SERIAL_QCOM_GENI = yes;
        SERIAL_QCOM_GENI_CONSOLE = yes;
        SPI_QCOM_GENI = yes;
        SPI_QCOM_QSPI = yes;
        SPMI_MSM_PMIC_ARB = unset;
        USB_DWC3_QCOM = yes;
        USB_ONBOARD_HUB = yes;
      };
      "mediatek" = {
        ARCH_MEDIATEK = yes;
        ARM_MEDIATEK_CPUFREQ_HW = yes;
        BACKLIGHT_MT6370 = yes;
        COMMON_CLK_MT8183 = yes;
        COMMON_CLK_MT8183_AUDIOSYS = yes;
        COMMON_CLK_MT8183_CAMSYS = yes;
        COMMON_CLK_MT8183_IMGSYS = yes;
        COMMON_CLK_MT8183_IPU_ADL = yes;
        COMMON_CLK_MT8183_IPU_CONN = yes;
        COMMON_CLK_MT8183_IPU_CORE0 = yes;
        COMMON_CLK_MT8183_IPU_CORE1 = yes;
        COMMON_CLK_MT8183_MFGCFG = yes;
        COMMON_CLK_MT8183_MMSYS = yes;
        COMMON_CLK_MT8183_VDECSYS = yes;
        COMMON_CLK_MT8183_VENCSYS = yes;
        COMMON_CLK_MT8192_AUDSYS = yes;
        COMMON_CLK_MT8192_CAMSYS = yes;
        COMMON_CLK_MT8192_IMGSYS = yes;
        COMMON_CLK_MT8192_IMP_IIC_WRAP = yes;
        COMMON_CLK_MT8192_IPESYS = yes;
        COMMON_CLK_MT8192_MDPSYS = yes;
        COMMON_CLK_MT8192_MFGCFG = yes;
        COMMON_CLK_MT8192_MSDC = yes;
        COMMON_CLK_MT8192_SCP_ADSP = yes;
        COMMON_CLK_MT8192_VDECSYS = yes;
        COMMON_CLK_MT8192_VENCSYS = yes;
        I2C_MT65XX = yes;
        KEYBOARD_MT6779 = yes;
        MEDIATEK_WATCHDOG = yes;
        MFD_MT6397 = yes;
        MMC_MTK = yes;
        MFD_MT6370 = yes;
        COMMON_CLK_MT8192 = yes;
        MTD_SPI_NOR = yes;
        MTK_CMDQ_MBOX = yes;
        MTK_IOMMU = yes;
        MTK_MMSYS = yes;
        MTK_PMIC_WRAP = yes;
        MTK_SCP = yes;
        MTK_SCPSYS_PM_DOMAINS = yes;
        MTK_SMI = yes;
        MTK_SVS = yes;
        NVMEM_MTK_EFUSE = yes;
        PCIE_MEDIATEK_GEN3 = yes;
        PHY_MTK_DP = yes;
        PHY_MTK_HDMI = yes;
        PHY_MTK_MIPI_DSI = yes;
        PHY_MTK_PCIE = yes;
        PHY_MTK_TPHY = yes;
        PHY_MTK_UFS = yes;
        PHY_MTK_XSPHY = yes;
        PWM = yes;
        PWM_CROS_EC = yes;
        PWM_MTK_DISP = yes;
        REGULATOR_MT6315 = yes;
        RTC_DRV_MT6397 = yes;
        SERIAL_8250 = yes;
        SERIAL_8250_CONSOLE = yes;
        SERIAL_8250_MT6577 = yes;
        SPI_MT65XX = yes;
        SPI_MTK_NOR = yes;
        SPMI_MTK_PMIF = unset;
        USB_MTU3 = yes;
        USB_XHCI_MTK = yes;
      };
    }
    .${lib.head (lib.attrNames config.platform)}
  );
}
