{ config, lib, ... }:
let
  efi = !config.coreboot.enable;
in
{
  linux.kconfig = with lib.kernel; {
    "64BIT" = yes;
    ASYMMETRIC_KEY_TYPE = yes;
    ASYMMETRIC_PUBLIC_KEY_SUBTYPE = yes;
    ATA = yes;
    BINFMT_ELF = yes;
    BINFMT_SCRIPT = yes;
    BLK_DEV = yes;
    BLK_DEV_INITRD = yes;
    BLK_DEV_NVME = yes;
    BLK_DEV_SD = yes;
    BLOCK = yes;
    CC_OPTIMIZE_FOR_PERFORMANCE = unset;
    CC_OPTIMIZE_FOR_SIZE = yes;
    COMMON_CLK = yes;
    CRYPTO_HW = yes;
    CRYPTO_SHA256 = yes;
    CRYPTO_SHA512 = yes;
    DEBUG_FS = yes; # some drivers want to write here
    DEFAULT_HOSTNAME = freeform "tinyboot";
    DEFAULT_INIT = freeform "/init";
    DEVMEM = yes;
    DEVTMPFS = yes;
    DMADEVICES = yes;
    EFI = lib.mkIf efi yes;
    EFI_STUB = lib.mkIf efi yes;
    EPOLL = yes;
    EVENTFD = yes;
    EXPERT = yes;
    FAT_FS = yes;
    FUTEX = yes;
    FW_LOADER = yes;
    FW_LOADER_COMPRESS = yes;
    FW_LOADER_COMPRESS_XZ = yes;
    GOOGLE_CBMEM = yes;
    GOOGLE_COREBOOT_TABLE = yes;
    GOOGLE_FIRMWARE = yes;
    GOOGLE_MEMCONSOLE_COREBOOT = yes;
    GOOGLE_VPD = yes;
    GPIOLIB = yes;
    HID = yes;
    HID_GENERIC = yes;
    HID_SUPPORT = yes;
    I2C = yes;
    I2C_HID = yes;
    IMA = yes;
    IMA_APPRAISE = yes;
    IMA_APPRAISE_MODSIG = yes;
    IMA_DEFAULT_HASH_SHA256 = yes;
    IMA_KEXEC = yes;
    IMA_MEASURE_ASYMMETRIC_KEYS = yes;
    INPUT = yes;
    INPUT_KEYBOARD = yes;
    INPUT_MOUSE = unset;
    INTEGRITY = yes;
    INTEGRITY_ASYMMETRIC_KEYS = yes;
    INTEGRITY_SIGNATURE = yes;
    INTEGRITY_TRUSTED_KEYRING = unset;
    IOMMU_SUPPORT = yes;
    IRQ_POLL = yes;
    JUMP_LABEL = yes;
    KEXEC = yes;
    KEXEC_FILE = yes;
    KEYS = yes;
    LSM = freeform "integrity";
    LTO_NONE = yes;
    MMC = yes;
    MMC_BLOCK = yes;
    MMC_SDHCI = yes;
    MMC_CQHCI = yes;
    MMC_HSQ = yes;
    MMU = yes;
    MODULE_SIG_FORMAT = yes;
    MSDOS_FS = yes;
    MULTIUSER = yes; # not really needed
    NET = yes; # needed for unix domain sockets
    NLS = yes;
    NLS_CODEPAGE_437 = yes;
    NLS_ISO8859_1 = yes;
    PCI = yes;
    PINCTRL = yes;
    PRINTK = yes;
    PROC_FS = yes;
    RD_XZ = yes;
    RELOCATABLE = yes; # allows for this kernel itself to be kexec'ed
    RTC_CLASS = yes;
    SCSI = yes;
    SCSI_LOWLEVEL = yes;
    SECCOMP = unset;
    SECURITY = yes;
    SECURITYFS = yes;
    SHMEM = yes;
    SIGNALFD = yes;
    SLUB = yes;
    SLUB_TINY = yes;
    SMP = yes;
    SPI = yes;
    SYSFS = yes;
    SYSVIPC = yes;
    TCG_TIS = yes;
    TCG_TPM = yes;
    TIMERFD = yes;
    TMPFS = yes;
    TTY = yes;
    UNIX = yes;
    USB = yes;
    USB_EHCI_HCD = yes;
    USB_EHCI_PCI = yes;
    USB_HID = yes;
    USB_PCI = yes;
    USB_STORAGE = yes;
    USB_SUPPORT = yes;
    USB_XHCI_HCD = yes;
    USB_XHCI_PCI = yes;
    VFAT_FS = yes;
    WATCHDOG = yes;
    WATCHDOG_HANDLE_BOOT_ENABLED = yes;
    WIRELESS = unset;
    X509_CERTIFICATE_PARSER = yes;
  };
}
