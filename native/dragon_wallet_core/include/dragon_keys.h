#pragma once
#include <stddef.h>
#include <stdint.h>
// Status functions return 0 on success. Signing is used only by the Android transaction builder.
int dragon_key_sign(const uint8_t* sk, size_t len, const uint8_t digest[32], uint8_t signature[690], size_t* size);
int dragon_key_generate(uint8_t sk[1281], uint8_t pk[897]);
int dragon_key_from_seed(const uint8_t seed[64], uint8_t sk[1281]);
int dragon_key_public(const uint8_t* sk, size_t len, uint8_t pk[897]);
int dragon_key_check(const uint8_t* sk, size_t len);
void dragon_ripemd160(const uint8_t* input, size_t len, uint8_t out[20]);
void dragon_cleanse(void* data, size_t len);
