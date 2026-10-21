#include <jni.h>
#include "dragon_keys.h"
#include <array>

static jbyteArray bytes(JNIEnv* env, const uint8_t* data, size_t size) {
    auto result = env->NewByteArray(static_cast<jsize>(size));
    if (result) env->SetByteArrayRegion(result, 0, static_cast<jsize>(size), reinterpret_cast<const jbyte*>(data));
    return result;
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_org_dragonwallet_dragon_1wallet_KeyNative_sign(JNIEnv* env, jobject, jbyteArray input, jbyteArray message) {
    if (!input || !message || env->GetArrayLength(input) != 1281 || env->GetArrayLength(message) != 32) return nullptr;
    std::array<uint8_t, 1281> sk{};
    std::array<uint8_t, 690> sig{};
    uint8_t digest[32];
    env->GetByteArrayRegion(input, 0, 1281, reinterpret_cast<jbyte*>(sk.data()));
    env->GetByteArrayRegion(message, 0, 32, reinterpret_cast<jbyte*>(digest));
    size_t size = sig.size();
    int status = dragon_key_sign(sk.data(), sk.size(), digest, sig.data(), &size);
    dragon_cleanse(sk.data(), sk.size());
    return status ? nullptr : bytes(env, sig.data(), size);
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_org_dragonwallet_dragon_1wallet_KeyNative_fromSeed(JNIEnv* env, jobject, jbyteArray input) {
    if (!input || env->GetArrayLength(input) != 64) return nullptr;
    std::array<uint8_t, 64> seed{};
    std::array<uint8_t, 1281> sk{};
    env->GetByteArrayRegion(input, 0, 64, reinterpret_cast<jbyte*>(seed.data()));
    int status = dragon_key_from_seed(seed.data(), sk.data());
    auto result = status ? nullptr : bytes(env, sk.data(), sk.size());
    dragon_cleanse(seed.data(), seed.size());
    dragon_cleanse(sk.data(), sk.size());
    return result;
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_org_dragonwallet_dragon_1wallet_KeyNative_generate(JNIEnv* env, jobject) {
    std::array<uint8_t, 1281> sk{};
    std::array<uint8_t, 897> pk{};
    int status = dragon_key_generate(sk.data(), pk.data());
    auto result = status ? nullptr : bytes(env, sk.data(), sk.size());
    dragon_cleanse(sk.data(), sk.size());
    return result;
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_org_dragonwallet_dragon_1wallet_KeyNative_publicKey(JNIEnv* env, jobject, jbyteArray input) {
    if (!input || env->GetArrayLength(input) != 1281) return nullptr;
    std::array<uint8_t, 1281> sk{};
    std::array<uint8_t, 897> pk{};
    env->GetByteArrayRegion(input, 0, 1281, reinterpret_cast<jbyte*>(sk.data()));
    int status = dragon_key_public(sk.data(), sk.size(), pk.data());
    if (!status) status = dragon_key_check(sk.data(), sk.size());
    dragon_cleanse(sk.data(), sk.size());
    return status ? nullptr : bytes(env, pk.data(), pk.size());
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_org_dragonwallet_dragon_1wallet_KeyNative_ripemd160(JNIEnv* env, jobject, jbyteArray input) {
    if (!input || env->GetArrayLength(input) != 32) return nullptr;
    uint8_t data[32], hash[20];
    env->GetByteArrayRegion(input, 0, 32, reinterpret_cast<jbyte*>(data));
    dragon_ripemd160(data, 32, hash);
    return bytes(env, hash, 20);
}
