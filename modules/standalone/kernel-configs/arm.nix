{ lib, pkgs, ... }:
{
  linux.kconfig = lib.mkIf pkgs.stdenv.hostPlatform.isAarch32 (
    with lib.kernel;
    {
      USE_OF = yes;
      ARCH_MULTI_V7 = yes;
      OF = yes;
      OF_ADDRESS = yes;
      OF_EARLY_FLATTREE = yes;
      OF_FLATTREE = yes;
      OF_IRQ = yes;
      OF_KOBJ = yes;
      OF_RESERVED_MEM = yes;
      SERIAL_8250 = yes;
      SERIAL_OF_PLATFORM = yes;

      #
      ARCH_ACTIONS = yes;
      ARCH_AIROHA = yes;
      ARCH_ALPINE = yes;
      ARCH_ARTPEC = yes;
      ARCH_ASPEED = yes;
      ARCH_AT91 = yes;
      ARCH_BCM = yes;
      ARCH_BCM2835 = yes;
      ARCH_BCMBCA = yes;
      ARCH_BCMBCA_BRAHMAB15 = yes;
      ARCH_BCMBCA_CORTEXA7 = yes;
      ARCH_BCMBCA_CORTEXA9 = yes;
      ARCH_BCM_21664 = yes;
      ARCH_BCM_23550 = yes;
      ARCH_BCM_281XX = yes;
      ARCH_BCM_5301X = yes;
      ARCH_BCM_53573 = yes;
      ARCH_BCM_CYGNUS = yes;
      ARCH_BCM_HR2 = yes;
      ARCH_BCM_NSP = yes;
      ARCH_BERLIN = yes;
      ARCH_BRCMSTB = yes;
      ARCH_DIGICOLOR = yes;
      ARCH_EXYNOS = yes;
      ARCH_HI3xxx = yes;
      ARCH_HIGHBANK = yes;
      ARCH_HIP01 = yes;
      ARCH_HIP04 = yes;
      ARCH_HISI = yes;
      ARCH_HIX5HD2 = yes;
      ARCH_HPE = yes;
      ARCH_HPE_GXP = yes;
      ARCH_MULTIPLATFORM = yes;
      ARCH_MXC = yes;
      ARCH_SUNPLUS = yes;
      ARCH_UNIPHIER = yes;
      ARCH_VIRT = yes;
      MACH_ARTPEC6 = yes;
      MACH_ASPEED_G6 = yes;
      MACH_BERLIN_BG2 = yes;
      MACH_BERLIN_BG2CD = yes;
      MACH_BERLIN_BG2Q = yes;
      SOC_LAN966 = yes;
      SOC_SAMA5D2 = yes;
      SOC_SAMA5D3 = yes;
      SOC_SAMA5D4 = yes;
      SOC_SAMA7G5 = yes;
    }
  );
}
