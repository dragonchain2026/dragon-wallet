package org.dragonwallet.dragon_wallet

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.math.BigInteger
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object KeyNative {
    init { System.loadLibrary("dragon_keys_jni") }
    external fun generate(): ByteArray?
    external fun fromSeed(seed: ByteArray): ByteArray?
    external fun publicKey(secret: ByteArray): ByteArray?
    external fun sign(secret: ByteArray, digest: ByteArray): ByteArray?
    external fun ripemd160(input: ByteArray): ByteArray
}

object KeyCodec {
    private const val alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    private val radix = BigInteger.valueOf(58)
    fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
    fun encode(payload: ByteArray): String {
        val data = payload + sha256(sha256(payload)).copyOf(4)
        try {
            var number = BigInteger(1, data)
            val result = StringBuilder()
            while (number.signum() > 0) {
                val parts = number.divideAndRemainder(radix)
                result.append(alphabet[parts[1].toInt()]); number = parts[0]
            }
            for (byte in data) { if (byte.toInt() != 0) break; result.append('1') }
            return result.reverse().toString()
        } finally { data.fill(0) }
    }
    // Returns 1281 private bytes plus a preserved compressed-format flag.
    fun decodeWif(input: String): ByteArray {
        val text = input.trim()
        require(text.length in 1700..1800) { "请输入 Dragonchain Falcon-512 WIF 私钥" }
        var number = BigInteger.ZERO
        for (char in text) {
            val digit = alphabet.indexOf(char)
            require(digit >= 0) { "私钥包含无效字符" }
            number = number.multiply(radix).add(BigInteger.valueOf(digit.toLong()))
        }
        val raw = number.toByteArray()
        val bytes = if (raw.size > 1 && raw[0] == 0.toByte()) raw.copyOfRange(1, raw.size) else raw.copyOf()
        raw.fill(0)
        try {
            require(bytes.size == 1286 || bytes.size == 1287) { "私钥长度无效" }
            val payload = bytes.copyOfRange(0, bytes.size - 4)
            try {
                require(payload[0] == 0x80.toByte()) { "只支持主网私钥" }
                require(payload.size == 1282 || payload.last() == 1.toByte()) { "私钥格式无效" }
                require(MessageDigest.isEqual(sha256(sha256(payload)).copyOf(4), bytes.copyOfRange(bytes.size - 4, bytes.size))) { "私钥校验和错误" }
                require(encode(payload) == text) { "私钥编码无效" }
                return payload.copyOfRange(1, 1282) + byteArrayOf(if (payload.size == 1283) 1 else 0)
            } finally { payload.fill(0) }
        } finally { bytes.fill(0) }
    }
    fun wif(secret: ByteArray): String {
        require(secret.size == 1282)
        val payload = byteArrayOf(0x80.toByte()) + secret.copyOfRange(0, 1281) +
            if (secret.last() == 1.toByte()) byteArrayOf(1) else byteArrayOf()
        try { return encode(payload) } finally { payload.fill(0) }
    }
    fun address(publicKey: ByteArray): String {
        require(publicKey.size == 897 && publicKey[0] == 9.toByte())
        return encode(byteArrayOf(63) + KeyNative.ripemd160(sha256(byteArrayOf(7) + publicKey)))
    }
    fun witnessAddress(publicKey: ByteArray): String {
        require(publicKey.size == 897 && publicKey[0] == 9.toByte())
        return witnessAddressForHash(KeyNative.ripemd160(sha256(byteArrayOf(7) + publicKey)))
    }
    fun witnessAddressForHash(hash: ByteArray): String {
        require(hash.size == 20)
        val values = mutableListOf(0)
        var acc = 0; var bits = 0
        for (byte in hash) {
            acc = ((acc shl 8) or (byte.toInt() and 255)) and 0xffff; bits += 8
            while (bits >= 5) { bits -= 5; values.add((acc ushr bits) and 31) }
        }
        if (bits > 0) values.add((acc shl (5 - bits)) and 31)
        var check = 1
        val generators = intArrayOf(0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3)
        for (value in "dragon".map { it.code shr 5 } + listOf(0) + "dragon".map { it.code and 31 } + values + List(6) { 0 }) {
            val top = check ushr 25
            check = ((check and 0x1ffffff) shl 5) xor value
            for (i in 0..4) if ((top ushr i) and 1 != 0) check = check xor generators[i]
        }
        check = check xor 1
        val charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
        return "dragon1" + (values + (0..5).map { (check ushr (5 * (5-it))) and 31 }).map { charset[it] }.joinToString("")
    }
}

class KeyVault(context: Context) {
    private val mnemonic = Mnemonic(context)
    private val directory = File(context.noBackupFilesDir, "falcon-keys-v1").apply { mkdirs() }
    private fun key(alias: String, create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        check(create) { "设备密钥不可用，请从备份恢复" }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).setUserAuthenticationRequired(true)
            .setUserAuthenticationValidityDurationSeconds(30).build())
        return generator.generateKey()
    }
    private fun alias(record: JSONObject, id: String): String {
        val name = record.getString("alias")
        require(name.matches(Regex("dragon\\.wallet\\.falcon\\.v1\\.$id\\.[0-9a-f-]{36}")))
        return name
    }
    private fun removeKey(name: String) {
        KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(name) }
    }
    private fun file(id: String): File {
        require(id.matches(Regex("[0-9a-f]{64}")))
        return File(directory, "$id.json")
    }
    private fun id(pk: ByteArray) = KeyCodec.sha256(pk).joinToString("") { "%02x".format(it) }
    private fun decode(value: String) = Base64.decode(value, Base64.NO_WRAP)
    private fun encode(value: ByteArray) = Base64.encodeToString(value, Base64.NO_WRAP)
    private fun records(): List<File> = directory.listFiles().orEmpty()
        .filter { it.name.endsWith(".json") || it.name.endsWith(".json.bak") }
        .map { File(directory, it.name.removeSuffix(".bak")) }.distinctBy { it.name }.sortedBy { it.name }
    private fun read(file: File) = JSONObject(AtomicFile(file).readFully().toString(Charsets.UTF_8))
    fun list(): List<Map<String, String>> = records().map { item ->
            val record = read(item)
            val pk = decode(record.getString("publicKey"))
            check(id(pk) == item.nameWithoutExtension)
            metadata(pk, record.optInt("mnemonicVersion") == 1, record.optString("backupType",
                if (record.optInt("mnemonicVersion") == 1) "mnemonic" else "wif"))
        }
    private fun metadata(pk: ByteArray, hasMnemonic: Boolean, backupType: String) = mapOf("id" to id(pk),
        "address" to KeyCodec.witnessAddress(pk), "legacy_address" to KeyCodec.address(pk),
        "has_mnemonic" to hasMnemonic.toString(), "backup_type" to backupType)
    private fun save(secret: ByteArray, entropy: ByteArray? = null): Map<String, String> {
        val raw = secret.copyOfRange(0, 1281)
        val pk = try { KeyNative.publicKey(raw) ?: throw IllegalArgumentException("私钥无效或无法通过签名自检") } finally { raw.fill(0) }
        val id = id(pk)
        val previousAlias = if (records().any { it.nameWithoutExtension == id }) alias(read(file(id)), id) else null
        check(previousAlias != null || list().size < 100) { "最多保存 100 个本地密钥" }
        // Reimporting WIF must not silently discard an existing mnemonic backup.
        val retained = if (entropy == null && previousAlias != null && read(file(id)).optInt("mnemonicVersion") == 1)
            withPayload(id) { payload, _ -> payload.copyOfRange(1282, payload.size) } else null
        val recovery = entropy ?: retained
        val payload = secret + (recovery ?: byteArrayOf())
        // Each import receives a fresh wrapping key, so restoring one backup also
        // repairs its invalidated Keystore entry without changing any other key.
        val newAlias = "dragon.wallet.falcon.v1.$id.${java.util.UUID.randomUUID()}"
        var committed = false
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key(newAlias, true))
            cipher.updateAAD(pk)
            val ciphertext = cipher.doFinal(payload)
            val record = JSONObject().put("version", if (recovery == null) 1 else 2)
                .put("backupType", if (entropy == null) "wif" else "mnemonic")
                .put("mnemonicVersion", if (recovery == null) 0 else 1).put("alias", newAlias).put("publicKey", encode(pk))
                .put("iv", encode(cipher.iv)).put("ciphertext", encode(ciphertext))
            val atomic = AtomicFile(file(id))
            val output = atomic.startWrite()
            try { output.write(record.toString().toByteArray()); atomic.finishWrite(output) }
            catch (error: Exception) { atomic.failWrite(output); throw error }
            committed = true
        } finally {
            payload.fill(0); retained?.fill(0)
            if (!committed) removeKey(newAlias)
        }
        if (previousAlias != null) removeKey(previousAlias)
        return metadata(pk, recovery != null, if (entropy == null) "wif" else "mnemonic")
    }
    fun generate(): Map<String, String> {
        val raw = KeyNative.generate() ?: error("生成密钥失败")
        val secret = raw + byteArrayOf(1)
        raw.fill(0)
        try { return save(secret) } finally { secret.fill(0) }
    }
    fun generateMnemonic(): Map<String, String> {
        val entropy = mnemonic.generateEntropy()
        try { return saveMnemonic(entropy) } finally { entropy.fill(0) }
    }
    private fun saveMnemonic(entropy: ByteArray): Map<String, String> {
        val raw = mnemonic.secret(entropy)
        val secret = raw + byteArrayOf(1)
        raw.fill(0)
        try { return save(secret, entropy) } finally { secret.fill(0) }
    }
    fun importMnemonic(text: String): Map<String, String> {
        val entropy = mnemonic.decode(text)
        try { return saveMnemonic(entropy) } finally { entropy.fill(0) }
    }
    fun exportMnemonic(id: String): ByteArray = withPayload(id) { payload, pk ->
        require(payload.size > 1282) { "此地址由 WIF 导入或旧版随机生成，没有助记词，请导出 WIF 私钥备份" }
        val entropy = payload.copyOfRange(1282, payload.size)
        try {
            val raw = mnemonic.secret(entropy)
            try { check(KeyNative.publicKey(raw)?.contentEquals(pk) == true) }
            finally { raw.fill(0) }
            (mnemonic.encode(entropy) + "\n").toByteArray(Charsets.UTF_8)
        } finally { entropy.fill(0) }
    }
    fun importWif(wif: String): Map<String, String> {
        val secret = KeyCodec.decodeWif(wif)
        try { return save(secret) } finally { secret.fill(0) }
    }
    fun exportWif(id: String): ByteArray {
        return withSecret(id) { secret, _ -> (KeyCodec.wif(secret) + "\n").toByteArray(Charsets.UTF_8) }
    }
    fun publicKey(id: String): ByteArray {
        val pk = decode(read(file(id)).getString("publicKey"))
        check(id(pk) == id)
        return pk
    }
    fun <T> withSecret(id: String, action: (ByteArray, ByteArray) -> T): T {
        return withPayload(id) { payload, pk ->
            val secret = payload.copyOfRange(0, 1282)
            try { action(secret, pk) } finally { secret.fill(0) }
        }
    }
    private fun <T> withPayload(id: String, action: (ByteArray, ByteArray) -> T): T {
        val record = read(file(id))
        val pk = decode(record.getString("publicKey"))
        check(id(pk) == id)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(alias(record, id), false), GCMParameterSpec(128, decode(record.getString("iv"))))
        cipher.updateAAD(pk)
        val secret = cipher.doFinal(decode(record.getString("ciphertext")))
        try {
            when (record.getInt("version")) {
                1 -> require(secret.size == 1282 && record.optInt("mnemonicVersion") == 0)
                2 -> require(record.optInt("mnemonicVersion") == 1 && secret.size - 1282 in listOf(16,20,24,28,32))
                else -> error("不支持的密钥存储版本")
            }
            require(secret[1281].toInt() in 0..1)
            val raw = secret.copyOfRange(0, 1281)
            try { check(KeyNative.publicKey(raw)?.contentEquals(pk) == true) }
            finally { raw.fill(0) }
            return action(secret, pk)
        } finally { secret.fill(0) }
    }
    fun delete(id: String) {
        val name = alias(read(file(id)), id)
        check(file(id).delete()) { "删除失败" }
        removeKey(name)
    }
}
