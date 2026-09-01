#ifndef C_ELECTRON_SAFE_STORAGE_H
#define C_ELECTRON_SAFE_STORAGE_H

#include <stddef.h>
#include <stdint.h>

enum ElectronSafeStorageResult {
    ElectronSafeStorageSuccess = 0,
    ElectronSafeStorageInvalidPayload = 1,
    ElectronSafeStorageKeyDerivationFailed = 2,
    ElectronSafeStorageDecryptionFailed = 3,
    ElectronSafeStorageOutputTooSmall = 4
};

int ElectronSafeStorageDecrypt(
    const uint8_t *payload,
    size_t payloadLength,
    const uint8_t *password,
    size_t passwordLength,
    uint8_t *output,
    size_t outputCapacity,
    size_t *outputLength
);

#endif
