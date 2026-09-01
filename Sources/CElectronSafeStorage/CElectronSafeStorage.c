#include "CElectronSafeStorage.h"

#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <string.h>

static void ClearBytes(uint8_t *bytes, size_t length) {
    volatile uint8_t *cursor = bytes;
    while (length-- > 0) {
        *cursor++ = 0;
    }
}

int ElectronSafeStorageDecrypt(
    const uint8_t *payload,
    size_t payloadLength,
    const uint8_t *password,
    size_t passwordLength,
    uint8_t *output,
    size_t outputCapacity,
    size_t *outputLength
) {
    static const uint8_t prefix[] = {'v', '1', '0'};
    static const uint8_t salt[] = {'s', 'a', 'l', 't', 'y', 's', 'a', 'l', 't'};
    static const uint8_t initializationVector[kCCBlockSizeAES128] = {
        ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ',
        ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '
    };

    if (payload == NULL || password == NULL || output == NULL || outputLength == NULL ||
        payloadLength <= sizeof(prefix) ||
        memcmp(payload, prefix, sizeof(prefix)) != 0 ||
        (payloadLength - sizeof(prefix)) % kCCBlockSizeAES128 != 0) {
        return ElectronSafeStorageInvalidPayload;
    }

    if (outputCapacity < payloadLength - sizeof(prefix)) {
        return ElectronSafeStorageOutputTooSmall;
    }

    uint8_t key[kCCKeySizeAES128] = {0};
    int derivationStatus = CCKeyDerivationPBKDF(
        kCCPBKDF2,
        (const char *)password,
        passwordLength,
        salt,
        sizeof(salt),
        kCCPRFHmacAlgSHA1,
        1003,
        key,
        sizeof(key)
    );
    if (derivationStatus != kCCSuccess) {
        ClearBytes(key, sizeof(key));
        return ElectronSafeStorageKeyDerivationFailed;
    }

    size_t decryptedLength = 0;
    CCCryptorStatus decryptionStatus = CCCrypt(
        kCCDecrypt,
        kCCAlgorithmAES,
        kCCOptionPKCS7Padding,
        key,
        sizeof(key),
        initializationVector,
        payload + sizeof(prefix),
        payloadLength - sizeof(prefix),
        output,
        outputCapacity,
        &decryptedLength
    );
    ClearBytes(key, sizeof(key));

    if (decryptionStatus != kCCSuccess) {
        return ElectronSafeStorageDecryptionFailed;
    }

    *outputLength = decryptedLength;
    return ElectronSafeStorageSuccess;
}
