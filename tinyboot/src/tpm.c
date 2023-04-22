#include <wolftpm/tpm2_wrap.h>

const char *pcr_extend(const BYTE digest[TPM_SHA256_DIGEST_SIZE]) {
  int rc = -1;

  PCR_Extend_In pcrExtend;
  WOLFTPM2_DEV dev;

  rc = wolfTPM2_Init(&dev, NULL, NULL);
  if (rc != TPM_RC_SUCCESS) {
    goto exit;
  }

  XMEMSET(&pcrExtend, 0, sizeof(pcrExtend));
  pcrExtend.pcrHandle = 9;
  pcrExtend.digests.count = 1;
  pcrExtend.digests.digests[0].hashAlg = TPM_ALG_SHA256;

  for (int i = 0; i < TPM_SHA256_DIGEST_SIZE; i++) {
    pcrExtend.digests.digests[0].digest.H[i] = digest[i];
  }

  rc = TPM2_PCR_Extend(&pcrExtend);
  if (rc != TPM_RC_SUCCESS) {
    goto exit;
  }

  wolfTPM2_Cleanup(&dev);
  return "";

exit:
  wolfTPM2_Cleanup(&dev);
  return TPM2_GetRCString(rc);
}
