#include <stdio.h>
#include <wolftpm/tpm2_wrap.h>

const char *pcr_extend(const BYTE digest[TPM_SHA256_DIGEST_SIZE]) {
  union {
    PCR_Read_In pcrRead;
    PCR_Extend_In pcrExtend;
    byte maxInput[MAX_COMMAND_SIZE];
  } cmdIn;

  int rc = -1;
  WOLFTPM2_DEV dev;
  rc = wolfTPM2_Init(&dev, NULL, NULL);
  if (rc != TPM_RC_SUCCESS) {
    goto exit;
  }

  XMEMSET(&cmdIn.pcrExtend, 0, sizeof(cmdIn.pcrExtend));
  cmdIn.pcrExtend.pcrHandle = 9;
  cmdIn.pcrExtend.digests.count = 1;
  cmdIn.pcrExtend.digests.digests[0].hashAlg = TPM_ALG_SHA256;

  for (int i = 0; i < TPM_SHA256_DIGEST_SIZE; i++) {
    cmdIn.pcrExtend.digests.digests[0].digest.H[i] = digest[i];
  }

  rc = TPM2_PCR_Extend(&cmdIn.pcrExtend);
  if (rc != TPM_RC_SUCCESS) {
    goto exit;
  }

  wolfTPM2_Cleanup(&dev);
  return "";

exit:
  wolfTPM2_Cleanup(&dev);
  return TPM2_GetRCString(rc);
}
