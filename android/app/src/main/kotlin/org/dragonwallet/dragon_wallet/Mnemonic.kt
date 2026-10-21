package org.dragonwallet.dragon_wallet

import android.content.Context
import java.security.SecureRandom
import java.text.Normalizer
import java.util.Locale
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/** BIP39 English, empty passphrase. Falcon derivation version 1 is defined in keys.cpp. */
class Mnemonic(context: Context) {
    private val words = context.assets.open("bip39-english.txt").use { input ->
        val bytes = input.readBytes()
        check(KeyCodec.sha256(bytes).joinToString("") { "%02x".format(it) } ==
            "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda")
        bytes.toString(Charsets.UTF_8).trim().lines()
    }
    private val indices = words.withIndex().associate { it.value to it.index }
    init { check(words.size == 2048 && indices.size == 2048) }
    fun generateEntropy(): ByteArray = ByteArray(32).also { SecureRandom().nextBytes(it) }
    fun encode(entropy: ByteArray): String {
        require(entropy.size in listOf(16,20,24,28,32)) { "助记词熵长度无效" }
        val hash = KeyCodec.sha256(entropy)
        fun bit(index: Int): Int {
            val data = if (index < entropy.size * 8) entropy else hash
            val offset = if (index < entropy.size * 8) index else index - entropy.size * 8
            return (data[offset / 8].toInt() ushr (7 - offset % 8)) and 1
        }
        return (0 until entropy.size * 3 / 4).joinToString(" ") { index ->
            var value = 0
            repeat(11) { value = (value shl 1) or bit(index * 11 + it) }
            words[value]
        }
    }
    fun decode(input: String): ByteArray {
        require(input.length <= 512) { "助记词过长" }
        val normalized = Normalizer.normalize(input, Normalizer.Form.NFKD).trim().lowercase(Locale.ROOT)
        val tokens = normalized.split(Regex("\\s+"))
        require(tokens.size in listOf(12,15,18,21,24)) { "请输入 12、15、18、21 或 24 个英文助记词" }
        val entropy = ByteArray(tokens.size * 4 / 3)
        try {
            tokens.forEachIndexed { index, word ->
                val value = indices[word] ?: throw IllegalArgumentException("助记词包含不支持的英文单词")
                repeat(11) { bit ->
                    val position = index * 11 + bit
                    if (position < entropy.size * 8) {
                        entropy[position / 8] = (entropy[position / 8].toInt() or
                            (((value ushr (10 - bit)) and 1) shl (7 - position % 8))).toByte()
                    }
                }
            }
            require(encode(entropy) == tokens.joinToString(" ")) { "助记词校验和错误，请核对单词和顺序" }
            return entropy
        } catch (error: Exception) { entropy.fill(0); throw error }
    }
    // Exposed internally for verification against official BIP39 vectors.
    fun seed(entropy: ByteArray, passphrase: String = ""): ByteArray {
        val chars = encode(entropy).toCharArray()
        val salt = ("mnemonic" + Normalizer.normalize(passphrase, Normalizer.Form.NFKD)).toByteArray(Charsets.UTF_8)
        val spec = PBEKeySpec(chars, salt, 2048, 512)
        return try { SecretKeyFactory.getInstance("PBKDF2WithHmacSHA512").generateSecret(spec).encoded }
        finally { chars.fill('\u0000'); salt.fill(0); spec.clearPassword() }
    }
    fun secret(entropy: ByteArray): ByteArray {
        val seed = seed(entropy)
        return try { KeyNative.fromSeed(seed) ?: error("无法从助记词恢复 Falcon 密钥") }
        finally { seed.fill(0) }
    }
}
