#include "dragon_keys.h"
#include "api.h"
#include "inner.h"
#include "crypto/ripemd160.h"
#include <string.h>

void dragon_cleanse(void* data, size_t len) {
    volatile uint8_t* p = static_cast<volatile uint8_t*>(data);
    while (len--) *p++ = 0;
}
template<class T> struct Wipe {
    T& value;
    ~Wipe() { dragon_cleanse(&value, sizeof(value)); }
};
int dragon_key_public(const uint8_t* sk, size_t len, uint8_t pk[897]) {
    if (!sk || len != 1281 || sk[0] != 0x59) return -1;
    struct Scratch {
        int8_t f[512], g[512], F[512], G[512];
        uint16_t h[512];
        alignas(8) uint8_t temp[72 * 512];
    } s{};
    Wipe<Scratch> wipe{s};
    size_t offset = 1;
    for (int i = 0; i < 3; ++i) {
        int8_t* dest = i == 0 ? s.f : i == 1 ? s.g : s.F;
        size_t n = PQCLEAN_FALCON512_CLEAN_trim_i8_decode(dest, 9,
            i == 2 ? PQCLEAN_FALCON512_CLEAN_max_FG_bits[9] : PQCLEAN_FALCON512_CLEAN_max_fg_bits[9],
            sk + offset, len - offset);
        if (!n) return -1;
        offset += n;
    }
    if (offset != len || !PQCLEAN_FALCON512_CLEAN_complete_private(s.G, s.f, s.g, s.F, 9, s.temp)) return -1;
    // Reject malformed F even when f/g could derive a superficially valid public key.
    int norm = 0;
    for (int i = 0; i < 512; ++i) norm += s.f[i] * s.f[i] + s.g[i] * s.g[i];
    if (norm >= 16823) return -1;
    // Match the reference key generator's Gram-Schmidt acceptance bound too.
    auto* r1 = reinterpret_cast<fpr*>(s.temp);
    auto* r2 = r1 + 512;
    auto* r3 = r2 + 512;
    for (int i = 0; i < 512; ++i) { r1[i] = fpr_of(s.f[i]); r2[i] = fpr_of(s.g[i]); }
    PQCLEAN_FALCON512_CLEAN_FFT(r1, 9);
    PQCLEAN_FALCON512_CLEAN_FFT(r2, 9);
    PQCLEAN_FALCON512_CLEAN_poly_invnorm2_fft(r3, r1, r2, 9);
    PQCLEAN_FALCON512_CLEAN_poly_adj_fft(r1, 9);
    PQCLEAN_FALCON512_CLEAN_poly_adj_fft(r2, 9);
    PQCLEAN_FALCON512_CLEAN_poly_mulconst(r1, fpr_q, 9);
    PQCLEAN_FALCON512_CLEAN_poly_mulconst(r2, fpr_q, 9);
    PQCLEAN_FALCON512_CLEAN_poly_mul_autoadj_fft(r1, r3, 9);
    PQCLEAN_FALCON512_CLEAN_poly_mul_autoadj_fft(r2, r3, 9);
    PQCLEAN_FALCON512_CLEAN_iFFT(r1, 9);
    PQCLEAN_FALCON512_CLEAN_iFFT(r2, 9);
    fpr bnorm = fpr_zero;
    for (int i = 0; i < 512; ++i) {
        bnorm = fpr_add(bnorm, fpr_sqr(r1[i]));
        bnorm = fpr_add(bnorm, fpr_sqr(r2[i]));
    }
    if (!fpr_lt(bnorm, fpr_bnorm_max)) return -1;
    for (int k = 0; k < 512; ++k) {
        int coefficient = 0;
        for (int i = 0; i < 512; ++i) {
            int j = k - i;
            int sign = j < 0 ? -1 : 1;
            if (j < 0) j += 512;
            coefficient += sign * (s.f[i] * s.G[j] - s.g[i] * s.F[j]);
        }
        if (coefficient != (k == 0 ? 12289 : 0)) return -1;
    }
    if (!PQCLEAN_FALCON512_CLEAN_compute_public(s.h, s.f, s.g, 9, s.temp)) return -1;
    pk[0] = 9;
    return PQCLEAN_FALCON512_CLEAN_modq_encode(pk + 1, 896, s.h, 9) == 896 ? 0 : -1;
}
int dragon_key_check(const uint8_t* sk, size_t len) {
    uint8_t pk[897], signature[690];
    Wipe<decltype(signature)> wipe{signature};
    static const uint8_t message[] = "Dragon Wallet key recovery self-check v1";
    if (dragon_key_public(sk, len, pk)) return -1;
    size_t size = sizeof(signature);
    if (PQCLEAN_FALCON512_CLEAN_crypto_sign_signature(signature, &size, message, sizeof(message), sk)) return -1;
    return PQCLEAN_FALCON512_CLEAN_crypto_sign_verify(signature, size, message, sizeof(message), pk);
}
// Dragon Wallet mnemonic derivation v1. Domain bytes exclude the terminating NUL.
// This is deliberately independent of randombytes used by signing/key generation.
int dragon_key_from_seed(const uint8_t seed[64], uint8_t sk[1281]) {
    if (!seed || !sk) return -1;
    struct Scratch {
        alignas(8) uint8_t temp[FALCON_KEYGEN_TEMP_9];
        int8_t f[512], g[512], F[512];
        uint16_t h[512];
        inner_shake256_context rng;
    } s{};
    Wipe<Scratch> wipe{s};
    static const char domain[] = "Dragon Wallet/Falcon-512/mnemonic/v1";
    inner_shake256_init(&s.rng);
    inner_shake256_inject(&s.rng, reinterpret_cast<const uint8_t*>(domain), sizeof(domain) - 1);
    inner_shake256_inject(&s.rng, seed, 64);
    inner_shake256_flip(&s.rng);
    PQCLEAN_FALCON512_CLEAN_keygen(&s.rng, s.f, s.g, s.F, nullptr, s.h, 9, s.temp);
    dragon_cleanse(s.rng.ctx, PQC_SHAKEINCCTX_BYTES);
    inner_shake256_ctx_release(&s.rng);
    sk[0] = 0x59;
    size_t offset = 1;
    for (int i = 0; i < 3; ++i) {
        size_t n = PQCLEAN_FALCON512_CLEAN_trim_i8_encode(sk + offset, 1281 - offset,
            i == 0 ? s.f : i == 1 ? s.g : s.F, 9,
            i == 2 ? PQCLEAN_FALCON512_CLEAN_max_FG_bits[9] : PQCLEAN_FALCON512_CLEAN_max_fg_bits[9]);
        if (!n) { dragon_cleanse(sk, 1281); return -1; }
        offset += n;
    }
    if (offset != 1281 || dragon_key_check(sk, 1281)) {
        dragon_cleanse(sk, 1281); return -1;
    }
    return 0;
}
int dragon_key_generate(uint8_t sk[1281], uint8_t pk[897]) {
    if (PQCLEAN_FALCON512_CLEAN_crypto_sign_keypair(pk, sk) || dragon_key_check(sk, 1281)) {
        dragon_cleanse(sk, 1281);
        return -1;
    }
    return 0;
}
void dragon_ripemd160(const uint8_t* input, size_t len, uint8_t out[20]) {
    CRIPEMD160().Write(input, len).Finalize(out);
}
int dragon_key_sign(const uint8_t* sk, size_t len, const uint8_t digest[32], uint8_t signature[690], size_t* size) {
    uint8_t pk[897];
    if (!digest || !signature || !size || dragon_key_public(sk, len, pk)) return -1;
    *size = 690;
    if (PQCLEAN_FALCON512_CLEAN_crypto_sign_signature(signature, size, digest, 32, sk)
        || *size > 690 || PQCLEAN_FALCON512_CLEAN_crypto_sign_verify(signature, *size, digest, 32, pk)) {
        dragon_cleanse(signature, 690);
        *size = 0;
        return -1;
    }
    return 0;
}
