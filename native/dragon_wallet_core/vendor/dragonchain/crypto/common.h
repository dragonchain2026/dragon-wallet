// Minimal portable endian helpers for the unmodified upstream RIPEMD-160.
#pragma once
#include <stdint.h>
static inline uint32_t ReadLE32(const unsigned char* p) {
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}
static inline void WriteLE32(unsigned char* p, uint32_t x) {
    for (int i = 0; i < 4; ++i) p[i] = static_cast<unsigned char>(x >> (8 * i));
}
static inline void WriteLE64(unsigned char* p, uint64_t x) {
    for (int i = 0; i < 8; ++i) p[i] = static_cast<unsigned char>(x >> (8 * i));
}
