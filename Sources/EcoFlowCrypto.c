/* secp160r1 is required by EcoFlow's existing BLE protocol. The implementation
 * is vendored micro-ecc (BSD-2-Clause); no OpenSSL runtime is required. */
#define uECC_SUPPORTS_secp160r1 1
#define uECC_SUPPORTS_secp192r1 0
#define uECC_SUPPORTS_secp224r1 0
#define uECC_SUPPORTS_secp256r1 0
#define uECC_SUPPORTS_secp256k1 0
#include <Security/SecRandom.h>
#include "../Vendor/micro-ecc/uECC.c"

static int ecoflow_random(uint8_t *dest, unsigned size) {
    return SecRandomCopyBytes(kSecRandomDefault, size, dest) == errSecSuccess;
}

int ecoflow_make_key(uint8_t *public_key, uint8_t *private_key) {
    uECC_set_rng(ecoflow_random);
    return uECC_make_key(public_key, private_key, uECC_secp160r1());
}

int ecoflow_shared_secret(const uint8_t *public_key, const uint8_t *private_key, uint8_t *secret) {
    if (!uECC_valid_public_key(public_key, uECC_secp160r1())) return 0;
    return uECC_shared_secret(public_key, private_key, secret, uECC_secp160r1());
}
