#include "dragon_keys.h"
#include <array>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void check(bool condition, const char* message) {
    if (!condition) { fprintf(stderr, "FAILED: %s\n", message); exit(1); }
}
int main() {
    uint8_t hash[20];
    dragon_ripemd160(reinterpret_cast<const uint8_t*>("abc"), 3, hash);
    const uint8_t expected[] = {0x8e,0xb2,0x08,0xf7,0xe0,0x5d,0x98,0x7a,0x9b,0x04,0x4a,0x8e,0x98,0xc6,0xb0,0x87,0xf1,0x5a,0x0b,0xfc};
    check(memcmp(hash, expected, 20) == 0, "RIPEMD-160 known answer");
    std::array<uint8_t,1281> sk{}, second{}, invalid{};
    std::array<uint8_t,897> pk{}, restored{}, pk2{};
    check(dragon_key_generate(sk.data(), pk.data()) == 0, "key generation and signature check");
    check(dragon_key_public(sk.data(), sk.size(), restored.data()) == 0, "public recovery");
    check(pk == restored, "recovered public key matches generated public key");
    check(dragon_key_generate(second.data(), pk2.data()) == 0 && sk != second && pk != pk2, "independent entropy");
    check(dragon_key_public(sk.data(), 1280, restored.data()) != 0, "truncated secret rejected");
    check(dragon_key_public(sk.data(), 1282, restored.data()) != 0, "oversized secret rejected");
    invalid = sk; invalid[0] = 0x58;
    check(dragon_key_public(invalid.data(), invalid.size(), restored.data()) != 0, "wrong Falcon degree rejected");
    invalid = sk; invalid[1200] ^= 1;
    check(dragon_key_public(invalid.data(), invalid.size(), restored.data()) != 0, "invalid F rejected");
    invalid.fill(0); invalid[0] = 0x59;
    check(dragon_key_public(invalid.data(), invalid.size(), restored.data()) != 0, "zero polynomials rejected");
    dragon_cleanse(sk.data(), sk.size()); dragon_cleanse(second.data(), second.size());
    check(sk == std::array<uint8_t,1281>{}, "secret buffers wiped");
    puts("11 native key checks passed");
}
