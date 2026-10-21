package org.dragonwallet.dragon_wallet

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MnemonicTests {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val mnemonic = Mnemonic(context)
    // Public BIP39 test vectors, never used as a wallet or saved to the vault.
    @Test fun officialBip39Vectors() {
        val entropy = ByteArray(16)
        val phrase = "abandon ".repeat(11) + "about"
        assertEquals(phrase, mnemonic.encode(entropy))
        assertArrayEquals(entropy, mnemonic.decode("  " + phrase.uppercase().replace(" ", "\n") + "  "))
        assertEquals("c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531" +
            "f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04",
            Transfer.hex(mnemonic.seed(entropy, "TREZOR")))
        assertEquals("abandon ".repeat(23) + "art", mnemonic.encode(ByteArray(32)))
        assertEquals("zoo ".repeat(23) + "vote", mnemonic.encode(ByteArray(32) { 0xff.toByte() }))
        for (size in listOf(16,20,24,28,32)) {
            val bytes = ByteArray(size) { (it * 11).toByte() }
            assertArrayEquals(bytes, mnemonic.decode(mnemonic.encode(bytes)))
        }
    }
    @Test fun rejectsInvalidInputAndUsesFreshEntropy() {
        for (text in listOf("", "abandon ".repeat(12), "notaword ".repeat(24),
            "abandon ".repeat(13), "x".repeat(513))) {
            try { mnemonic.decode(text); fail("Invalid mnemonic accepted") }
            catch (_: IllegalArgumentException) { }
        }
        val first = mnemonic.generateEntropy()
        val second = mnemonic.generateEntropy()
        assertEquals(32, first.size)
        assertFalse(first.contentEquals(second))
        assertEquals(24, mnemonic.encode(first).split(" ").size)
        first.fill(0); second.fill(0)
        assertNull(KeyNative.fromSeed(ByteArray(32)))
    }
    @Test fun deterministicRecoveryWifAndSigning() {
        val entropy = ByteArray(32)
        val raw = mnemonic.secret(entropy)
        val recovered = mnemonic.secret(mnemonic.decode(mnemonic.encode(entropy)))
        try {
            assertArrayEquals(raw, recovered)
            val pk = KeyNative.publicKey(raw)!!
            assertEquals("dragon1qhfpt5f9ude8yksn479ga32merjg7ks9dgmk6yd", KeyCodec.witnessAddress(pk))
            assertEquals("fcf3b5f0f2f933f9b4d45535fa01bd7e5fdb70271542e30a20d8cd2de3177628", Transfer.hex(KeyCodec.sha256(raw)))
            assertEquals(KeyCodec.witnessAddress(pk), KeyCodec.witnessAddress(KeyNative.publicKey(recovered)!!))
            val different = mnemonic.secret(ByteArray(32) { 1 })
            try { assertFalse(raw.contentEquals(different)) } finally { different.fill(0) }
            val wif = KeyCodec.wif(raw + byteArrayOf(1))
            val imported = KeyCodec.decodeWif(wif)
            try { assertArrayEquals(raw, imported.copyOfRange(0,1281)) } finally { imported.fill(0) }
            assertNotNull(KeyNative.sign(raw, ByteArray(32)))
            // Public compatibility data only; no mnemonic/private material written.
            java.io.File(context.cacheDir, "mnemonic-public-vector.txt").writeText(
                KeyCodec.witnessAddress(pk) + "\n" + Transfer.hex(KeyCodec.sha256(raw)) + "\n")
        } finally { raw.fill(0); recovered.fill(0); entropy.fill(0) }
    }
}
